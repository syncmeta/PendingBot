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
/// macOS @main 与 iPad regular 共用同一个壳。**四个 tab 全部**取共享
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
    /// 「我」tab 的选中项 —— 共享 `MeTabView` 的 `Selection`(`MeSection`)。
    /// 壳把同一个 binding 喂给中间列表列(写)和右栏详情(读);右栏按
    /// section 渲染对应详情(钱包/加好友方式/能力扩展/设置)。
    @State private var meSelection: MeSection? = nil
    /// 机组 tab 的选中项 —— 共享 `CrewTabView` 的 `Selection`(`crew_sessions.id`
    /// 字符串)。壳把同一个 binding 喂给列表列(写)和详情列(读);详情列的
    /// `CrewSessionDetailView` 按 id 自取数据。
    @State private var crewSelection: String? = nil

    /// 统一 tab 选择来源:外部注入(iPad,跟 `TabRoot.selected`)优先,否则
    /// 用内部 `@State`(macOS @main)。侧栏 List 与 中/右栏 switch 全部读它,
    /// 这样两条路径走同一份代码,深链翻 tab 在 iPad 上也能落到壳。
    private var tabSelection: Binding<TopTab> { externalTab ?? $selectedTab }

    var body: some View {
        NavigationSplitView {
            combinedSidebar
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

    /// 合并侧栏 = 窄图标 rail ＋ 当前 tab 的 list,整体作为 split view 的
    /// **唯一可折叠首列**(2 栏布局:sidebar | detail)。折叠按钮一下收起 rail+list,
    /// 把整宽让给右侧详情。五个 tab 同构 —— 「我」也有列表列(账号/设置菜单),
    /// 点条目右栏出详情。列宽 = rail(56)+ list,可拖动 300–560。
    private var combinedSidebar: some View {
        HStack(spacing: 0) {
            tabRail
                .frame(width: 56)
            middleColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        // 空标题:不显示任何文字,但**确立侧栏列自己的 toolbar 区**。否则各
        // tab 在 middleColumn 里声明的 toolbar 项无处可落,会漂到 detail 列的
        // 工具栏(折叠按钮右侧),与 PendingCrew「按钮在折叠按钮左侧」不符。
        .navigationTitle("")
        // 不自铺任何背景 —— rail 与 list 都透明,直接露出 NavigationSplitView
        // 侧栏列**自带的原生材质**(原来 List 侧栏那块)。list 列已去掉 canvas,
        // 所以整条侧栏是同一块原生底、中间无分隔。自糊 NSVisualEffectView 在
        // 这个被 MacMainWindowStyler 强制不透明的窗口里 behind-window 透不出来,
        // 反而发灰带渐变,故不用。
        // 列宽:默认 360(更紧凑);「我」现在也有列表列,不再 56px 特例。
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 560)
    }

    private var tabRail: some View {
        // 窄图标栏 —— **不用 `List`**:`List` 强制撑满全高 + 自带 inset 选中样式,
        // 硬压窄会挤掉 NavigationSplitView 的折叠按钮。改成自绘的竖向 rail,
        // 图标顶对齐(去掉顶部 `Spacer`),「我」用 `Spacer` 顶到最底、以本人头像
        // 作图标。纯图标无文字。写回经 `tabSelection` —— iPad 改 `TabRoot.selected`、
        // macOS 改内部 `@State`。
        let tabBinding = tabSelection
        return VStack(spacing: 2) {
            ForEach(TopTab.allCases.filter { $0 != .me }) { tab in
                railButton(tab, binding: tabBinding)
            }
            Spacer(minLength: 0)
            // 「我」固定在 rail 最底,图标 = 本人头像(上传图优先,否则确定性 emoji)。
            meRailButton(binding: tabBinding)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
    }

    /// 普通 tab 的 rail 按钮 —— 纯 SF Symbol,无文字。选中态 = 实心填充 + accent。
    private func railButton(_ tab: TopTab, binding: Binding<TopTab>) -> some View {
        let selected = binding.wrappedValue == tab
        return Button {
            if binding.wrappedValue != tab { binding.wrappedValue = tab }
        } label: {
            tab.symbol.image
                .font(Theme.Fonts.glyph(size: 16, weight: .regular))
                // 自定义 symbol 没有 fill 变体也会优雅回退到原轮廓。
                .symbolVariant(selected ? .fill : .none)
                .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.inkMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 「我」rail 按钮 —— 头像作图标,选中态用 accent 描边圈出。
    private func meRailButton(binding: Binding<TopTab>) -> some View {
        let selected = binding.wrappedValue == .me
        return Button {
            if binding.wrappedValue != .me { binding.wrappedValue = .me }
        } label: {
            UserAvatar(
                seed: AccountStore.shared.avatarSeed
                    ?? AccountStore.shared.current?.id ?? "?",
                attachmentId: AccountStore.shared.avatarAttachmentId,
                size: 26
            )
            .overlay(
                Circle().strokeBorder(
                    selected ? Theme.Palette.accent : Color.clear,
                    lineWidth: 2
                )
                .padding(-2)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        case .friends:
            // 好友 tab 中列 = 共享 `FriendsTabView` 的 list 列;选中一位好友
            // (PendingPeer)后右栏是会话 detail。
            FriendsTabView().listColumn(selection: $friendsSelection)
        case .envelope:
            // 来信 tab 中列 = 共享 `EnvelopeTabView` 的 feed 列;选中一封来信
            // (envelope_runs.id)后右栏是正文 detail。
            EnvelopeTabView().listColumn(selection: $envelopeSelection)
        case .crew:
            // 机组 tab 中列 = 共享 `CrewTabView` 的 session 卡片流;选中一个
            // session(crew_sessions.id)后右栏是遥控台 detail。
            CrewTabView().listColumn(selection: $crewSelection)
        case .me:
            // 「我」tab 中列 = 共享 `MeTabView` 的列表列(账号头部 + 设置菜单);
            // 选中一个 `MeSection`(钱包/加好友方式/能力扩展/设置)后右栏出详情。
            MeTabView().listColumn(selection: $meSelection)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch tabSelection.wrappedValue {
        case .me:
            // 「我」detail = 共享 surface 的 detail 列,按中列选中的 `MeSection`
            // 渲染对应详情(钱包/加好友方式/能力扩展/设置);无选中 → 空态。
            MeTabView().detailColumn(selection: meSelection)
        case .message:
            // 消息 detail = 共享 surface 的 detail 列,纯从 selection(ChatDest)
            // 解析。注意:这是与 list 列不同的 `MessageTabView()` 实例,二者
            // @State 互相不可见 —— detail 的 `bot(for:)` 读不到 list 列加载的
            // `bots`,会传 `bot: nil`;ConversationView 设计上能从
            // `pendingPeer?.peerId ?? conversation.bot_id` 自行解析 botId,所以
            // 仍可用(Phase 7 真机验证 bot 元信息渲染)。
            MessageTabView().detailColumn(selection: messagesSelection)
        case .friends:
            // 好友 detail = 共享 surface 的 detail 列,纯从 selection(PendingPeer)
            // 解析(同上 separate-@State 注意点:`bot: nil`,ConversationView 自解析)。
            FriendsTabView().detailColumn(selection: friendsSelection)
        case .envelope:
            // 来信 detail = 共享 surface 的 detail 列,纯从 selection
            // (envelope_runs.id)解析;`EnvelopeArticleView` 按 id 自取行 +
            // 订阅 Realtime,与中列是不同 `EnvelopeTabView()` 实例也无妨。
            EnvelopeTabView().detailColumn(selection: envelopeSelection)
        case .crew:
            // 机组 detail = 共享 surface 的 detail 列,按选中的 session id 渲染
            // 遥控台(live banner + transcript + 权限卡 + composer);
            // `CrewSessionDetailView` 按 id 自取数据 + 连 viewer WS。
            CrewTabView().detailColumn(selection: crewSelection)
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
        // 登录→主窗只做一次的「保持中心」处理(见 anchorGrowToCenter)。
        private var growHandled = false
        private var growConsumed = false
        private var anchorCenter: NSPoint?
        private var anchorPreSize: NSSize?

        func attach(to window: NSWindow) {
            self.window = window
            Self.restore(window)
            anchorGrowToCenter(window)
            guard !observed else { return }
            observed = true
            let nc = NotificationCenter.default
            for name: NSNotification.Name in [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didResizeNotification,
            ] {
                nc.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self, let w = self.window else { return }
                        Self.restore(w)
                        // 主窗因 .contentSize 从登录小窗长到主尺寸时会再发
                        // didResize —— 借这一拍把窗口重新锚回登录前的中心。
                        if note.name == NSWindow.didResizeNotification {
                            self.anchorGrowToCenter(w)
                        }
                    }
                }
            }
        }

        /// 让窗口从登录/占位小窗「长大」到主 app 尺寸时**以中心为锚**展开,
        /// 而不是 SwiftUI `.windowResizability(.contentSize)` 默认的「钉住左上角」
        /// —— 后者会让窗口往右下方蹿。一次性:读 `MacWindowGrowAnchor` 里登录
        /// 前记录的中心 + 旧尺寸,等 grow 落定(窗口确实变大)后把中心搬回去。
        private func anchorGrowToCenter(_ window: NSWindow) {
            guard !growHandled else { return }
            if !growConsumed {
                growConsumed = true
                anchorCenter = MacWindowGrowAnchor.center
                anchorPreSize = MacWindowGrowAnchor.preSize
                MacWindowGrowAnchor.center = nil
                MacWindowGrowAnchor.preSize = nil
            }
            guard let center = anchorCenter else { growHandled = true; return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, !self.growHandled else { return }
                // grow 还没落定(仍≈登录尺寸)→ 留给 grow 的 didResize 再触发。
                if let pre = self.anchorPreSize,
                   window.frame.width <= pre.width + 1,
                   window.frame.height <= pre.height + 1 {
                    return
                }
                self.growHandled = true
                var frame = window.frame
                frame.origin.x = (center.x - frame.width / 2).rounded()
                frame.origin.y = (center.y - frame.height / 2).rounded()
                // 夹在可见屏内,别把标题栏顶出屏幕。
                if let visible = window.screen?.visibleFrame {
                    frame.origin.x = min(max(frame.origin.x, visible.minX),
                                         max(visible.minX, visible.maxX - frame.width))
                    frame.origin.y = min(max(frame.origin.y, visible.minY),
                                         max(visible.minY, visible.maxY - frame.height))
                }
                window.setFrame(frame, display: true, animate: false)
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
