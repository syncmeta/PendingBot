#if os(macOS)
import Foundation
import SwiftTerm

/// 一个内嵌真终端的 coding-agent 会话：在 PTY 里跑交互式 claude/codex(自动审批)。
/// 读=终端原样显示，控=键盘(SwiftTerm 原生) + 程序化 send()/interrupt() 字节注入。
@MainActor
final class AgentTerminalSession: ObservableObject {
    enum Status: Equatable { case running, exited(Int32?) }

    let kind: LocalCodingAgentKind
    let terminalView: LocalProcessTerminalView
    @Published private(set) var status: Status = .running

    private final class Delegate: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: ((Int32?) -> Void)?
        func processTerminated(source: TerminalView, exitCode: Int32?) { onExit?(exitCode) }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
    private let delegate = Delegate()

    /// `executable` = 已 resolve 的 claude/codex 绝对路径；`workdir` = 工作目录。
    init(kind: LocalCodingAgentKind, executable: String, workdir: String,
         model: String? = nil, resumeSessionId: String? = nil, env: [String: String]) {
        self.kind = kind
        self.terminalView = LocalProcessTerminalView(frame: .zero)
        self.terminalView.processDelegate = delegate
        delegate.onExit = { [weak self] code in
            Task { @MainActor in self?.status = .exited(code) }
        }
        var envArr = env.map { "\($0.key)=\($0.value)" }
        if !envArr.contains(where: { $0.hasPrefix("TERM=") }) { envArr.append("TERM=xterm-256color") }
        terminalView.startProcess(
            executable: executable,
            args: Self.argv(kind: kind, model: model, resumeSessionId: resumeSessionId),
            environment: envArr,
            currentDirectory: workdir
        )
    }

    /// 交互式 + 自动审批 argv（flag 本机实测 2026-06-04：claude 2.1.156 / codex 0.133.0）。
    static func argv(kind: LocalCodingAgentKind, model: String?, resumeSessionId: String?) -> [String] {
        switch kind {
        case .claudeCode:
            var a: [String] = []
            if let id = resumeSessionId { a += ["--resume", id] }
            a += ["--dangerously-skip-permissions"]
            if let m = model { a += ["--model", m] }
            return a
        case .codex:
            if let id = resumeSessionId { return ["resume", id, "-a", "never", "--sandbox", "workspace-write"] }
            var a = ["-a", "never", "--sandbox", "workspace-write"]
            if let m = model { a += ["--model", m] }
            return a
        }
    }

    /// 程序化发文本(prompt / steer)：写文本 + 回车。
    func send(_ text: String) { inject(Array((text + "\r").utf8)) }
    /// 打断进行中的回合(Esc)。
    func interrupt() { inject([0x1b]) }
    /// 终止子进程。
    func stop() { terminalView.terminate() }

    private func inject(_ bytes: [UInt8]) { terminalView.process.send(data: bytes[...]) }
}
#endif
