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

/// 一次 local coding agent 跑动的 view-side 视图模型。
///
/// 每次 `start(...)` 起一个新 `CrewSessionRun` 并赋给 `current`。
/// 旧的 run 不会自动停止 —— caller 需要先 `current?.stop()`。MVP
/// 一个窗口只跑一个 run（composer 起 session 前 view 会给提示），
/// 多 session tab 留下次。
///
/// 每个 run 内嵌一个真 PTY 终端（`AgentTerminalSession`），跑交互式
/// claude/codex（自动审批）。读=终端原样渲染；控=键盘 + 程序化 send/stop。
@MainActor
final class CrewSessionRunner: ObservableObject {
    @Published private(set) var current: CrewSessionRun?

    init() {}

    /// 起一个新 session。pre-flight 失败抛错（工具未装）。成功后立刻把
    /// `current` 切到新 run 并 return；agent 在内嵌终端里交互式跑。
    func start(
        crewId: String,
        kind: LocalCodingAgentKind,
        workingDirectory: URL,
        taskBrief: String,
        /// 用户在 composer 选的 model slug。Claude Code / Codex 都会拼成
        /// `--model <slug>`；nil = 让 CLI 用自己的默认。
        model: String? = nil,
        additionalEnv: [String: String] = [:],
        /// Spec v2 §10 — per-session override of the crew's permission mode.
        /// `nil` = inherit crew default. Run-level metadata only; the embedded
        /// terminal runs in auto-approve so this is currently informational.
        permissionModeOverride: String? = nil,
        /// 当登录时，caller 备好 server-side session（register host → create →
        /// claim）并把 link 传进来，run 在结束时关掉 server row（让跨端列表能看到
        /// session 已结束）。`nil` = BYOK / local-only。
        serverLink: CrewSessionServerLink? = nil
    ) async throws {
        // 1. 校验工具可用 + resolve 可执行路径
        guard let executable = LocalCodingAgentExecutable.resolve(kind) else {
            throw RunnerError.toolNotInstalled(kind: kind)
        }
        // 2. env 白名单（spec v2 §8.4.2）—— 复用 spec 的纯函数构造。
        let env = LocalCodingAgentEnv.build(additionalEnv: additionalEnv)
        // 3. 起内嵌终端 session
        let terminalSession = AgentTerminalSession(
            kind: kind,
            executable: executable.path,
            workdir: workingDirectory.path,
            model: model,
            env: env
        )
        // 4. 包成 view model
        let run = CrewSessionRun(
            crewId: crewId,
            kind: kind,
            taskBrief: taskBrief,
            workingDirectory: workingDirectory,
            model: model,
            permissionModeOverride: permissionModeOverride,
            terminalSession: terminalSession,
            serverLink: serverLink
        )
        // 切到新 run 前先停掉上一个 —— 否则旧 agent 进程没有任何 UI 能停，变成
        // orphan 一直跑（"停不掉"的一半）。MVP 一个窗口只跑一个 run。
        current?.stop()
        current = run
    }

    enum RunnerError: LocalizedError {
        case toolNotInstalled(kind: LocalCodingAgentKind)

        var errorDescription: String? {
            switch self {
            case .toolNotInstalled(let kind):
                return "未在 PATH 中找到 \(kind.binaryName)，请先安装 \(kind.displayName) CLI。"
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

    let runID = UUID()
    let crewId: String
    let kind: LocalCodingAgentKind
    let taskBrief: String
    let workingDirectory: URL
    /// 用户起 session 时选的 model slug。Run-level metadata，UI 展示用。
    let model: String?
    /// Spec v2 §10 — session-level override for permission_mode（informational）。
    let permissionModeOverride: String?
    let startedAt = Date()

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
        kind: LocalCodingAgentKind,
        taskBrief: String,
        workingDirectory: URL,
        model: String? = nil,
        permissionModeOverride: String? = nil,
        terminalSession: AgentTerminalSession,
        serverLink: CrewSessionServerLink? = nil
    ) {
        self.crewId = crewId
        self.kind = kind
        self.taskBrief = taskBrief
        self.workingDirectory = workingDirectory
        self.model = model
        self.permissionModeOverride = permissionModeOverride
        self.terminalSession = terminalSession
        self.serverLink = serverLink
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
