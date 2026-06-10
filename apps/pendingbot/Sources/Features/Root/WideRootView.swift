import SwiftUI

/// 共享三列宽屏壳 — A5。
///
/// 这是 `Mac/MacRootView.swift` 的跨平台化升级:同样的 `NavigationSplitView`
/// 三列骨架(tab 侧栏 / 中间 list / 右栏 detail),但类型本身不带 `os()`
/// guard,用共享的 `TopTab` 而非 Mac-private 的 `MacTab`。
///
/// ```
/// ┌──────────┬────────────────┬───────────────────────────┐
/// │ tab      │ list / index   │ detail (conversation / …) │
/// │ sidebar  │                │                            │
/// └──────────┴────────────────┴───────────────────────────┘
/// ```
///
/// macOS @main 与 iPad regular 共用同一个壳。**五个 tab 全部**取共享
/// `FeatureSurface` 的 `listColumn` / `detailColumn`(「我」无 list,壳给中列
/// 空态、右栏放 `detailColumn`),不再有任何 Mac 平行列。每个 tab 持有各自的
/// 强类型 selection,壳把同一个 binding 喂给中列(写)和右栏(读)。
/// 中/右栏的 list/detail 渲染是跨平台的(`FeatureSurface` 方法不带 `os()`
/// guard),iOS 与 macOS 走同一份 switch,不再有 iOS 占位分支。
///
/// ## tab 选择来源 — 内部 `@State` vs 外部 binding
/// macOS @main 路径(`WideRootView()` 无参)用内部 `@State selectedTab`,壳
/// 自己拥有 tab 选择。iPad 路径(`WideRootView(externalTab:)`)由 `TabRoot`
/// 注入它的 `selected` 绑定,壳跟着 `TabRoot` 的选择走 —— 这样深链翻 tab
/// (`/b/<slug>` → 好友、群邀请 → 消息)经 `TabRoot.onChange` 改 `selected`
/// 后,壳侧栏与中/右栏会同步切换。`tabSelection` 计算属性统一这两条路径:
/// `externalTab ?? $selectedTab`。
struct WideRootView: View {
    /// 外部 tab 绑定 —— iPad 由 `TabRoot` 注入(承接深链翻 tab);macOS @main
    /// 不传(`nil`),壳退回内部 `@State selectedTab`,行为与接入前完全一致。
    var externalTab: Binding<TopTab>? = nil
    @State private var selectedTab: TopTab = .message
    /// 好友 tab 的选中项 —— 直接持有共享 `FriendsTabView` 的 `Selection`
    /// (`PendingPeer`),壳把同一个 binding 喂给 list 列(写)和 detail 列(读)。
    @State private var friendsSelection: PendingPeer? = nil
    /// 消息 tab 的选中项 —— 共享 `MessageTabView` 的 `Selection`(`ChatDest`)。
    @State private var messagesSelection: ChatDest? = nil
    /// 来信 tab 的选中项 —— 共享 `EnvelopeTabView` 的 `Selection`(`envelope_runs.id`
    /// 字符串)。壳把同一个 binding 喂给 feed 列(写)和正文列(读);正文列的
    /// `EnvelopeArticleView` 按 id 自取行,所以只需带 id。
    @State private var envelopeSelection: String? = nil
    /// Crew tab 的选中项 —— 共享 `CrewTabV2View` 的 `Selection`(crew id 字符串)。
    /// 壳把同一个 binding 喂给 list 列(写)和 detail 列(读);detail 列的
    /// `CrewDetailV2View` 按 id 自取机组(`getCrewV2`),所以只需带 id。
    @State private var crewSelection: String? = nil

