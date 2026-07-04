#if os(macOS)
import Foundation
import SwiftTerm

/// 一个内嵌真终端的 coding-agent 会话：在 PTY 里跑交互式 claude/codex(自动审批)。
/// 读=终端原样显示，控=键盘(SwiftTerm 原生) + 程序化 send()/interrupt() 字节注入。
/// `LocalProcessTerminalView` 子类，记录最近一次收到 PTY 输出的时刻 —— 用来近似
/// 「agent 在干活」：claude TUI 干活时持续重绘(spinner/输出)→ 频繁有数据;空闲等
/// 指令时几乎不吐数据(光标闪烁是 SwiftTerm 本地渲染，不经 PTY)。`dataReceived` 是
/// `open`，覆盖它记时间戳即可(主线程，UI feed 路径)。
final class ActivityTerminalView: LocalProcessTerminalView {
    /// 最近一次收到子进程输出的时刻；busy 判定 = now - lastOutputAt < 阈值。
    var lastOutputAt = Date.distantPast
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        lastOutputAt = Date()
    }
}

@MainActor
final class AgentTerminalSession: ObservableObject, SessionBackend {
    let kind: LocalCodingAgentKind
    let terminalView: ActivityTerminalView
    @Published private(set) var status: SessionStatus = .running
    var statusPublisher: Published<SessionStatus>.Publisher { $status }
    /// 唤醒注入门禁用：PTY 终端无可编程 turn-state，交互式 claude 自带输入排队，
    /// 注入随时安全 → 恒 false（main 语义保留，别让 @我的定向消息因 busy 漏注入）。
    var isBusy: Bool { false }
    /// UI 头像「干活中/空闲」用（与 isBusy 解耦）：最近 ~1s 还在吐 PTY 输出=干活，
    /// 安静=空闲。0.6s 轮询 `terminalView.lastOutputAt` 重算；status 非 running 时恒 false。
    @Published private(set) var isWorking = false
    var isWorkingPublisher: Published<Bool>.Publisher { $isWorking }
    private var busyTimer: Timer?

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
        self.terminalView = ActivityTerminalView(frame: .zero)
        self.terminalView.processDelegate = delegate
        delegate.onExit = { [weak self] code in
            Task { @MainActor in
                self?.status = .exited(code)
                self?.isWorking = false
                self?.busyTimer?.invalidate()
            }
        }
        var envArr = env.map { "\($0.key)=\($0.value)" }
        if !envArr.contains(where: { $0.hasPrefix("TERM=") }) { envArr.append("TERM=xterm-256color") }
        terminalView.startProcess(
            executable: executable,
            args: config.argv(),
            environment: envArr,
            currentDirectory: workdir
        )
        // 0.6s 轮询输出活跃度 → 翻 isBusy。定时器在 main runloop 触发(init 是
        // @MainActor)；[weak self] 不成环，exit/stop/deinit 时 invalidate。
        busyTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recomputeWorking() }
        }
    }

    /// 干活中 = 仍 running 且最近 1s 内还有 PTY 输出。
    private func recomputeWorking() {
        let working = status == .running && Date().timeIntervalSince(terminalView.lastOutputAt) < 1.0
        if working != isWorking { isWorking = working }
    }

    deinit { busyTimer?.invalidate() }

    /// 程序化发文本(prompt / steer)：先写正文，隔一拍再单发回车。
    /// claude TUI 按字节到达时序区分「粘贴 vs 敲键」——正文+回车一笔写入会被
    /// 整段判成粘贴，回车被吞进输入框文本 → 不提交（用户得手动按 Enter）。
    /// 回车必须作为独立的一次按键、在粘贴判定窗口之外到达才触发提交。
    func send(_ text: String) {
        inject(Array(text.utf8))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, self.status == .running else { return }
            self.inject([0x0d])
        }
    }
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
