#if os(macOS)
import SwiftUI

/// 右栏：当前 session 的内嵌终端视图。
///
/// 这一层只观察 `CrewSessionRunner.current`（哪个 run 在前台）。具体 run 的
/// status 变化由内层 `SessionRunContentView` 通过 `@ObservedObject` 观察 ——
/// **必须分两层**：`CrewSessionRun` 是嵌套的 ObservableObject，父 view 只
/// `@EnvironmentObject` 持有 runner 时不会订阅到 run 自己的 `@Published`，否则
/// status 更新了 UI 不刷新。
struct CrewSessionWindowView: View {
    @EnvironmentObject private var sessionRunner: CrewSessionRunner
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var crewStore: CrewStore

    @State private var draft = ""
    @State private var starting = false
    @State private var localError: String?
    @State private var selectedKind: LocalCodingAgentKind = .claudeCode
    /// Sessions this app has already claimed+run (or is running), so the
    /// auto-claim loop (K: captain-created queued sessions) doesn't double-run
    /// them. Includes both manual starts and auto-claimed ones.
    @State private var handledSessionIds: Set<String> = []

    /// spec §9.3 + 用户心智：右栏是**常驻**和 claude/codex 交互的面（像 Codex
    /// Desktop）。没有 session 时就地给一个 composer —— **第一条消息即开始
    /// session**（零配置，用 crew 默认目录/runner/权限模式；无标题、无单独的
    /// 「新建」表单）。运行中再发 = 直接把文本注入终端续聊。
    var body: some View {
        VStack(spacing: 0) {
            if let run = sessionRunner.current {
                SessionRunContentView(run: run)
                // 内联待办卡片：本 session 调 ask / 撞权限被拦时，就地答（写 LocalApprovalStore
                // 解 helper 的 long-poll）。BYOK 本地路径；logged 走 edge interactions。
                if appModel.mode == .byok {
                    SessionApprovalCardsView(crewId: run.crewId, sessionId: run.sessionId)
                }
            } else {
                idleState
            }
            Divider()
            composer
        }
        .navigationTitle("Session")
        // K (edge→Mac channel): for the selected crew, auto-claim + run sessions
        // the captain queued on the server (status='queued'). local_host = this
        // Mac is the executor; the captain just creates the queued row on edge.
        .task(id: crewStore.selectedDetail?.crew.id) { await autoClaimLoop() }
    }

    private var isRunning: Bool { sessionRunner.current?.status == .running }

