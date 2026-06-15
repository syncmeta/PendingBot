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
    var kind: LocalCodingAgentKind { get }
    func send(_ text: String)
    func interrupt()
    func stop()
}
#endif
