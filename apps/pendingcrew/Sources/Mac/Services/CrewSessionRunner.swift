#if os(macOS)
import Combine
import Foundation
import SwiftUI

/// Bridges a local `CrewSessionRun` to its server-side `crew_sessions` row so
/// cross-device viewers can see a session exists + when it ends. Logged mode
/// only; BYOK runs pass `nil` and stay purely local.
///
/// **Phase 1 scope**: just the row lifecycle close (`finish`). The structured
/// per-event transcript mirror + the realtime SessionProxy socket were ripped
/// out with the one-shot runner — Phase 2 rebuilds live cross-device control as
/// a raw byte tunnel over the embedded terminal's PTY, not as parsed events.
///
/// **Best-effort**: the server call is `try?`'d — a failure (network blip,
/// scope gap, evicted lease) is logged but never disrupts the local agent
/// process. The local run is always the source of truth for the user.
struct CrewSessionServerLink: Sendable {
    let api: PendingCrewAPI
    let runnerHostId: String
    let sessionId: String

    /// Close out the server session row. `localStatus` is the run's terminal
    /// state mapped to the server's completed/failed/cancelled enum.
    func finish(localStatus: CrewSessionRun.Status, summary: String?) async {
        let status: String
        switch localStatus {
        case .completed: status = "completed"
        case .cancelled: status = "cancelled"
        default: status = "failed"
        }
        do {
            try await api.finishSession(
                runnerHostId: runnerHostId,
                sessionId: sessionId,
                status: status,
                summary: summary
            )
        } catch {
            print("[crew-session] finish failed: \(error)")
        }
    }
}

/// local coding agent 跑动的 view-side 视图模型（chunk2 T1：多 run 并存）。
///
/// 每次 `start(...)` 起一个新 `CrewSessionRun` 追加进 `runs` 并选中——旧 run
/// **不再**被自动停掉，N 个 session 并行各自跑各自的 PTY；上限 6 个 running。
/// 右栏 session 切换条（T2）靠 `selectedRunId` 决定哪个 run 在前台。
///
/// 每个 run 内嵌一个真 PTY 终端（`AgentTerminalSession`），跑交互式
/// claude/codex（自动审批）。读=终端原样渲染；控=键盘 + 程序化 send/stop。
@MainActor
final class CrewSessionRunner: ObservableObject {
    @Published private(set) var runs: [CrewSessionRun] = []
    @Published var selectedRunId: UUID?

    /// 「新建 session」态：inspector 显示零配置 composer 而非某个 run。由 roster /
    /// 切换条的「+」置 true，启动成功或切到某个 run 时复位。UI 选择态（与
    /// `selectedRunId` 同类），放这里让 roster（开 inspector 的一端）与 inspector
    /// composer（消费的一端）无需额外 binding 即可共享。
    @Published var isComposingNew = false

    /// inspector 内的模式开关：`false`=成员列表模式（平时看 roster + 待审批），
    /// `true`=终端模式（看某个 session 的终端 + composer）。点 session 行 / 起新
    /// session 翻 true；inspector 顶「‹ 成员」返回翻 false。toolbar 的「Session 终端」
    /// 开关只翻 inspector 呈现态，不强制 true —— 让用户先落在成员列表。
    @Published var viewingTerminal = false

    /// 前台 run：选中的那个；没选中（或选中的已被移除）时回退最后一个。
    /// 保留这个名字让既有 call site（composer / auto-claim）继续编译。
    var current: CrewSessionRun? {
        runs.first { $0.runID == selectedRunId } ?? runs.last
    }

    /// 同时 running 的 session 上限（资源护栏）。
    static let maxConcurrentRuns = 6

    init() {}

    /// 切换前台 run（退出「新建」态）。
    func select(_ runId: UUID) {
        selectedRunId = runId
        isComposingNew = false
    }

    /// 进入「新建 session」态（composer 显零配置启动面）。
    func composeNew() {
        isComposingNew = true
    }

    /// 停掉指定 run（保留在列表里，状态落 cancelled）。
    func stop(_ runId: UUID) {
        runs.first { $0.runID == runId }?.stop()
    }

    /// 移除指定 run（仍在跑则先停）。被移除的是选中项时，回退选最后一个。
    func remove(_ runId: UUID) {
        guard let idx = runs.firstIndex(where: { $0.runID == runId }) else { return }
        let run = runs[idx]
        if run.status == .running { run.stop() }
        runs.remove(at: idx)
        if selectedRunId == runId {
            selectedRunId = runs.last?.runID
        }
    }

