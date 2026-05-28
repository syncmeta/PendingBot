#if os(macOS)
import Foundation

/// 运行 + cancel 一个本机 coding agent 子进程。
///
/// **设计要点（spec v2 §8.4）**：
/// - `process.environment` 显式 set 白名单（见 `LocalCodingAgentLaunchSpec.env()`）
/// - stdout / stderr 行流式回调（不缓存全文 —— 长任务会撑爆 RAM）
/// - 不设 timeout
/// - Cancel：SIGTERM → `gracePeriod` 秒等待 → SIGKILL 兜底
/// - actor 隔离：cancel 可能从任意 Task 来；start / waitUntilExit / cancel 互斥
public actor LocalCodingAgentProcess {

    /// SIGTERM 到 SIGKILL 之间的 grace。spec v2 §8.4.3 写"几秒"，落地 5s。
    public static let defaultGracePeriod: Duration = .seconds(5)

    public enum LaunchError: Error, CustomStringConvertible {
        case workingDirectoryMissing(URL)
        case executableNotExecutable(URL)
        case alreadyStarted
        case spawnFailed(underlying: Error)

        public var description: String {
            switch self {
            case .workingDirectoryMissing(let url):
                return "working directory does not exist or is not a directory: \(url.path)"
            case .executableNotExecutable(let url):
                return "not an executable file: \(url.path)"
            case .alreadyStarted:
                return "LocalCodingAgentProcess.start() already called on this instance"
            case .spawnFailed(let err):
                return "Process.run() threw: \(err)"
            }
        }
    }

    public typealias LineHandler = @Sendable (String) -> Void

    // MARK: - state

    private let spec: LocalCodingAgentLaunchSpec
    private let stdoutHandler: LineHandler
    private let stderrHandler: LineHandler
    private let gracePeriod: Duration

    /// 一旦 start() 成功，赋值后不再改 —— actor 保证 access 串行。
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinPipe: Pipe?
    /// `waitUntilExit()` 的 awaiters 阻塞在这。Process.terminationHandler 触发后 resume。
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var didFinish: Bool = false
    private var finalExitCode: Int32?
    private var didStart: Bool = false
    private var cancelInFlight: Bool = false

    /// stdout / stderr 行缓冲。`readabilityHandler` 给的是 chunk，可能切到一行中间，
    /// 需要在 actor 内拼回完整行再交给 handler。
    private var stdoutLineBuffer: String = ""
    private var stderrLineBuffer: String = ""

    public init(
        spec: LocalCodingAgentLaunchSpec,
        stdoutHandler: @escaping LineHandler,
        stderrHandler: @escaping LineHandler,
        gracePeriod: Duration = LocalCodingAgentProcess.defaultGracePeriod
    ) {
        self.spec = spec
        self.stdoutHandler = stdoutHandler
        self.stderrHandler = stderrHandler
        self.gracePeriod = gracePeriod
    }

    // MARK: - start

    /// 起子进程。Pre-checks（cwd / executable）失败时直接抛，**不**走 Process.run。
    public func start() async throws {
        guard !didStart else { throw LaunchError.alreadyStarted }
        didStart = true

        // 校验 cwd：spec v2 §8.4 + 任务里明确要求"workingDirectory 在 init 时校验"。
        // 这里在 start 而不是 spec init 校验，因为 spec init 是 sync value-type 构造，
        // 不该有 IO。actor.start 是 IO 边界，校验放这。
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: spec.workingDirectory.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw LaunchError.workingDirectoryMissing(spec.workingDirectory)
        }
        guard FileManager.default.isExecutableFile(atPath: spec.executableURL.path) else {
            throw LaunchError.executableNotExecutable(spec.executableURL)
        }

        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.argv()
        process.currentDirectoryURL = spec.workingDirectory
        // **显式 set**：不传 nil（=继承父进程 env，恰恰是 spec v2 §8.4 禁止的）。
        process.environment = spec.env()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        // stdout/stderr readabilityHandler：在 Pipe 的 IO queue 上回调，
        // 我们 hop 回 actor 处理 line splitting + 调用 user handler。
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            // availableData 返回空 = EOF；nil 化 handler 让 fd 关闭，free 资源。
            Task { [weak self] in
                await self?.ingestStdout(chunk)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { [weak self] in
                await self?.ingestStderr(chunk)
            }
        }

        // terminationHandler 在 Process 的私有 queue 上回调。hop 回 actor 收尾。
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { [weak self] in
                await self?.handleTermination(exitCode: code)
            }
        }

        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.stdinPipe = stdinPipe

        do {
            try process.run()
        } catch {
            // 起不来：清掉 handler 避免泄漏，rethrow。
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            self.stdinPipe = nil
            didFinish = true
            throw LaunchError.spawnFailed(underlying: error)
        }

        // 把 initialPrompt 喂进 stdin，然后关闭 —— Claude Code / Codex 都在
        // stdin EOF 后开始处理。
        if !spec.initialPrompt.isEmpty {
            let data = Data(spec.initialPrompt.utf8)
            // `write(contentsOf:)` 在 macOS 11+ 才有；fall back 用 legacy write。
            // 这里直接用 `write(_:)` —— 同步、SIGPIPE 风险存在但 Process 子进程
            // 在 stdin pipe close 前不会自己关 stdin 端。
            stdinPipe.fileHandleForWriting.write(data)
        }
        try? stdinPipe.fileHandleForWriting.close()
    }

    // MARK: - wait

    /// 等到子进程退出，返回 exit code。若已经退出，立即返回。
    public func waitUntilExit() async -> Int32 {
        if didFinish, let code = finalExitCode {
            return code
        }
        return await withCheckedContinuation { cont in
            exitWaiters.append(cont)
        }
    }

    // MARK: - cancel

    /// SIGTERM → grace → SIGKILL。可重复调用（idempotent —— 第二次是 no-op）。
    ///
    /// 不抛错：cancel 必须尽力跑完；目标是"子进程一定死"。
    public func cancel() async {
        guard let process = process, process.isRunning, !cancelInFlight else { return }
        cancelInFlight = true

        // SIGTERM。Process.terminate() 在 Darwin 上发的是 SIGTERM。
        process.terminate()

        // 起一个 grace 计时；若到点还在跑，发 SIGKILL（Process 没暴露 SIGKILL API，
        // 用 kill(2)）。
        try? await Task.sleep(for: gracePeriod)
        if process.isRunning {
            // SIGKILL = 9。直接用 Darwin.kill，pid 来自 Process。
            kill(process.processIdentifier, SIGKILL)
        }
        // 不在这里 wait —— terminationHandler 会 resume waiters。
    }

    // MARK: - private: streaming

    private func ingestStdout(_ chunk: Data) {
        Self.splitLines(buffer: &stdoutLineBuffer, chunk: chunk, emit: stdoutHandler)
    }

    private func ingestStderr(_ chunk: Data) {
        Self.splitLines(buffer: &stderrLineBuffer, chunk: chunk, emit: stderrHandler)
    }

    /// 把 chunk 追加到 buffer，按 `\n` 切，整行交给 emit。
    /// 不完整的 trailing 留在 buffer 里等下一个 chunk。
    private static func splitLines(buffer: inout String, chunk: Data, emit: LineHandler) {
        guard let text = String(data: chunk, encoding: .utf8) else {
            // 二进制/无效 UTF-8：lossy 转回，避免吞数据。
            let lossy = String(decoding: chunk, as: UTF8.self)
            buffer += lossy
            return
        }
        buffer += text
        while let newlineIdx = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIdx])
            buffer.removeSubrange(buffer.startIndex...newlineIdx)
            emit(line)
        }
    }

    /// terminationHandler 触发后清场 + resume 所有 waiter。
    private func handleTermination(exitCode: Int32) {
        guard !didFinish else { return }
        didFinish = true
        finalExitCode = exitCode

        // flush 残留的、没换行结尾的 buffer。
        if !stdoutLineBuffer.isEmpty {
            stdoutHandler(stdoutLineBuffer)
            stdoutLineBuffer = ""
        }
        if !stderrLineBuffer.isEmpty {
            stderrHandler(stderrLineBuffer)
            stderrLineBuffer = ""
        }

        // 关掉 readabilityHandler 释放 fd。
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        let waiters = exitWaiters
        exitWaiters.removeAll()
        for cont in waiters {
            cont.resume(returning: exitCode)
        }
    }
}
#endif
