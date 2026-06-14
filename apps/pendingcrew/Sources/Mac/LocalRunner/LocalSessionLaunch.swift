#if os(macOS)
import Foundation

/// 本地起 session 的共享准备工序（#242 提取自 CrewSessionWindowView）：
/// 手动起（CrewSessionWindowView）与 relay task_request 自动起（CrewRelayAgent）
/// 用同一份 —— comms 接线 / 世界观渲染不分叉。
enum LocalSessionLaunch {
    /// 机长起不来的可恢复错误（建 crew 自动起兜底/手动按钮共用）。
    enum CaptainLaunchError: LocalizedError {
        case noWorkingDirectory
        var errorDescription: String? {
            switch self {
            case .noWorkingDirectory:
                return "这个 crew 没有工作目录 —— 在建 crew 时设置后再启动 Captain。"
            }
        }
    }

    /// 启动机长 session —— 手动按钮、建 crew 自动起共用这一份（单一事实源）。
    /// 已有在跑的 captain 直接返回（每 crew 同时只允许一个，防重）。无工作目录抛错。
    ///
    /// captain 与 worker 的差异只有两点:世界观后追加 captain persona
    /// （`crew-captain.zh.md`），MCP helper 带 `--captain` 解锁 answer_decision
    /// （chunk2 §2）。机长是调度者不改代码 —— 直接用 crew 目录,不开 isolation worktree。
    /// `initialPrompt` 让它读白板 + `post_to_crew` 报到一句 —— "建 crew 即在群里发消息"
    /// 走这条（不另写代码发系统消息，保持白板由 agent 自己写的一致语义）。
    @MainActor
    static func startCaptain(
        detail: CrewDetail,
        runner: CrewSessionRunner,
        backend: PendingCrewBackend?
    ) async throws {
        let crewId = detail.crew.id
        guard !runner.runs.contains(where: {
            $0.crewId == crewId && $0.role == .captain && $0.status == .running
        }) else { return }
        guard let wd = detail.crew.workingDirectory, !wd.isEmpty else {
            throw CaptainLaunchError.noWorkingDirectory
        }
        let workdir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
        let localSessionId = "captain-" + String(UUID().uuidString.lowercased().prefix(8))
        let initialPrompt = "你是本 crew 的机长。先用 read_whiteboard 了解群聊现状，然后简短报到（post_to_crew 一句）并待命。后续有待决策会通知你。"
        // persona / members best-effort：加载失败不挡启动（只是少人设/世界观，与 worker 同策略）。
        let persona = try? LocalPromptLoader().rawTemplate(name: "crew-captain", locale: "zh")
        let members = (try? await backend?.listCrewMembers(crewId: crewId))?.members ?? []
        var cfg = SessionConfig(kind: .claudeCode, initialPrompt: initialPrompt)
        cfg.appendSystemPromptFile = renderWorldModelFile(
            detail: detail, members: members, taskBrief: initialPrompt, workdir: workdir,
            sessionId: localSessionId, runnerKind: .claudeCode, appendPersona: persona)
        let comms = prepareLocalCommsConfig(crewId: crewId, sessionId: localSessionId, captain: true)
        cfg.settingsFile = comms.settings
        cfg.mcpConfigFile = comms.mcp
        try await runner.start(
            crewId: crewId,
            sessionId: localSessionId,
            config: cfg,
            workingDirectory: workdir,
            taskBrief: initialPrompt,
            role: .captain
        )
    }

    /// 生成 per-session 的 settings.json（PostToolUse hook = 自身二进制 `--mcp-hook`，
    /// 每轮注入未读白板）+ mcp-config.json（自身二进制 `--mcp-serve`，post_to_crew/read_whiteboard）。
    /// helper = `Bundle.main.executablePath`（re-exec self：app 二进制兼当 helper，最自包含、
    /// 免 embed）；白板 dir = `LocalWhiteboardStore.defaultDirectory`（与 app/store 同一份）。
    /// 接合 v2：comms 恒为本地，不再按 mode 跳过。任一步失败 → 对应 nil（session 仍启动，少 comms）。
    static func prepareLocalCommsConfig(
        crewId: String, sessionId: String, captain: Bool = false
    ) -> (settings: String?, mcp: String?) {
        guard let helper = Bundle.main.executablePath
        else { return (nil, nil) }
        let dir = LocalWhiteboardStore.defaultDirectory.path
        let tmp = FileManager.default.temporaryDirectory

        // mcp-config：command + args 是 exec 形式（claude 直接 spawn，不过 shell）→ 不引号。
        // captain → 多带 --captain，helper 端解锁机长专用 answer_decision（chunk2 T4）。
        var serveArgs = ["--mcp-serve", "--crew", crewId, "--dir", dir, "--session", sessionId]
        if captain { serveArgs.append("--captain") }
        let mcp: [String: Any] = ["mcpServers": ["crew": [
            "command": helper,
            "args": serveArgs,
        ]]]
        // settings：两个 hook 的 command 都是 shell 字符串（claude 过 sh -c）→ 引号每段。
        // PostToolUse：每轮注入未读白板。
        let hookCmd = [helper, "--mcp-hook", "--crew", crewId, "--dir", dir, "--session", sessionId]
            .map(shellQuote).joined(separator: " ")
        // PreToolUse：权限审批 gate（spec ask-approval §3「权限类直达人类」）。v1 默认只 gate
        // computer-use（敏感的桌面控制）；**不** gate 自家 crew 工具（post_to_crew/read_whiteboard/
        // ask 都 mcp__crew__ 前缀，子串不含 "computer-use"）。未来可做成 UI 可配 gate 列表。
        let permGates = "computer-use"
        // --session 必带：权限待审批归档在**本地** sessionId 下，右栏内联卡片才过滤得到
        // （不能用 PreToolUse hook stdin 里 claude 自己的 session_id）。
        let permCmd = [helper, "--mcp-permission-hook", "--crew", crewId, "--dir", dir,
                       "--session", sessionId, "--gate", permGates]
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

    /// 渲染本地世界观 system prompt → 临时 `.md` → 返回路径供
    /// `--append-system-prompt-file`。best-effort：任一步失败返 nil，session
    /// 仍照常启动（只是没世界观）。`appendPersona` 非 nil 时（captain session）
    /// 把 persona 拼到世界观后面。members 由 caller 拉好传入（view 用 backend、
    /// relay agent 同样走 backend）。
    static func renderWorldModelFile(
        detail: CrewDetail,
        members: [CrewMember],
        taskBrief: String,
        workdir: URL,
        sessionId: String,
        runnerKind: LocalCodingAgentKind,
        appendPersona: String? = nil
    ) -> String? {
        let humans = members
            .filter { $0.memberKind == "human" }
            .map { LocalSessionWorldModel.Human(
                displayName: $0.displayName ?? "(无名)", role: $0.role ?? "member", userId: $0.userId) }
        let ctx = LocalSessionWorldModel.Context(
            sessionTaskBrief: taskBrief,
            runnerKind: runnerKind == .claudeCode ? "claude_code" : "codex",
            sessionId: sessionId,
            crewId: detail.crew.id,
            crewTitle: detail.crew.title,
            workingDirectory: workdir.path,
            humans: humans,
            captainName: detail.captain?.displayName,
            captainBotId: detail.captain?.botId)
        guard var md = try? LocalSessionWorldModel().render(ctx) else { return nil }
        if let persona = appendPersona {
            md += "\n\n---\n\n" + persona
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingcrew-worldmodel-\(UUID().uuidString).md")
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }

    private static func writeJSON(_ obj: [String: Any], to url: URL) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url.path
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