    /// 起一个新 session。pre-flight 失败抛错（工具未装 / 超并发上限）。成功后
    /// 把新 run 追加进 `runs` 并选中；agent 在内嵌终端里交互式跑，旧 run 不受影响。
    func start(
        crewId: String,
        /// 本 session 的合成 id（BYOK localSessionId / logged 服务端 id）—— 存到 run 上，
        /// 右栏内联待办卡片靠它从 `LocalApprovalStore` 过滤出本 session 的待决策/待审批。
        sessionId: String,
        /// 完整的 per-session 启动配置（kind / model / effort / initialPrompt /
        /// permissionMode）—— argv 由 `config.argv()` 构建（spec §1/§11）。
        config: SessionConfig,
        workingDirectory: URL,
        taskBrief: String,
        additionalEnv: [String: String] = [:],
        /// 当登录时，caller 备好 server-side session（register host → create →
        /// claim）并把 link 传进来，run 在结束时关掉 server row（让跨端列表能看到
        /// session 已结束）。`nil` = BYOK / local-only。
        serverLink: CrewSessionServerLink? = nil,
        /// codex 世界观（字符串）→ `thread/start.developerInstructions`。caller 在
        /// 拿得到 detail/members 处用 `LocalSessionLaunch.renderWorldModelString` 算好传入。
        /// claude 不用这个 —— claude 走 `config.appendSystemPromptFile`（文件路径）。
        developerInstructions: String? = nil,
        /// codex crew MCP 配置 dict → `thread/start.mcpServers`。caller 用
        /// `LocalSessionLaunch.codexMcpServers` 算好传入。claude 不用 —— 走
        /// `config.mcpConfigFile`（文件路径）。
        codexMcpServers: [String: Any]? = nil,
        /// captain / worker 角色标记（session 切换条展示 + captain 置顶）。
        role: CrewSessionRun.Role = .worker
    ) async throws {
        // 0. 并发上限护栏 —— running 的 run 不超过 maxConcurrentRuns。
        guard runs.filter({ $0.status == .running }).count < Self.maxConcurrentRuns else {
            throw RunnerError.tooManySessions
        }
        // 1. 校验工具可用 + resolve 可执行路径
        guard let executable = LocalCodingAgentExecutable.resolve(config.kind) else {
            throw RunnerError.toolNotInstalled(kind: config.kind)
        }
        // 2. env 白名单（spec v2 §8.4.2）—— 复用 spec 的纯函数构造。
        let env = LocalCodingAgentEnv.build(additionalEnv: additionalEnv, kind: config.kind)
        // 3. 按 kind 选后端：claude = 内嵌真 PTY 终端；codex = app-server（stdio JSON-RPC）。
        let backend: any SessionBackend
        switch config.kind {
        case .claudeCode:
            backend = AgentTerminalSession(
                config: config,
                executable: executable.path,
                workdir: workingDirectory.path,
                env: env
            )
        case .codex:
            // codex 没有 claude 的 hook/settings 通道：世界观经 developerInstructions、
            // MCP 经 mcpServers dict、白板每轮经 additionalContext、审批经 server request。
            // 后两者用 in-process provider 复用同一份本地 store（与 claude 的 helper 子进程
            // 读写同一份白板/审批 JSON —— 右栏内联卡片 / 群聊白板对齐）。
            let cb = CodexAppServerBackend(
                executable: executable.path,
                argv: config.argv(),
                cwd: workingDirectory.path,
                env: env,
                model: config.model,
                developerInstructions: developerInstructions,
                mcpServers: codexMcpServers,
                whiteboardProvider: Self.makeWhiteboardProvider(crewId: crewId, sessionId: sessionId),
                approvalProvider: Self.makeApprovalProvider(crewId: crewId, sessionId: sessionId))
            cb.boot(initialPrompt: config.initialPrompt)
            backend = cb
        }
        // 4. 包成 view model
        let run = CrewSessionRun(
            crewId: crewId,
            sessionId: sessionId,
            kind: config.kind,
            taskBrief: taskBrief,
            workingDirectory: workingDirectory,
            model: config.model,
            permissionModeOverride: config.permissionMode,
            backend: backend,
            serverLink: serverLink,
            role: role
        )
        // 多 run 并存：追加 + 选中，不动旧 run（每个 run 在切换条上都有自己的
        // 停止/移除入口，不会变 orphan）。
        runs.append(run)
        selectedRunId = run.runID
        isComposingNew = false
    }

    // MARK: - codex backend providers