    /// 统一 tab 选择来源:外部注入(iPad,跟 `TabRoot.selected`)优先,否则
    /// 用内部 `@State`(macOS @main)。侧栏 List 与 中/右栏 switch 全部读它,
    /// 这样两条路径走同一份代码,深链翻 tab 在 iPad 上也能落到壳。
    private var tabSelection: Binding<TopTab> { externalTab ?? $selectedTab }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            middleColumn
        } detail: {
            detailColumn
        }
        #if os(macOS)
        // 还原登录窗的透明 + 圆角裁剪(MacLoginWindowStyler 对共享 NSWindow
        // 做的手术),否则登录后主界面继承透明窗 → 不自带材质的空态列直接
        // 透到桌面。登录与主 app 共用同一个 WindowGroup 窗口。
        .background(MacMainWindowStyler())
        #endif
    }

    // MARK: - Columns

    private var sidebar: some View {
        // 单选侧栏:`List(selection:)` 要 `Binding<SelectionValue?>`,而
        // `tabSelection` 是非可选的 —— 派生一个永不为 nil 的 optional 绑定,
        // 两端(iOS/macOS)都能用同一个初始化器。写回经 `tabSelection`,
        // 所以 iPad 点侧栏会改 `TabRoot.selected`、macOS 改内部 `@State`。
        let tabBinding = tabSelection
        let listSelection = Binding<TopTab?>(
            get: { tabBinding.wrappedValue },
            set: { if let new = $0 { tabBinding.wrappedValue = new } }
        )
        return List(selection: listSelection) {
            ForEach(TopTab.allCases) { tab in
                Label(tab.label, systemImage: tab.systemImage)
                    .tag(tab)
            }
        }
        .navigationTitle("PendingBot")
        .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 200)
    }

    // 中/右栏取共享 `FeatureSurface` 的 list/detail 列。这些方法是跨平台的
    // (各 tab 的 extension 不带 `os()` guard),所以同一份 switch 在 macOS
    // @main 与 iPad regular 上都渲染真业务面 —— 不再有 iOS 占位分支。
    @ViewBuilder
    private var middleColumn: some View {
        switch tabSelection.wrappedValue {
        case .message:
            // 消息 tab 中列 = 共享 `MessageTabView` 的 list 列;选中一个会话
            // (ChatDest)后右栏是聊天 detail。壳持有 selection,list 写、detail 读。
            MessageTabView().listColumn(selection: $messagesSelection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        case .friends:
            // 好友 tab 中列 = 共享 `FriendsTabView` 的 list 列;选中一位好友
            // (PendingPeer)后右栏是会话 detail。
            FriendsTabView().listColumn(selection: $friendsSelection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        case .envelope:
            // 来信 tab 中列 = 共享 `EnvelopeTabView` 的 feed 列;选中一封来信
            // (envelope_runs.id)后右栏是正文 detail。
            EnvelopeTabView().listColumn(selection: $envelopeSelection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        case .crew:
            // Crew tab 中列 = 共享 `CrewTabV2View` 的 list 列;选中一个 crew
            // (crew id)后右栏是机组群聊 detail。
            CrewTabV2View().listColumn(selection: $crewSelection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        case .me:
            // 「我」tab 没有可枚举的 list 内容,中间列保持空态;账号详情放右栏。
            WidePlaceholderColumn(message: "账号与钱包条目会出现在这里")
                .navigationTitle("我")
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch tabSelection.wrappedValue {
        case .me:
            // 「我」tab 直接把账号详情放到右栏(中间列保持空态),
            // 因为「我」tab 没有可枚举的 list 内容。右栏取共享
            // `MeTabView` 的 `detailColumn`(FeatureSurface「无列表型」),
            // 取代已删的 Mac 平行 `MacMeView`。selection 对「我」无语义,
            // 传 nil。
            MeTabView().detailColumn(selection: nil)
        case .message:
            // 消息 detail = 共享 surface 的 detail 列,纯从 selection(ChatDest)
            // 解析。注意:这是与 list 列不同的 `MessageTabView()` 实例,二者
            // @State 互相不可见 —— detail 的 `bot(for:)` 读不到 list 列加载的
            // `bots`,会传 `bot: nil`;ConversationView 设计上能从
            // `pendingPeer?.peerId ?? conversation.bot_id` 自行解析 botId,所以
            // 仍可用(Phase 7 真机验证 bot 元信息渲染)。
            MessageTabView().detailColumn(selection: messagesSelection)
        case .crew:
            // Crew detail = 共享 surface 的 detail 列,纯从 selection(crew id)
            // 解析;`CrewDetailV2View` 按 id 自取机组 + 订阅 Realtime,与中列
            // 是不同 `CrewTabV2View()` 实例也无妨。
            CrewTabV2View().detailColumn(selection: crewSelection)
        case .friends:
            // 好友 detail = 共享 surface 的 detail 列,纯从 selection(PendingPeer)
            // 解析(同上 separate-@State 注意点:`bot: nil`,ConversationView 自解析)。
            FriendsTabView().detailColumn(selection: friendsSelection)
        case .envelope:
            // 来信 detail = 共享 surface 的 detail 列,纯从 selection
            // (envelope_runs.id)解析;`EnvelopeArticleView` 按 id 自取行 +
            // 订阅 Realtime,与中列是不同 `EnvelopeTabView()` 实例也无妨。
            EnvelopeTabView().detailColumn(selection: envelopeSelection)
        }
    }
}

/// 壳里中间 / 右栏暂未接入业务面时的跨平台占位列(居中文案)。
/// 不用 iOS-locked 的 `EmptyDetailHint`,也不用 MacRootView private 的
/// `MacEmptyColumn` —— 这俩都跨不过来,所以壳自带一个最小占位。
private struct WidePlaceholderColumn: View {
    let message: String
    var prominent: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            if prominent {
                Image(systemName: "sparkles")
                    .font(Theme.Fonts.glyph(size: 32, weight: .light))
                    .foregroundStyle(Theme.Palette.inkMuted.opacity(0.6))
            }
            Text(message)
                .font(prominent ? Theme.Fonts.title3 : Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas)
    }
}

#if os(macOS)
import AppKit

/// 还原 `MacLoginWindowStyler` 对共享 `NSWindow` 做的化妆手术(透明 backing
/// + contentView 22pt 圆角裁剪)。登录卡片与主 app 住同一个 WindowGroup 窗口,
/// 不还原的话主 app 继承透明 + 圆角窗 —— 不自绘材质的空态列(如 detail 列的
/// 占位)会直接透到桌面。这里把窗口恢复成正常不透明 app 窗口。
/// (从已删除的 MacRootView.swift 搬来,随 WideRootView 接管 macOS 主壳。)
private struct MacMainWindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { [weak v] in
            if let w = v?.window { context.coordinator.attach(to: w) }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            if let w = nsView?.window { context.coordinator.attach(to: w) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observed = false

        func attach(to window: NSWindow) {
            self.window = window
            Self.restore(window)
            guard !observed else { return }
            observed = true
            let nc = NotificationCenter.default
            for name: NSNotification.Name in [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didResizeNotification,
            ] {
                nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let w = self.window else { return }
                        Self.restore(w)
                    }
                }
            }
        }

        private static func restore(_ window: NSWindow) {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            if let content = window.contentView {
                content.wantsLayer = true
                content.layer?.masksToBounds = false
                content.layer?.cornerRadius = 0
            }
            window.invalidateShadow()
            window.viewsNeedDisplay = true
            window.displayIfNeeded()
        }
    }
}
#endif
