#if os(macOS)
import Foundation
import AppKit
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
    /// PTY 输出旁路（健康扫描用）——`dataReceived` 在主线程 UI feed 路径上调,
    /// 回调必须够便宜（SessionHealthScanner 是字节循环 + 尾窗子串查,满足）。
    var onData: ((ArraySlice<UInt8>) -> Void)?
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        lastOutputAt = Date()
        onData?(slice)
    }

    // MARK: - 外置 overlay 滚动条支撑

    /// 终端滚动位置变化回调（外置 overlay 条据此刷新 knob）。
    /// `userInitiated` 区分「用户滚轮/拖动」与「输出自动滚屏」——只有前者才淡入显示条，
    /// 后者只静默同步几何，避免 agent 持续输出时条一直闪。
    var onScroll: ((_ userInitiated: Bool) -> Void)?

    /// SwiftTerm 每次 yDisp 变化都会调这里（用户滚 + 输出自动滚都算）。`scrollWheel` 在
    /// SwiftTerm 里非 open、外部模块不可 override，故不能直接标记「用户滚轮」；改用启发式：
    /// 输出驱动的自动滚屏总是紧跟一拍 `dataReceived`（lastOutputAt≈now），而用户滚轮/触控板
    /// 在空闲期滚动时最近没有 PTY 输出。>0.2s 没收到输出 = 判为用户主动 → 点亮条。
    override func scrolled(source terminal: Terminal, yDisp: Int) {
        super.scrolled(source: terminal, yDisp: yDisp)
        let userInitiated = Date().timeIntervalSince(lastOutputAt) > 0.2
        onScroll?(userInitiated)
    }

    /// SwiftTerm 内部那条焊死的 NSScroller —— 外置 overlay 条取代它，这里把它藏了。
    /// 网格宽度已扣掉 scrollerWidth（`getEffectiveWidth`），藏掉后右侧那条 ~15pt 空当
    /// 正好留给 overlay，且不占字。scroller 在 `setupScroller()` 里 addSubview，时机不定，
    /// 故 didAddSubview 抓一次 + 外部可再 sweep 一次兜底。
    private var didHideNativeScroller = false
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview is NSScroller {
            subview.isHidden = true
            didHideNativeScroller = true
        }
    }

    /// 兜底扫一遍 subviews 藏掉 NSScroller；返回是否已确认藏到（供 fail-loud 用）。
    @discardableResult
    func hideNativeScroller() -> Bool {
        if didHideNativeScroller { return true }
        if let native = subviews.compactMap({ $0 as? NSScroller }).first {
            native.isHidden = true
            didHideNativeScroller = true
        }
        return didHideNativeScroller
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
    /// PTY 输出健康扫描（未登录/额度到顶）—— 每 Kind 只翻一次;`health` 保留
    /// 最近一条(auth 优先级高于 quota 的覆盖顺序由到达先后决定,展示层不细分)。
    @Published private(set) var health: CrewSessionHealth?
    var healthPublisher: Published<CrewSessionHealth?>.Publisher { $health }
    private let healthScanner = SessionHealthScanner()
    private var busyTimer: Timer?

    /// 外置 overlay 滚动条的几何 + 用户主动信号（SwiftUI `TerminalScrollbarOverlay` 观察）。
    /// 全部取自 SwiftTerm 公开滚动接口，语义：position/thumbSize 都是 0…1。
    struct ScrollState: Equatable {
        /// 是否可滚（有回滚历史且非 alternate buffer）——决定 overlay 是否挂出。
        var canScroll = false
        /// viewport 相对位置 0(最顶)…1(最底)。
        var position: Double = 0
        /// knob 占轨道的比例 0…1（= SwiftTerm `scrollThumbsize`/knobProportion）。
        var thumbSize: Double = 1
        /// 单调递增计数：每次「用户主动滚动」bump 一次。overlay 据此触发淡入 + 重置
        /// 自动隐藏计时；输出自动滚屏不 bump，条不会因 agent 持续吐字一直闪。
        var userScrollTick: Int = 0
    }
    @Published private(set) var scrollState = ScrollState()

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
        // 健康扫描旁路：PTY 输出喂 SessionHealthScanner,命中(每 Kind 一次)翻 health。
        // dataReceived 在主线程,init 也是 @MainActor —— assumeIsolated 安全。
        self.terminalView.onData = { [weak self] slice in
            guard let self else { return }
            MainActor.assumeIsolated {
                // 逐条赋值(而非只取一条)——同一 chunk 罕见地同时命中 auth+quota 时,
                // 两次 @Published 变更都要发出去,下游(run 的白板 fail-loud)按 kind 去重。
                for hit in self.healthScanner.feed(slice) { self.health = hit }
            }
        }
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
        // 终端滚动（用户滚 + 输出自动滚）→ 刷新外置条几何。userInitiated 决定是否点亮。
        terminalView.onScroll = { [weak self] userInitiated in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshScrollState(userInitiated: userInitiated) }
        }
        // 0.6s 轮询输出活跃度 → 翻 isBusy。定时器在 main runloop 触发(init 是
        // @MainActor)；[weak self] 不成环，exit/stop/deinit 时 invalidate。
        busyTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recomputeWorking()
                // canScroll/thumbSize 会因输出增长而变，但只在 yDisp 变化时才有 scrolled
                // 回调；顶到底持续吐字时 yDisp 每行都动能覆盖，静止但 buffer 变化的边角用
                // 轮询兜一层（非用户主动，只同步几何不点亮）。
                self?.refreshScrollState(userInitiated: false)
            }
        }
        // 内部 scroller 兜底隐藏 + fail-loud：didAddSubview 一般已抓到；若 SwiftTerm 换了
        // 布局（不再用 NSScroller / 私有结构变），这里大声报，别让它静默贴右缘压字。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            if !self.terminalView.hideNativeScroller() {
                assertionFailure("SwiftTerm 内部 NSScroller 未找到——外置滚动条方案需复核 SwiftTerm 布局")
                NSLog("[AgentTerminalSession] 警告：未能隐藏 SwiftTerm 内部滚动条，右缘可能压字")
            }
        }
    }

    /// 从 SwiftTerm 公开接口重算外置条几何；仅在变化时发布，避免输出流时高频 @Published。
    private func refreshScrollState(userInitiated: Bool) {
        let next = ScrollState(
            canScroll: terminalView.canScroll,
            position: terminalView.scrollPosition,
            thumbSize: Double(terminalView.scrollThumbsize),
            userScrollTick: scrollState.userScrollTick + (userInitiated ? 1 : 0)
        )
        if next != scrollState { scrollState = next }
    }

    /// overlay 拖动/点击 → 驱动 SwiftTerm 滚到 0…1 位置，并立即回刷几何（算用户主动）。
    func scrollTerminal(toPosition position: Double) {
        terminalView.scroll(toPosition: max(0, min(1, position)))
        refreshScrollState(userInitiated: true)
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