    /// codex 每轮 turn 前注入未读白板的 provider —— 复用 claude PostToolUse hook 的
    /// 同一份 `HookEmitter`（per-session 游标读未读 + 渲染 + 推进游标），区别只是
    /// 这里在 app 进程内直接调，不经 helper 子进程。返回的字符串塞进
    /// `turn/start.additionalContext`。无未读 → nil（不注入）。best-effort：
    /// 任何失败（store 读不出 / 渲染失败）→ nil，turn 照常跑（只是这轮没白板）。
    nonisolated static func makeWhiteboardProvider(crewId: String, sessionId: String) -> () -> String? {
        let dir = LocalWhiteboardStore.defaultDirectory
        return {
            let emitter = HookEmitter(
                store: LocalWhiteboardStore(directory: dir),
                crewId: crewId, sessionId: sessionId, cursorDir: dir)
            // HookEmitter 吐的是 claude hook 信封 JSON；codex 这边只要里头的纯文本
            // additionalContext，剥一层拿渲染好的未读串。
            guard let json = emitter.emitAndAdvance(),
                  let data = json.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let hook = obj["hookSpecificOutput"] as? [String: Any],
                  let ctx = hook["additionalContext"] as? String, !ctx.isEmpty
            else { return nil }
            return ctx
        }
    }

    /// codex 审批 provider —— 镜像 `McpPermissionHook` 的 raise→long-poll→answer，
    /// 但在 app 进程内异步等（不阻塞线程）。codex 经 server request 发来审批，
    /// 这里 raise 一条 `permission` 待审批（归档在本 sessionId 下，右栏内联卡片
    /// 据此过滤）+ 通知半边贴本地白板，再 poll `LocalApprovalStore` 直到人类在待审批
    /// 列表 allow/deny。映射：allow→"accept"，deny / 超时→"decline"（安全侧 fail-safe）。
    /// 超时取 `McpPermissionHook` 一样保守的兜底（v1 不设硬等人上限，但 in-process
    /// 异步等设一个长上限防 turn 永久挂死）。
    nonisolated static func makeApprovalProvider(
        crewId: String, sessionId: String
    ) -> (_ summary: String, _ decisions: [String]) async -> String {
        let dir = LocalWhiteboardStore.defaultDirectory
        return { summary, decisions in
            let approvals = LocalApprovalStore(directory: dir)
            let board = LocalWhiteboardStore(directory: dir)
            let reqId = approvals.raise(
                crewId: crewId, kind: "permission", sessionId: sessionId, summary: summary)
            // 通知半边（与 McpPermissionHook 一致）：贴本地群聊白板，人类在 crew chat
            // 看得见有新审批请求。
            board.appendSessionMessage(
                crewId: crewId, sessionId: sessionId,
                text: "🔔 待审批：\(summary)\n（请在 PendingCrew 待审批列表里 allow / deny）",
                category: "question")
            // long-poll：0.5s 一拍，最多等 ~30min 后保守判 deny（防 turn 永久挂）。
            let pollInterval: UInt64 = 500_000_000 // 0.5s
            let maxWaits = 3600
            var waits = 0
            let chosen: String = await {
                while waits < maxWaits {
                    if let it = approvals.item(crewId: crewId, id: reqId), it.status == "answered" {
                        return it.decision == "allow" ? "allow" : "deny"
                    }
                    try? await Task.sleep(nanoseconds: pollInterval)
                    waits += 1
                }
                return "deny" // 超时 → 安全侧拒绝
            }()
            // 映射到 codex decision —— allow→accept，其余→decline（若 codex 没声明
            // accept/decline 而是别的可选项，退回它声明的第一个/末一个作 fail-safe）。
            if chosen == "allow" {
                return decisions.contains("accept") ? "accept" : (decisions.first ?? "accept")
            } else {
                return decisions.contains("decline") ? "decline" : (decisions.last ?? "decline")
            }
        }
    }

    enum RunnerError: LocalizedError {
        case toolNotInstalled(kind: LocalCodingAgentKind)
        case tooManySessions
        case captainNoWorkingDirectory

        var errorDescription: String? {
            switch self {
            case .toolNotInstalled(let kind):
                return "未在 PATH 中找到 \(kind.binaryName)，请先安装 \(kind.displayName) CLI。"
            case .tooManySessions:
                return "同时运行的 session 已达上限（6），先停掉一些再开。"
            case .captainNoWorkingDirectory:
                return "这个 crew 没有工作目录 —— 在建 crew 时设置后再启动 Captain。"
            }
        }
    }

