#if os(macOS)
import Foundation
import SwiftTerm

/// 一个内嵌真终端的 coding-agent 会话：在 PTY 里跑交互式 claude/codex(自动审批)。
/// 读=终端原样显示，控=键盘(SwiftTerm 原生) + 程序化 send()/interrupt() 字节注入。
@MainActor
final class AgentTerminalSession: ObservableObject, SessionBackend {
    let kind: LocalCodingAgentKind
    let terminalView: LocalProcessTerminalView
    @Published private(set) var status: SessionStatus = .running
    var statusPublisher: Published<SessionStatus>.Publisher { $status }

    private final class Delegate: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: ((Int32?) -> Void)?
        func processTerminated(source: TerminalView, exitCode: Int32?) { onExit?(exitCode) }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
    private let delegate = Delegate()

    /// `executable` = 已 resolve 的 claude/codex 绝对路径；`workdir` = 工作目录。
    /// argv（含首条指令的 positional prompt、auto mode、effort）由 `config.argv()` 构建。
    init(config: SessionConfig, executable: String, workdir: String, env: [String: String]) {
        self.kind = config.kind
        self.terminalView = LocalProcessTerminalView(frame: .zero)
        self.terminalView.processDelegate = delegate
        delegate.onExit = { [weak self] code in
            Task { @MainActor in self?.status = .exited(code) }
        }
        var envArr = env.map { "\($0.key)=\($0.value)" }
        if !envArr.contains(where: { $0.hasPrefix("TERM=") }) { envArr.append("TERM=xterm-256color") }
        terminalView.startProcess(
            executable: executable,
            args: config.argv(),
            environment: envArr,
            currentDirectory: workdir
        )
    }

    /// 程序化发文本(prompt / steer)：写文本 + 回车。
    func send(_ text: String) { inject(Array((text + "\r").utf8)) }
    /// 打断进行中的回合(Esc)。
    func interrupt() { inject([0x1b]) }

    /// 终止子进程。"停不掉"的真因：SwiftTerm `terminate()` 调 `childStopped()`，
    /// 后者 **cancel 掉退出监听 childMonitor 且 close io**，于是进程真退出后
    /// `processTerminated` 回调**永不触发** → `status` 永远停在 `.running` →
    /// UI 停止键/badge/终端留屏不变 = 看着"停不掉"。所以这里**自己翻 `status`**，
    /// 不依赖被吞掉的回调。另外 `terminate()` 只发 SIGTERM；万一交互式 agent 截获
    /// 它，宽限后 `terminateTree` 升级 SIGKILL（不可捕获）兜底，连带杀子进程。
    func stop() {
        guard status == .running else { return }
        let pid = terminalView.process?.shellPid ?? 0
        terminalView.terminate()            // SIGTERM + close PTY（但不回调 processTerminated）
        status = .exited(nil)               // ← 自己翻状态，否则 UI 永远 running
        Task { await terminateTree(pid: pid, graceSeconds: 2.0) }
    }

    private func inject(_ bytes: [UInt8]) { terminalView.process?.send(data: bytes[...]) }
}

/// SIGTERM 已由调用方（SwiftTerm `terminate()`）发出；本函数等一个宽限期，
/// 若进程仍在就升级到 **SIGKILL**。`killpg` 杀整个进程组——pty 子进程是 setsid
/// 的会话首（组 id == pid），能连带杀掉它拉起的 bash/MCP 子进程；非组首则
/// fallback 单杀。SIGKILL 不可捕获，保证停得掉。
func terminateTree(pid: pid_t, graceSeconds: Double) async {
    guard pid > 0 else { return }
    try? await Task.sleep(nanoseconds: UInt64(max(0, graceSeconds) * 1_000_000_000))
    guard kill(pid, 0) == 0 else { return }     // 已退出，无需升级
    if killpg(pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
}
#endif
