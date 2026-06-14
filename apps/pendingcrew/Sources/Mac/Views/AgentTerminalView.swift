#if os(macOS)
import SwiftUI
import SwiftTerm

/// 把 AgentTerminalSession 的 LocalProcessTerminalView 宿主进 SwiftUI。
struct AgentTerminalView: NSViewRepresentable {
    let session: AgentTerminalSession
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = session.terminalView
        // 终端基于网格(默认 ~80 列)有个很宽的 intrinsicContentSize + 默认 750 的
        // 水平抗压缩优先级。宿主进窄的 inspector 栏时,NSSplitView 不肯把它压到
        // intrinsic 宽以下,会把整栏顶宽;栏比它窄就两边溢出被切(必须拖宽才正常)。
        // 调低水平抗压缩/抱紧优先级,让栏能自由把终端压到可用宽度——终端会按实际
        // 宽度重排列数,而不是顶死栏宽。
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
#endif