    /// 启动机长 session —— 手动按钮、建 crew 自动起共用这一份（单一事实源）。
    /// 已有在跑的 captain 直接返回（每 crew 同时只允许一个，防重）。无工作目录抛错。
    ///
    /// captain 与 worker 的差异只有两点：世界观后追加 captain persona
    /// （`crew-captain.zh.md`），MCP helper 带 `--captain` 解锁 answer_decision
    /// （chunk2 §2）。机长是调度者不改代码 —— 直接用 crew 目录，不开 isolation worktree。
    /// `initialPrompt` 让它读白板 + `post_to_crew` 报到一句 ——「建 crew 即在群里发消息」
    /// 走这条（不另写代码发系统消息，保持白板由 agent 自己写的一致语义）。
    /// 渲染世界观要 roster → 用传入的 `backend` 拉（best-effort，失败照样启动）。
    func startCaptain(detail: CrewDetail, backend: PendingCrewBackend?) async throws {
        let crewId = detail.crew.id
        guard !runs.contains(where: {
            $0.crewId == crewId && $0.role == .captain && $0.status == .running
        }) else { return }
        guard let wd = detail.crew.workingDirectory, !wd.isEmpty else {
            throw RunnerError.captainNoWorkingDirectory
        }
        let workdir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
        let localSessionId = "captain-" + String(UUID().uuidString.lowercased().prefix(8))
        let initialPrompt = "你是本 crew 的机长。先用 read_whiteboard 了解群聊现状，然后简短报到（post_to_crew 一句）并待命。后续有待决策会通知你。"
        // persona / members best-effort：加载失败不挡启动（只是少人设/世界观，与 worker 同策略）。
        let persona = try? LocalPromptLoader().rawTemplate(name: "crew-captain", locale: "zh")
        let members = (try? await backend?.listCrewMembers(crewId: crewId))?.members ?? []
        // 机长用建 crew 时选定的 coding agent（crew 没记 → 默认 Codex）。
        let captainKind = LocalCodingAgentKind.captainDefault(detail.crew.captainAgentKind)
        var cfg = SessionConfig(kind: captainKind, initialPrompt: initialPrompt)
        // 世界观 + crew 工具按 kind 分流：claude 走文件 flag（appendSystemPromptFile +
        // settings/mcp-config），codex 走 app-server 通道（developerInstructions 字符串 +
        // mcpServers dict）。captain 两边都带（persona 追加 + helper `--captain` 解锁
        // answer_decision）。**默认 captain = codex**（captainDefault），所以 codex 这支必须接对，
        // 否则机长无世界观、无 crew 工具。
        var developerInstructions: String? = nil
        var codexMcpServers: [String: Any]? = nil
        switch captainKind {
        case .claudeCode:
            cfg.appendSystemPromptFile = LocalSessionLaunch.renderWorldModelFile(
                detail: detail, members: members, taskBrief: initialPrompt, workdir: workdir,
                sessionId: localSessionId, runnerKind: captainKind, appendPersona: persona)
            let comms = LocalSessionLaunch.prepareLocalCommsConfig(
                crewId: crewId, sessionId: localSessionId, captain: true)
            cfg.settingsFile = comms.settings
            cfg.mcpConfigFile = comms.mcp
        case .codex:
            developerInstructions = LocalSessionLaunch.renderWorldModelString(
                detail: detail, members: members, taskBrief: initialPrompt, workdir: workdir,
                sessionId: localSessionId, appendPersona: persona)
            codexMcpServers = LocalSessionLaunch.codexMcpServers(
                crewId: crewId, sessionId: localSessionId, captain: true)
        }
        try await start(
            crewId: crewId,
            sessionId: localSessionId,
            config: cfg,
            workingDirectory: workdir,
            taskBrief: initialPrompt,
            developerInstructions: developerInstructions,
            codexMcpServers: codexMcpServers,
            role: .captain
        )
    }
}

/// 单次 session 的 UI 视图模型。
///
/// agent 跑在后端里（claude = 内嵌真终端；codex = app-server），UI 通过
/// `agentTerminalSession` 有条件地嵌入终端视图。这里只追踪后端进程的
/// running/exited 生命周期，并在结束时关掉 server row。
@MainActor
final class CrewSessionRun: ObservableObject, Identifiable {
    enum Status: Equatable {
        case running
        case completed
        case cancelled
        case failed
    }

    /// session 在 crew 里的角色 —— captain（调度者）/ worker（干活的）。
    /// 切换条展示用，captain 置顶。
    enum Role: Equatable {
        case captain
        case worker
    }

