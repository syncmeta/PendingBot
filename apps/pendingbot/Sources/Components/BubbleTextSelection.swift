import Combine
import SwiftUI

/// 「同一时刻只有一条气泡挂文本选中」的归属登记。
///
/// ## 为什么不能所有气泡都常开 `.textSelection(.enabled)`
///
/// SwiftUI 在 macOS 上实现 `.textSelection(.enabled)` 的方式是给**每一段可选中
/// 文字**背后挂一个真的 `NSTextField`(内部的 `SelectionOverlay`),而且每次视图图
/// 更新都要把全部 overlay 的 `updateNSView` 跑一遍 —— 列表里有多少段文字,这一下
/// 就付多少个 NSTextField 的钱(`setAttributedStringValue:` → `setFont:` →
/// `_invalidateEffectiveFont`)。流式回复期间视图图每帧都在更新,成本按行数线性放大。
///
/// ## 修法:不减功能,只把「常开」改成「谁在指针底下谁开」
///
/// 鼠标悬停到哪条气泡,就把选中能力**只**给那条。照样能划选、能部分复制,成本从
/// 「窗口内每一条」降到「一条」。
///
/// ## 为什么用 subject 而不是 `@Published` / 宿主 `@State`
///
/// 归属若存在宿主视图的 `@State` 里,鼠标每划过一条气泡就写一次宿主 state ——
/// 整个 ConversationView 的 body 失效、整条消息列表重新测量。那是拿一个卡换另一个卡。
/// 所以归属走一个**不参与 SwiftUI 依赖追踪**的 subject:发一次,只有「刚交出」和
/// 「刚拿到」那两行的局部 `@State` 真的变,其余行原值不变、不重绘。
///
/// ## 划选起点 / 拖出气泡外
///
/// 归属是**接力式**的:悬停进入某条 → 它拿走;离开时**不主动交还**,要等下一条来拿。
/// 所以「按下鼠标、拖到气泡外面继续划」这个动作里 overlay 一直在,选中不会中途被拆。
/// (AppKit 在按住拖动时是否仍派发 hover-exit 属未定义行为,这里不依赖它。)
///
/// 移植自 PendingCrew(它从真实 hang 报告里定位到这条热点)。**PendingBot 侧没有
/// 对应的性能采样**,采纳的理由是「全列表常开原生控件」这个机制本身,不是 crew 的
/// 那个秒数 —— 见 docs/tech-debt.md。
final class BubbleSelectionOwner {
    /// 进程内共享一个 —— 同一时刻只有一个会话列表在屏幕上。
    static let shared = BubbleSelectionOwner()

    /// 当前持有选中能力的气泡 id。nil = 谁都没碰过,全列表都不挂 overlay。
    private let subject = CurrentValueSubject<String?, Never>(nil)

    var publisher: AnyPublisher<String?, Never> { subject.eraseToAnyPublisher() }

    /// 当前值 —— 行首次出现时用它定初值,免得刚滚回来的那条丢了选中能力。
    var current: String? { subject.value }

    /// 悬停进入:把归属接过来。已经是自己就什么都不做(别白发一次通知)。
    func arm(_ id: String) {
        guard subject.value != id else { return }
        subject.send(id)
    }
}

/// 给一条气泡挂「按需文本选中」。macOS 走悬停接力;iOS 没有指针,长按选中是系统
/// 惯例,保持常开(iOS 侧也没有 `SelectionOverlay`/NSTextField 这条成本)。
struct BubbleTextSelection: ViewModifier {
    let id: String
    var owner: BubbleSelectionOwner = .shared

    @State private var armed = false

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onHover { inside in if inside { owner.arm(id) } }
            .onReceive(owner.publisher) { holder in
                let next = (holder == id)
                if armed != next { armed = next }
            }
            .onAppear { armed = (owner.current == id) }
            .environment(\.bubbleSelectable, armed)
        #else
        content.environment(\.bubbleSelectable, true)
        #endif
    }
}

/// 气泡内部(`BubbleView` / `MarkdownText`)读它决定挂不挂 `.textSelection`。
/// 走 environment 而不是逐层传参 —— `MarkdownText` 有一堆调用点,少改一处是一处。
/// 默认 `true`:气泡之外的调用点(来信正文、代码运行面板…)行为一字不变。
private struct BubbleSelectableKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var bubbleSelectable: Bool {
        get { self[BubbleSelectableKey.self] }
        set { self[BubbleSelectableKey.self] = newValue }
    }
}

/// `.textSelection(.enabled)` 与 `.textSelection(.disabled)` 是两个**不同的具体
/// 类型**(`EnabledTextSelectability` / `DisabledTextSelectability`),三元表达式
/// 写不出来,只能分支。收口成一个 modifier,免得每个调用点各写一遍 `if`。
private struct SelectableText: ViewModifier {
    @Environment(\.bubbleSelectable) private var selectable

    @ViewBuilder
    func body(content: Content) -> some View {
        if selectable {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}

extension View {
    /// 气泡里的可选中文字:由 `bubbleSelectable` 环境值决定挂不挂 overlay。
    func bubbleSelectableText() -> some View { modifier(SelectableText()) }

    /// 把这条气泡登记进「谁在指针底下谁能选」的接力。
    func bubbleTextSelection(id: String) -> some View {
        modifier(BubbleTextSelection(id: id))
    }
}