    private var idleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            if crewStore.selectedDetail == nil {
                Text("先在左侧选一个 crew").foregroundStyle(.secondary)
            } else {
                Text("给 agent 下第一条指令，开始一个 session")
                    .foregroundStyle(.secondary)
                Text("用 crew 的默认工作目录与权限模式，无需任何配置")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if let localError {
                Text(localError).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                if !isRunning {
                    Picker("", selection: $selectedKind) {
                        Text("Claude Code").tag(LocalCodingAgentKind.claudeCode)
                        Text("Codex").tag(LocalCodingAgentKind.codex)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(starting)
                }
                TextField(isRunning ? "继续对 agent 说…（⌘↩ 发送）" : "下第一条指令开始…",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .disabled(starting || crewStore.selectedDetail == nil)
                    .onSubmit { Task { await send() } }
                Button {
                    Task { await send() }
                } label: {
                    if starting { ProgressView().controlSize(.small) }
                    else { Image(systemName: "paperplane.fill") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(starting || crewStore.selectedDetail == nil
                          || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    // MARK: - actions

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let run = sessionRunner.current, run.status == .running {
            // Running session → inject the text straight into the embedded
            // terminal (the agent's interactive prompt picks it up).
            run.send(text)
            draft = ""
        } else {
            await startSession(firstPrompt: text)
        }
    }

    /// Zero-config start: crew default dir + runner kind + permission mode, with
    /// `firstPrompt` as the initial turn. No title, no task brief. Replicates the
    /// logged server-link prep (register host → create → claim) so cross-device
    /// viewers can follow it; BYOK stays local. The first prompt is injected into
    /// the terminal once the agent's REPL is up.
    private func startSession(firstPrompt: String) async {
        guard let detail = crewStore.selectedDetail else { return }
        guard let wd = detail.crew.workingDirectory, !wd.isEmpty else {
            localError = "这个 crew 没有工作目录 —— 在建 crew 时设置后再开 session。"
            return
        }
        let dir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
        starting = true
        defer { starting = false }
        localError = nil

        var serverLink: CrewSessionServerLink? = nil
        if appModel.mode == .logged {
            do { serverLink = try await prepareServerSession(detail: detail, taskBrief: firstPrompt) }
            catch {
                localError = "服务端 session 准备失败: \(error.localizedDescription)"
                return
            }
        }
        if let sid = serverLink?.sessionId { handledSessionIds.insert(sid) }
        do {
            var cfg = SessionConfig(kind: selectedKind, initialPrompt: firstPrompt)
            // isolation=on → 独立 worktree;off → crew 共享目录（spec §8/§11）。
            let workdir = SessionWorkspace.resolve(
                crewDirectory: dir, isolation: cfg.isolation, hint: firstPrompt)
            // BYOK: 渲染本地世界观 → 临时 .md → claude --append-system-prompt-file
            // (spec local-first chunk 4)。logged 模式 edge 自己注入世界观,这里跳过；
            // best-effort,失败 nil 不挡 session 启动。
            // BYOK 本地 session 的合成 id —— 世界观 / mcp-config / hook settings 三处一致。
            let localSessionId = serverLink?.sessionId ?? UUID().uuidString.lowercased()
            cfg.appendSystemPromptFile = await renderWorldModelFile(
                detail: detail, taskBrief: firstPrompt, workdir: workdir, sessionId: localSessionId)
            // 本地 crew-comms 接线（BYOK）：MCP(post_to_crew/read_whiteboard) + hook(注入
            // 未读白板)。logged 模式 prepareLocalCommsConfig 返回 (nil,nil)（edge 管 comms）。
            let comms = prepareLocalCommsConfig(crewId: detail.crew.id, sessionId: localSessionId)
            cfg.settingsFile = comms.settings
            cfg.mcpConfigFile = comms.mcp
            try await sessionRunner.start(
                crewId: detail.crew.id,
                sessionId: localSessionId,
                config: cfg,
                workingDirectory: workdir,
                taskBrief: firstPrompt,
                serverLink: serverLink
            )
            // 指令已在 argv 里(positional prompt)—— 不再等 REPL 就绪 sleep + 事后注入。
            draft = ""
        } catch {
            localError = error.localizedDescription
        }
    }

    /// BYOK: 渲染本地世界观 system prompt → 临时 `.md` → 返回路径供
    /// `--append-system-prompt-file`。logged 模式返回 nil（edge 注入）。
    /// best-effort：任一步失败返 nil，session 仍照常启动（只是没世界观）。
    private func renderWorldModelFile(detail: CrewDetail, taskBrief: String, workdir: URL, sessionId: String) async -> String? {
        guard appModel.mode == .byok, let backend = appModel.backend else { return nil }
        let members = (try? await backend.listCrewMembers(crewId: detail.crew.id))?.members ?? []
        let humans = members
            .filter { $0.memberKind == "human" }
            .map { LocalSessionWorldModel.Human(
                displayName: $0.displayName ?? "(无名)", role: $0.role ?? "member", userId: $0.userId) }
        let ctx = LocalSessionWorldModel.Context(
            sessionTaskBrief: taskBrief,
            runnerKind: selectedKind == .claudeCode ? "claude_code" : "codex",
            sessionId: sessionId,
            crewId: detail.crew.id,
            crewTitle: detail.crew.title,
            workingDirectory: workdir.path,
            humans: humans,
            captainName: detail.captain?.displayName,
            captainBotId: detail.captain?.botId)
        guard let md = try? LocalSessionWorldModel().render(ctx) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingcrew-worldmodel-\(UUID().uuidString).md")
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }

    /// BYOK: 生成 per-session 的 settings.json（PostToolUse hook = 自身二进制 `--mcp-hook`，
    /// 每轮注入未读白板）+ mcp-config.json（自身二进制 `--mcp-serve`，post_to_crew/read_whiteboard）。
    /// helper = `Bundle.main.executablePath`（re-exec self：app 二进制兼当 helper，最自包含、
    /// 免 embed）；白板 dir = `LocalWhiteboardStore.defaultDirectory`（与 app/store 同一份）。
    /// logged 模式 / 任一步失败 → 对应 nil（session 仍启动，少 comms）。
    private func prepareLocalCommsConfig(crewId: String, sessionId: String) -> (settings: String?, mcp: String?) {
        guard appModel.mode == .byok, let helper = Bundle.main.executablePath
        else { return (nil, nil) }
        let dir = LocalWhiteboardStore.defaultDirectory.path
        let tmp = FileManager.default.temporaryDirectory

        // mcp-config：command + args 是 exec 形式（claude 直接 spawn，不过 shell）→ 不引号。
        let mcp: [String: Any] = ["mcpServers": ["crew": [
            "command": helper,
            "args": ["--mcp-serve", "--crew", crewId, "--dir", dir, "--session", sessionId],
        ]]]
        // settings：两个 hook 的 command 都是 shell 字符串（claude 过 sh -c）→ 引号每段。
        // PostToolUse：每轮注入未读白板。
        let hookCmd = [helper, "--mcp-hook", "--crew", crewId, "--dir", dir, "--session", sessionId]
            .map(shellQuote).joined(separator: " ")
        // PreToolUse：权限审批 gate（spec ask-approval §3「权限类直达人类」）。v1 默认只 gate
        // computer-use（敏感的桌面控制）；**不** gate 自家 crew 工具（post_to_crew/read_whiteboard/
        // ask 都 mcp__crew__ 前缀，子串不含 "computer-use"）。未来可做成 UI 可配 gate 列表。
        let permGates = "computer-use"
        let permCmd = [helper, "--mcp-permission-hook", "--crew", crewId, "--dir", dir, "--gate", permGates]
            .map(shellQuote).joined(separator: " ")
        let settings: [String: Any] = ["hooks": [
            "PostToolUse": [["hooks": [["type": "command", "command": hookCmd]]]],
            "PreToolUse": [["hooks": [["type": "command", "command": permCmd]]]],
        ]]

        return (
            settings: writeJSON(settings, to: tmp.appendingPathComponent("pendingcrew-settings-\(sessionId).json")),
            mcp: writeJSON(mcp, to: tmp.appendingPathComponent("pendingcrew-mcp-\(sessionId).json"))
        )
    }

    private func writeJSON(_ obj: [String: Any], to url: URL) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url.path
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - auto-claim (K: captain-created queued sessions)

    /// Poll the crew's server sessions; when the captain queues one (status=
    /// 'queued') and this Mac is free, claim it + run it locally with the crew's
    /// working dir. local_host: the captain (on edge) creates the row, this Mac
    /// executes. Logged mode only.
    private func autoClaimLoop() async {
        while !Task.isCancelled {
            if appModel.mode == .logged,
               let detail = crewStore.selectedDetail,
               sessionRunner.current == nil || sessionRunner.current?.status != .running,
               let api = try? appModel.loggedAPIClient(),
               let sessions = try? await api.listCrewSessions(crewId: detail.crew.id) {
                if let queued = sessions.first(where: { $0.status == "queued" && !handledSessionIds.contains($0.id) }) {
                    handledSessionIds.insert(queued.id) // claim-once guard before the await
                    await runQueuedSession(queued, detail: detail, api: api)
                }
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4s
        }
    }

    /// Claim + run an already-created (captain-queued) session. Mirrors the
    /// manual start but skips createSession (the row already exists).
    private func runQueuedSession(_ s: CrewSessionSummary, detail: CrewDetail, api: PendingCrewAPI) async {
        guard let wd = detail.crew.workingDirectory, !wd.isEmpty else { return }
        let dir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
        do {
            let subjects = try await api.listMySubjects()
            guard let subjectId = subjects.first?.id else { return }
            let hostId = try await appModel.ensureRunnerHost(
                api: api,
                subjectId: subjectId,
                allowedRunnerKinds: [
                    LocalCodingAgentKind.claudeCode.serverRunnerKind,
                    LocalCodingAgentKind.codex.serverRunnerKind,
                ]
            )
            _ = try await api.claimSession(runnerHostId: hostId, sessionId: s.id)
            let link = CrewSessionServerLink(api: api, runnerHostId: hostId, sessionId: s.id)
            let kind: LocalCodingAgentKind = s.runnerKind.contains("codex") ? .codex : .claudeCode
            try await sessionRunner.start(
                crewId: detail.crew.id,
                sessionId: s.id,
                config: SessionConfig(kind: kind, initialPrompt: s.taskBrief),
                workingDirectory: dir,
                taskBrief: s.taskBrief,
                serverLink: link
            )
            // taskBrief 已在 argv —— 不再 0.6s sleep + send(brief)。
        } catch {
            localError = "自动认领 session 失败: \(error.localizedDescription)"
            handledSessionIds.remove(s.id) // allow a retry next poll
        }
    }

    /// `taskBrief` is the session's first instruction — the edge requires a
    /// non-empty brief, and the first message is the natural one (no separate
    /// title/brief form, like Desktop naming a chat by its opening message).
    private func prepareServerSession(detail: CrewDetail, taskBrief: String) async throws -> CrewSessionServerLink {
        let api = try appModel.loggedAPIClient()
        let subjects = try await api.listMySubjects()
        guard let subjectId = subjects.first?.id else {
            throw PendingCrewBackendError.invalidConfig("没有可用的 subject（device grant 未解析出主体）")
        }
        let hostId = try await appModel.ensureRunnerHost(
            api: api,
            subjectId: subjectId,
            allowedRunnerKinds: [
                LocalCodingAgentKind.claudeCode.serverRunnerKind,
                LocalCodingAgentKind.codex.serverRunnerKind,
            ]
        )
        let sessionId = try await api.createSession(
            crewId: detail.crew.id,
            runnerKind: selectedKind.serverRunnerKind,
            taskBrief: taskBrief
        )
        _ = try await api.claimSession(runnerHostId: hostId, sessionId: sessionId)
        return CrewSessionServerLink(api: api, runnerHostId: hostId, sessionId: sessionId)
    }
}

/// 单个 run 的内容视图。`@ObservedObject` 订阅 run 的 `@Published`（status /
/// exitCode）驱动 header 刷新；内容区是内嵌的真终端（`AgentTerminalView`），
/// agent 的输出原样渲染、键盘直接可输入。
private struct SessionRunContentView: View {
    @ObservedObject var run: CrewSessionRun

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            AgentTerminalView(session: run.terminalSession)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: run.kind == .claudeCode ? "sparkles" : "wand.and.stars")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.kind.displayName)
                    .font(.callout.weight(.semibold))
                if !run.taskBrief.isEmpty {
                    Text(run.taskBrief)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            statusBadge(run.status, exitCode: run.exitCode)
            if run.status == .running {
                Button(role: .destructive) {
                    run.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusBadge(_ status: CrewSessionRun.Status, exitCode: Int32?) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .running: return ("running", .blue)
            case .completed:
                if let code = exitCode {
                    return code == 0 ? ("退出 0", .green) : ("退出 \(code)", .orange)
                }
                return ("已完成", .green)
            case .cancelled: return ("已取消", .secondary)
            case .failed:
                if let code = exitCode {
                    return ("失败 \(code)", .red)
                }
                return ("失败", .red)
            }
        }()
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
#endif
