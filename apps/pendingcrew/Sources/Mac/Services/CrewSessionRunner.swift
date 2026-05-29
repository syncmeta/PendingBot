#if os(macOS)
import Foundation
import SwiftUI

/// 一次 local coding agent 跑动的 view-side 视图模型。
///
/// 每次 `start(...)` 起一个新 `CrewSessionRun` 并赋给 `current`。
/// 旧的 run 不会自动取消 —— caller 需要先 `current?.cancel()`。MVP
/// 一个窗口只跑一个 run（CreateSessionSheet 起 sheet 前 view 会
/// 给 disabled 提示），多 session tab 留下次。
///
/// P3 stub：会在 P4 接入真实 `MacLocalCodingAgentService`。
@MainActor
final class CrewSessionRunner: ObservableObject {
    @Published private(set) var current: CrewSessionRun?

    /// 注入点 —— 测试时换成 mock impl。默认就是真实现。
    private let service: LocalCodingAgentService

    init(service: LocalCodingAgentService = MacLocalCodingAgentService()) {
        self.service = service
    }

    /// 起一个新 session。pre-flight 失败抛错（工具未装 / cwd 不存在 /
    /// spawn 失败）。成功后立刻把 `current` 切到新 run，return；进程在
    /// 背景跑，stdout/stderr 流式累积到 run 的 @Published 字段。
    func start(
        crewId: String,
        kind: LocalCodingAgentKind,
        workingDirectory: URL,
        taskBrief: String,
        initialPrompt: String,
        additionalEnv: [String: String] = [:],
        /// Spec v2 §10 — per-session override of the crew's permission
        /// mode. `nil` = inherit crew default (server-side null).
        /// `"auto"` / `"manual"` override just this session. The runner
        /// itself doesn't enforce the mode yet (T4.5 peer_device round-
        /// trip lands the real pause-on-manual behaviour); for now the
        /// value just gets recorded server-side so the crew chat card
        /// + the agent's system prompt see it.
        permissionModeOverride: String? = nil
    ) async throws {
        // 1. 校验工具可用
        guard let executable = await service.resolveExecutable(kind) else {
            throw RunnerError.toolNotInstalled(kind: kind)
        }
        // 2. 构造 spec
        let spec = LocalCodingAgentLaunchSpec(
            kind: kind,
            executableURL: executable,
            workingDirectory: workingDirectory,
            taskBrief: taskBrief,
            initialPrompt: initialPrompt,
            additionalEnv: additionalEnv
        )
        // 3. 起进程
        let runID = UUID()
        let handle = try await service.runSession(runID: runID, spec: spec)
        // 4. 包成 view model + 接 streams
        let run = CrewSessionRun(
            runID: runID,
            crewId: crewId,
            kind: kind,
            taskBrief: taskBrief,
            workingDirectory: workingDirectory,
            permissionModeOverride: permissionModeOverride,
            handle: handle
        )
        current = run
        run.observeStreams()
        // 5. v1 stub: 持有 override 在 run 上,等 T4.5 接入 session 创建
        //    HTTP endpoint 时把这个值 PATCH 到 /v1/sessions/:id/permission-mode。
        //    现在还没有 server-side session 行(本机 stub run),所以纯
        //    本地 metadata。
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
/// stdout/stderr 缓冲为简单的 `String` 累积 —— spec v2 §8.4 说不缓存
/// 全文，但 UI 必须能滚回去看历史，所以 view 这层还是把行流拼成
/// String。**长任务的内存上限留下次**（环形 buffer / 截断头部）。
@MainActor
final class CrewSessionRun: ObservableObject, Identifiable {
    enum Status: Equatable {
        case running
        case completed
        case cancelled
        case failed
    }

    let runID: UUID
    let crewId: String
    let kind: LocalCodingAgentKind
    let taskBrief: String
    let workingDirectory: URL
    /// Spec v2 §10 — session-level override for permission_mode.
    /// `nil` = inherit crew default (server-side null). The runner
    /// doesn't enforce the mode locally yet; this field is kept so
    /// the UI can show it and T4.5 has a place to read from when it
    /// wires the runner-side pause-on-manual behaviour.
    let permissionModeOverride: String?
    let startedAt: Date

    @Published private(set) var status: Status = .running
    @Published private(set) var stdoutText: String = ""
    @Published private(set) var stderrText: String = ""
    @Published private(set) var exitCode: Int32?

    private let handle: LocalCodingAgentRunHandle
    private var observeStdoutTask: Task<Void, Never>?
    private var observeStderrTask: Task<Void, Never>?
    private var observeExitTask: Task<Void, Never>?
    private var cancelled = false

    nonisolated var id: UUID { runID }

    init(
        runID: UUID,
        crewId: String,
        kind: LocalCodingAgentKind,
        taskBrief: String,
        workingDirectory: URL,
        permissionModeOverride: String? = nil,
        handle: LocalCodingAgentRunHandle
    ) {
        self.runID = runID
        self.crewId = crewId
        self.kind = kind
        self.taskBrief = taskBrief
        self.workingDirectory = workingDirectory
        self.permissionModeOverride = permissionModeOverride
        self.startedAt = Date()
        self.handle = handle
    }

    /// 起后台 task 把 handle 的 stream / exit code 同步进 @Published。
    /// 由 `CrewSessionRunner.start` 在赋给 `current` 后立刻调。
    ///
    /// Task 继承 enclosing MainActor 上下文（CrewSessionRun 是 @MainActor），
    /// 所以 `self.appendStdout` / `self.finish` 是同步调用 —— Swift 编译器会
    /// 警告多余的 await。
    func observeStreams() {
        let stdoutStream = handle.stdout
        let stderrStream = handle.stderr
        let exitTask = handle.exitCode
        observeStdoutTask = Task { [weak self] in
            for await line in stdoutStream {
                self?.appendStdout(line)
            }
        }
        observeStderrTask = Task { [weak self] in
            for await line in stderrStream {
                self?.appendStderr(line)
            }
        }
        observeExitTask = Task { [weak self] in
            let code = await exitTask.value
            self?.finish(exitCode: code)
        }
    }

    func cancel() async {
        guard status == .running else { return }
        cancelled = true
        await handle.cancel()
        // 不在这里把 status 直接改 cancelled —— 等 exitCode 收到，
        // finish() 会按 cancelled 标志判断是 cancelled 还是 failed。
    }

    deinit {
        observeStdoutTask?.cancel()
        observeStderrTask?.cancel()
        observeExitTask?.cancel()
    }

    // MARK: - private mutators

    private func appendStdout(_ line: String) {
        if !stdoutText.isEmpty { stdoutText.append("\n") }
        stdoutText.append(line)
    }

    private func appendStderr(_ line: String) {
        if !stderrText.isEmpty { stderrText.append("\n") }
        stderrText.append(line)
    }

    private func finish(exitCode: Int32) {
        self.exitCode = exitCode
        if cancelled {
            status = .cancelled
        } else if exitCode == 0 {
            status = .completed
        } else {
            // 退出码非 0 视为 failed —— UI 上仍把 exitCode 数字展示出来。
            // 后续如果 CLI 对 SIGTERM 也 exit 130/143，cancel + 非零退出码
            // 都会落到 cancelled 分支，因为 cancelled 标志已置。
            status = .failed
        }
    }
}
#endif
