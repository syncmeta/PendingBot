#if os(macOS)
import Foundation

// MARK: - Run handle

/// 单次 session 的运行句柄。生命周期 = 一次 `Process` 起到死。
///
/// Phase 2 的 UI agent 拿到这个 handle 后：
/// - 把 `stdout` / `stderr` 接到 session 窗口右栏
/// - 在用户按"停止"时调 `cancel()`
/// - 在 `exitCode` 完成时把 final state 写回 crew 群聊
public struct LocalCodingAgentRunHandle: Sendable {
    /// session id —— 由 caller 提供（PendingCrew 自己的 session uuid），
    /// 这里只是带回去方便 UI binding。
    public let runID: UUID

    /// 触发用的 spec（kind / cwd / brief / prompt），方便 UI 显示元信息。
    public let spec: LocalCodingAgentLaunchSpec

    /// stdout 逐行流。子进程 close stdout 时 stream finish。
    public let stdout: AsyncStream<String>

    /// stderr 逐行流。
    public let stderr: AsyncStream<String>

    /// 主动取消：SIGTERM + 5s grace + SIGKILL。
    public let cancel: @Sendable () async -> Void

    /// 子进程退出后 resolve 出 exit code。多次 await 同一个 task 返回同一个值。
    public let exitCode: Task<Int32, Never>
}

// MARK: - Service protocol

/// 顶层 Service —— 注入到 ViewModel 用。
///
/// 当前 `MacLocalCodingAgentService` 是唯一实现；测试用 mock 应实现这个 protocol。
public protocol LocalCodingAgentService: Sendable {
    /// 扫一遍本机能找到的 runner kind。
    func discoverAvailable() async -> [LocalCodingAgentKind]

    /// 解析某个 kind 的可执行路径。`nil` = 未安装。
    func resolveExecutable(_ kind: LocalCodingAgentKind) async -> URL?

    /// 起一个 session。返回 handle 后立刻 return —— Process 在背后跑。
    ///
    /// 抛错 = pre-flight 失败（cwd 不存在 / 工具未找到 / spawn 失败）。
    /// 抛错后**不**留资源 —— spawn 失败时内部 pipe 已经回收。
    func runSession(
        runID: UUID,
        spec: LocalCodingAgentLaunchSpec
    ) async throws -> LocalCodingAgentRunHandle
}

// MARK: - Default impl

public struct MacLocalCodingAgentService: LocalCodingAgentService {
    public init() {}

    public func discoverAvailable() async -> [LocalCodingAgentKind] {
        LocalCodingAgentExecutable.discoverAvailable()
    }

    public func resolveExecutable(_ kind: LocalCodingAgentKind) async -> URL? {
        LocalCodingAgentExecutable.resolve(kind)
    }

    public func runSession(
        runID: UUID,
        spec: LocalCodingAgentLaunchSpec
    ) async throws -> LocalCodingAgentRunHandle {
        // 用 AsyncStream 把 LocalCodingAgentProcess 的 line handler 转成 stream。
        // continuation 在 process 终止后 finish。
        var stdoutCont: AsyncStream<String>.Continuation!
        let stdoutStream = AsyncStream<String> { cont in
            stdoutCont = cont
        }
        var stderrCont: AsyncStream<String>.Continuation!
        let stderrStream = AsyncStream<String> { cont in
            stderrCont = cont
        }

        let process = LocalCodingAgentProcess(
            spec: spec,
            stdoutHandler: { line in
                stdoutCont.yield(line)
            },
            stderrHandler: { line in
                stderrCont.yield(line)
            }
        )

        // start 失败要直接抛 —— 别留半起来的 handle 给 caller。
        do {
            try await process.start()
        } catch {
            stdoutCont.finish()
            stderrCont.finish()
            throw error
        }

        // 后台任务等子进程退出 + finish streams。返回的 Task 给 caller await exitCode。
        let exitTask = Task<Int32, Never> {
            let code = await process.waitUntilExit()
            // 子进程退出后 stream 也该 finish —— Pipe 的 readabilityHandler
            // 已经在 handleTermination 里被 nil 化，不会再有新数据。
            stdoutCont.finish()
            stderrCont.finish()
            return code
        }

        return LocalCodingAgentRunHandle(
            runID: runID,
            spec: spec,
            stdout: stdoutStream,
            stderr: stderrStream,
            cancel: { await process.cancel() },
            exitCode: exitTask
        )
    }
}
#endif
