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
        let env = LocalCodingAgentEnv.build(additionalEnv: additionalEnv)
        // 3. 起内嵌终端 session
        let terminalSession = AgentTerminalSession(
            config: config,
            executable: executable.path,
            workdir: workingDirectory.path,
            env: env
        )
        // 4. 包成 view model
        let run = CrewSessionRun(
            crewId: crewId,
            sessionId: sessionId,
            kind: config.kind,
            taskBrief: taskBrief,
            workingDirectory: workingDirectory,
            model: config.model,
            permissionModeOverride: config.permissionMode,
            terminalSession: terminalSession,
            serverLink: serverLink,
            role: role
        )
        // 多 run 并存：追加 + 选中，不动旧 run（每个 run 在切换条上都有自己的
        // 停止/移除入口，不会变 orphan）。
        runs.append(run)
        selectedRunId = run.runID
        isComposingNew = false
    }

    enum RunnerError: LocalizedError {
        case toolNotInstalled(kind: LocalCodingAgentKind)
        case tooManySessions

        var errorDescription: String? {
            switch self {
            case .toolNotInstalled(let kind):
                return "未在 PATH 中找到 \(kind.binaryName)，请先安装 \(kind.displayName) CLI。"
            case .tooManySessions:
                return "同时运行的 session 已达上限（6），先停掉一些再开。"
            }
        }
    }
}

/// 单次 session 的 UI 视图模型。
///
/// agent 跑在内嵌真终端里（`terminalSession.terminalView`），UI 直接把那个
/// `LocalProcessTerminalView` 嵌进来（见 `AgentTerminalView`）。这里只追踪
/// 终端进程的 running/exited 生命周期，并在结束时关掉 server row。
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

    /// 内嵌真终端 session —— UI 把它的 `terminalView` 嵌进来，agent 在里面跑。
    let terminalSession: AgentTerminalSession

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
        terminalSession: AgentTerminalSession,
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
        self.terminalSession = terminalSession
        self.serverLink = serverLink
        self.role = role
        self.status = Self.map(terminalSession.status, cancelled: false)
        observeTerminalStatus()
    }

    /// 跟踪内嵌终端的 running/exited，映射到 run 的生命周期 status，并在退出时
    /// finalize（关 server row）。用 `@Published status` 的 Combine stream 驱动。
    private func observeTerminalStatus() {
        statusObservation = Task { [weak self] in
            guard let self else { return }
            for await terminalStatus in self.terminalSession.$status.values {
                if Task.isCancelled { return }
                switch terminalStatus {
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
    func send(_ text: String) { terminalSession.send(text) }

    /// 打断进行中的回合（Esc）。
    func interrupt() { terminalSession.interrupt() }

    /// 主动停掉 session（终止子进程）。终端退出后落 `.cancelled`。
    func stop() {
        guard status == .running else { return }
        cancelled = true
        terminalSession.stop()
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
    private static func map(_ status: AgentTerminalSession.Status, cancelled: Bool) -> Status {
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