    let runID = UUID()
    let crewId: String
    /// 本 session 的合成 id（BYOK = startSession 生成的 localSessionId；logged =
    /// 服务端 session id）。与 MCP `--session` / 世界观 / `LocalApprovalStore` 条目
    /// 的 sessionId 三处一致 —— 右栏内联待办卡片靠它过滤出本 session 的待决策/待审批。
    let sessionId: String
    let kind: LocalCodingAgentKind
    let taskBrief: String
    let workingDirectory: URL
    /// 用户起 session 时选的 model slug。Run-level metadata，UI 展示用。
    let model: String?
    /// Spec v2 §10 — session-level override for permission_mode（informational）。
    let permissionModeOverride: String?
    /// captain / worker 角色（切换条展示 + captain 置顶）。
    let role: Role
    let startedAt = Date()

    /// 切换条上的短名：captain 直接叫 "Captain"，worker 用 agent 名 + session id 前缀。
    var displayName: String {
        role == .captain ? "Captain" : kind.displayName + " · " + String(sessionId.prefix(6))
    }

    /// 后端实现（claude = AgentTerminalSession；codex = app-server，待实现）。
    let backend: any SessionBackend

    /// 类型转换访问：仅当后端是终端（claude）时非 nil，供 `AgentTerminalView` 使用。
    var agentTerminalSession: AgentTerminalSession? { backend as? AgentTerminalSession }

    @Published private(set) var status: Status = .running
    @Published private(set) var exitCode: Int32?

    /// 用户主动停 → 终端退出时落 `.cancelled` 而非 `.failed`。
    private var cancelled = false
    /// Guards double-finalize.
    private var finalized = false
    /// Server row lifecycle close (logged mode only; nil for BYOK/local-only).
    private let serverLink: CrewSessionServerLink?
    private var statusObservation: Task<Void, Never>?

    nonisolated var id: UUID { runID }

    init(
        crewId: String,
        sessionId: String,
        kind: LocalCodingAgentKind,
        taskBrief: String,
        workingDirectory: URL,
        model: String? = nil,
        permissionModeOverride: String? = nil,
        backend: any SessionBackend,
        serverLink: CrewSessionServerLink? = nil,
        role: Role = .worker
    ) {
        self.crewId = crewId
        self.sessionId = sessionId
        self.kind = kind
        self.taskBrief = taskBrief
        self.workingDirectory = workingDirectory
        self.model = model
        self.permissionModeOverride = permissionModeOverride
        self.backend = backend
        self.serverLink = serverLink
        self.role = role
        self.status = Self.map(backend.status, cancelled: false)
        observeBackendStatus()
    }

    /// 跟踪后端的 running/exited，映射到 run 的生命周期 status，并在退出时
    /// finalize（关 server row）。用 `backend.statusPublisher` 的 Combine stream 驱动。
    private func observeBackendStatus() {
        statusObservation = Task { [weak self] in
            guard let self else { return }
            for await backendStatus in self.backend.statusPublisher.values {
                if Task.isCancelled { return }
                switch backendStatus {
                case .running:
                    self.status = .running
                case let .exited(code):
                    self.exitCode = code
                    self.finalize(exitCode: code)
                }
            }
        }
    }

    /// 发文本给 agent（首条指令 / 续聊 / steer）。终端原样接收。
    func send(_ text: String) { backend.send(text) }

    /// 打断进行中的回合（Esc）。
    func interrupt() { backend.interrupt() }

    /// 主动停掉 session（终止子进程）。后端退出后落 `.cancelled`。
    func stop() {
        guard status == .running else { return }
        cancelled = true
        backend.stop()
    }

    deinit {
        statusObservation?.cancel()
    }

    /// 终端进程退出 —— 落 terminal status + 关 server row。Idempotent。
    private func finalize(exitCode: Int32?) {
        guard !finalized else { return }
        finalized = true
        status = Self.map(.exited(exitCode), cancelled: cancelled)
        statusObservation?.cancel()
        if let link = serverLink {
            let finalStatus = status
            Task { await link.finish(localStatus: finalStatus, summary: nil) }
        }
    }

    /// Map the terminal's running/exited state to the run lifecycle.
    private static func map(_ status: SessionStatus, cancelled: Bool) -> Status {
        switch status {
        case .running:
            return .running
        case let .exited(code):
            if cancelled { return .cancelled }
            return (code ?? 0) == 0 ? .completed : .failed
        }
    }
}
#endif
