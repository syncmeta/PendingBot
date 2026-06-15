#if os(macOS)
import Foundation
import Combine

/// Coding-agent session 的生命周期状态，与后端实现无关。
/// `.running` = agent 进程存活；`.exited(code)` = 已结束。
/// （codex app-server 跨多轮保持 `.running`，只有进程终止才变 `.exited`。）
public enum SessionStatus: Equatable {
    case running
    case exited(Int32?)
}

/// `CrewSessionRun` 所需的控制 + 生命周期接口，由终端后端（claude）
/// 与未来的 app-server 后端（codex）共同实现。
/// 视图层（`AgentTerminalView` 等）由具体类型/kind 决定；
/// 本协议只覆盖控制 + 状态两面。
@MainActor
protocol SessionBackend: AnyObject {
    var status: SessionStatus { get }
    var statusPublisher: Published<SessionStatus>.Publisher { get }
    /// 是否正在跑一轮 turn（busy）。事件驱动唤醒（Phase 4b）据此判断：busy 时
    /// 不打断、把@我的定向消息留给下一轮；空闲时立刻注入唤醒。
    ///
    /// - codex（app-server）：有真 turn 生命周期 → `activeTurnId != nil`。
    /// - claude（PTY 终端）：交互式 claude 没有可编程的 turn-state，且 `send()`
    ///   写进的文本由 claude 自己的输入缓冲排队（当前轮跑完后作为下一条 prompt
    ///   执行，不污染进行中的 turn）—— 所以恒返回 `false`（注入随时安全）。
    var isBusy: Bool { get }
    /// 头像/切换条「干活中 vs 空闲」状态点用的活跃信号 —— **与 `isBusy` 解耦**：
    /// `isBusy` 服务唤醒注入门禁（claude 恒 false 以保证不漏注入），这个只驱动 UI 且
    /// 可观察。codex=turn 进行中；claude=最近 ~1s 还在吐 PTY 输出的近似（干活时
    /// spinner/输出不断 → true，空闲等指令时安静 → false）。`status==.exited` 时恒 false。
    var isWorking: Bool { get }
    var isWorkingPublisher: Published<Bool>.Publisher { get }
    var kind: LocalCodingAgentKind { get }
    func send(_ text: String)
    func interrupt()
    func stop()
}
#endif
