#if os(macOS)
import SwiftUI
import SwiftTerm

/// 把 AgentTerminalSession 的 LocalProcessTerminalView 宿主进 SwiftUI。
struct AgentTerminalView: NSViewRepresentable {
    let session: AgentTerminalSession
    func makeNSView(context: Context) -> LocalProcessTerminalView { session.terminalView }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
#endif
