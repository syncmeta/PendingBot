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
    /// chunk2 T5（captain 唤醒=app 注入）：已通知过 captain 的 decision id ——
    /// 防止每个 tick 重复注入同一条待决策。
    @State private var notifiedDecisionIds: Set<String> = []
    /// 跨进程轮询（helper 写 LocalApprovalStore 文件、本进程读）—— 2s 检查
    /// 新待决策并注入 captain PTY。与 SessionApprovalCardsView 的 1.5s 同套路。
    private let captainTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    /// 未读角标的轻量刷新计数（chunk2 T6）—— 每个 tick 自增，逼 badgeCount 重算。
    @State private var badgeTick = 0

    /// spec §9.3 + 用户心智：右栏是**常驻**和 claude/codex 交互的面（像 Codex
    /// Desktop）。没有 session 时就地给一个 composer —— **第一条消息即开始
    /// session**（零配置，用 crew 默认目录/runner/权限模式；无标题、无单独的
    /// 「新建」表单）。运行中再发 = 直接把文本注入终端续聊。
    var body: some View {
        VStack(spacing: 0) {
            // 选中 crew 就渲染 —— 零 run 时也得有 ⚓ 启动 Captain 入口
            // （旧条件 !runs.isEmpty 让启动按钮在空列表时根本不可达）。
            if crewStore.selectedDetail != nil {
                sessionBar
                Divider()
            }
            if let run = sessionRunner.current {
                // `.id(run.runID)` 强制换 run 时整个终端视图重建 —— 否则 SwiftUI
                // 复用同一个 NSViewRepresentable，切换条点了终端不换。
                SessionRunContentView(run: run)
                    .id(run.runID)
                // 内联待办卡片：本 session 调 ask / 撞权限被拦时，就地答（写 LocalApprovalStore
                // 解 helper 的 long-poll）。接合 v2：comms/审批恒为本地，不再按 mode 门禁。
                SessionApprovalCardsView(crewId: run.crewId, sessionId: run.sessionId)
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
        // chunk2 T5：captain 唤醒 = app 注入。本地 BYOK 模式下轮询待决策，
        // 有新的（非 captain 自己 raise 的）就把提示注入 captain 的 PTY。
        .onReceive(captainTick) { _ in
            notifyCaptainOfNewDecisions()
            badgeTick &+= 1 // 未读角标随同一拍刷新（T6）
        }
        // 切前台 = 看过了：清掉新选中 run 的未读（T6）。
        .onChange(of: sessionRunner.selectedRunId) { _, newId in
            if let run = sessionRunner.runs.first(where: { $0.runID == newId }) {
                SessionUnreadStore.shared.markViewed(run.sessionId)
            }
        }
    }

    /// chunk2 T5：发现新待决策 → 注入运行中的 captain session（spec §2 唤醒=app 注入）。
    /// 没有在跑的 captain 就什么都不做（等 captain 启动后第一个 tick 再补通知）。
    private func notifyCaptainOfNewDecisions() {
        guard let crewId = crewStore.selectedDetail?.crew.id,
              let captainRun = sessionRunner.runs.first(where: {
                  $0.crewId == crewId && $0.role == .captain && $0.status == .running
              })
        else { return }
        let items = LocalApprovalStore.shared.pending(crewId: crewId).filter {
            $0.kind == "decision"
                && $0.sessionId != captainRun.sessionId
                && !notifiedDecisionIds.contains($0.id)
        }
        for item in items {
            captainRun.send("有新的待决策 #\(item.id)（来自 session \(item.sessionId)）：\(item.summary)\n能拍板就用 answer_decision 工具答它（reqId=\(item.id)）；拍不了就用 post_to_crew 发消息 @human 说明需要人类决策的理由与你的建议。")
            notifiedDecisionIds.insert(item.id)
        }
    }

    private var isRunning: Bool { sessionRunner.current?.status == .running }

    // MARK: - session bar (chunk2 T2)

    /// 当前选中 crew 的 runs，captain 置顶，其余按启动顺序。
    private var barRuns: [CrewSessionRun] {
        let crewId = crewStore.selectedDetail?.crew.id
        let runs = sessionRunner.runs.filter { $0.crewId == crewId }
        return runs.filter { $0.role == .captain } + runs.filter { $0.role != .captain }
    }

    /// 未读数（chunk2 T6）：本 session 的 pending 待办 + 上次查看后该 session
    /// 发的白板消息。`badgeTick` 由 2s 轮询 bump，强制重算（store 数据在文件里，
    /// 没有 ObservableObject 推送）。前台选中的 run 不显角标（看着呢）。
    private func badgeCount(for run: CrewSessionRun) -> Int {
        _ = badgeTick // 依赖 tick，让 SwiftUI 每 2s 重算一次
        if run.runID == sessionRunner.selectedRunId { return 0 }
        return SessionUnreadStore.shared.unreadCount(
            crewId: run.crewId, sessionId: run.sessionId,
            approvals: .shared, whiteboard: .shared)
    }

    /// 横向滚动的 session 切换条：每个 run 一个 capsule（名字 + 状态点 +
    /// 未读 badge 占位），点击切前台；已退出的带 ✕ 可移除。
    /// 选中 crew 是否已有在跑的 captain run（启动按钮的显隐 + startCaptain 防重）。
    private var hasRunningCaptain: Bool {
        guard let crewId = crewStore.selectedDetail?.crew.id else { return false }
        return sessionRunner.runs.contains {
            $0.crewId == crewId && $0.role == .captain && $0.status == .running
        }
    }

    private var sessionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if crewStore.selectedDetail != nil && !hasRunningCaptain {
                    Button {
                        Task { await startCaptain() }
                    } label: {
                        Text("⚓ 启动 Captain")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.indigo)
                    .controlSize(.small)
                    .disabled(starting)
                    .help("起一个机长 session：读白板、报到、答复待决策")
                }
                ForEach(barRuns) { run in
                    SessionBarItemView(
                        run: run,
                        isSelected: run.runID == sessionRunner.selectedRunId,
                        badgeCount: badgeCount(for: run),
                        select: { sessionRunner.select(run.runID) },
                        remove: { sessionRunner.remove(run.runID) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

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

        // 接合 v2：本地 crew id 不再对应 edge 的 crew 行，server link（跨设备
        // 遥控可跟看）在 block 3（信箱）重建本地↔edge 绑定后再启用 ——
        // 此前恒为 nil，prepareServerSession 保留不删，届时复用。
        let serverLink: CrewSessionServerLink? = nil
        if let sid = serverLink?.sessionId { handledSessionIds.insert(sid) }
        do {
            var cfg = SessionConfig(kind: selectedKind, initialPrompt: firstPrompt)
            // isolation=on → 独立 worktree;off → crew 共享目录（spec §8/§11）。
            let workdir = SessionWorkspace.resolve(
                crewDirectory: dir, isolation: cfg.isolation, hint: firstPrompt)
            // 渲染本地世界观 → 临时 .md → claude --append-system-prompt-file
            // (spec local-first chunk 4)。接合 v2：恒为本地渲染（不再有"logged
            // 由 edge 注入"的分叉）；best-effort,失败 nil 不挡 session 启动。
            // 本地 session 的合成 id —— 世界观 / mcp-config / hook settings 三处一致。
            let localSessionId = serverLink?.sessionId ?? UUID().uuidString.lowercased()
            cfg.appendSystemPromptFile = await renderWorldModelFile(
                detail: detail, taskBrief: firstPrompt, workdir: workdir, sessionId: localSessionId)
            // 本地 crew-comms 接线：MCP(post_to_crew/read_whiteboard) + hook(注入
            // 未读白板)。接合 v2：comms 恒为本地，无论登没登录。
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

    /// 启动机长 session（chunk2 T3）。与 worker 的差异只有两点：世界观后追加
    /// captain persona（`crew-captain.zh.md`），MCP helper 带 `--captain` 解锁
    /// answer_decision。机长是调度者不改代码 —— 直接用 crew 目录，不开 isolation
    /// worktree。每 crew 同时只允许一个在跑的 captain。
    private func startCaptain() async {
        guard let detail = crewStore.selectedDetail else { return }
        guard !hasRunningCaptain else { return }
        guard let wd = detail.crew.workingDirectory, !wd.isEmpty else {
            localError = "这个 crew 没有工作目录 —— 在建 crew 时设置后再启动 Captain。"
            return
        }
        let workdir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
        starting = true
        defer { starting = false }
        localError = nil

        let localSessionId = "captain-" + String(UUID().uuidString.lowercased().prefix(8))
        let initialPrompt = "你是本 crew 的机长。先用 read_whiteboard 了解群聊现状，然后简短报到（post_to_crew 一句）并待命。后续有待决策会通知你。"
        // persona best-effort：加载失败不挡启动（只是没机长人设，与世界观同策略）。
        let persona = try? LocalPromptLoader().rawTemplate(name: "crew-captain", locale: "zh")
        do {
            var cfg = SessionConfig(kind: .claudeCode, initialPrompt: initialPrompt)
            cfg.appendSystemPromptFile = await renderWorldModelFile(
                detail: detail, taskBrief: initialPrompt, workdir: workdir,
                sessionId: localSessionId, appendPersona: persona)
            let comms = prepareLocalCommsConfig(
                crewId: detail.crew.id, sessionId: localSessionId, captain: true)
            cfg.settingsFile = comms.settings
            cfg.mcpConfigFile = comms.mcp
            try await sessionRunner.start(
                crewId: detail.crew.id,
                sessionId: localSessionId,
                config: cfg,
                workingDirectory: workdir,
                taskBrief: initialPrompt,
                role: .captain
            )
        } catch {
            localError = error.localizedDescription
        }
    }

    /// 渲染本地世界观 system prompt → 临时 `.md` → 返回路径供
    /// `--append-system-prompt-file`。接合 v2：恒为本地渲染（无 mode 分叉）。
    /// best-effort：任一步失败返 nil，session 仍照常启动（只是没世界观）。
    /// `appendPersona` 非 nil 时（captain session）把 persona 拼到世界观后面 ——
    /// captain 与 worker 的差异只是「追加 persona + --captain 工具门禁」（chunk2 §2）。
    /// 渲染 + comms 接线的实现提取到 `LocalSessionLaunch`（#242：CrewRelayAgent
    /// 自动起 session 与这里走同一份工序）。这俩 wrapper 只补 view 持有的依赖
    /// （backend 拉 members、selectedKind）。
    private func renderWorldModelFile(detail: CrewDetail, taskBrief: String, workdir: URL, sessionId: String,
                                      appendPersona: String? = nil) async -> String? {
        guard let backend = appModel.backend else { return nil }
        let members = (try? await backend.listCrewMembers(crewId: detail.crew.id))?.members ?? []
        return LocalSessionLaunch.renderWorldModelFile(
            detail: detail, members: members, taskBrief: taskBrief, workdir: workdir,
            sessionId: sessionId, runnerKind: selectedKind, appendPersona: appendPersona)
    }

    private func prepareLocalCommsConfig(crewId: String, sessionId: String,
                                         captain: Bool = false) -> (settings: String?, mcp: String?) {
        LocalSessionLaunch.prepareLocalCommsConfig(crewId: crewId, sessionId: sessionId, captain: captain)
    }

    // MARK: - auto-claim (K: captain-created queued sessions)

    /// Poll the crew's server sessions; when something queues one on edge (e.g.
    /// remote control from the phone, status='queued') and this Mac is free,
    /// claim it + run it locally with the crew's working dir. 登录态能力叠加,
    /// gate 用 isAuthenticated。
    /// 接合 v2：本地 crew 与 edge 队列的绑定在 block 3（信箱）重建后再启用 ——
    /// 本地 crew id 目前在 edge 没有对应行，轮询只会空转。loop 保留不删，届时翻开关。
    private var edgeQueueBindingReady: Bool { false }

    private func autoClaimLoop() async {
        guard edgeQueueBindingReady else { return }
        while !Task.isCancelled {
            if appModel.isAuthenticated,
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

/// 切换条上的单个 session 项。`@ObservedObject` 订阅 run 的 `@Published status`
/// 驱动状态点/✕（嵌套 ObservableObject —— 父 view 观察不到 run 自己的变更）。
private struct SessionBarItemView: View {
    @ObservedObject var run: CrewSessionRun
    let isSelected: Bool
    let badgeCount: Int
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(run.status == .running ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
            Text(run.displayName)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
            if badgeCount > 0 {
                Text("\(badgeCount)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            if run.status != .running {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("移除这个 session")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(
                isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        )
        .contentShape(Capsule())
        .onTapGesture(perform: select)
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
