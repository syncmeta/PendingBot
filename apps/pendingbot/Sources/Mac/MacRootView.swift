#if os(macOS)
import SwiftUI

/// PendingBot Mac 端基础壳 — T1.4。
///
/// 信息架构对齐 spec v2 §11.1（消息 / 好友 / Crew / 来信 / 我），布局
/// 走 spec v2 §11.3 的 Mac 三列：
///
/// ```
/// ┌──────────┬────────────────┬───────────────────────────┐
/// │ tabs     │ list / index   │ detail (conversation / …) │
/// │ sidebar  │                │                            │
/// └──────────┴────────────────┴───────────────────────────┘
/// ```
///
/// 当前阶段中间和右栏都是 placeholder。Mac 端业务接入（会话流、好友列表、
/// Crew 详情、subject 钱包等）依赖把 `Features/* / Networking/* / Storage/*`
/// 那批 UIKit-coupled 文件改造成跨平台,会在后续 task 渐进做 —— 这次只
/// 把骨架升级到三列,确保后续每个 tab 都有正确的"列宽 + selection state"
/// 接入位。
///
/// iPad 维持 iOS 分支（`TabView` → `PendingBotRegularRootView`），不走这条
/// 三列路径；iPad-specific 适配跟 Crew Tab 一起 Phase 2 再做。
enum MacTab: String, CaseIterable, Identifiable, Hashable {
    case messages
    case friends
    case crew
    case envelope
    case me

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: "消息"
        case .friends: "好友"
        case .crew: "机组"
        case .envelope: "来信"
        case .me: "我"
        }
    }

    var systemImage: String {
        switch self {
        // 对齐 iOS TopTab(SidebarTabBar.swift)的图标。
        case .messages: "bubble.left"
        case .friends: "person.2"
        case .crew: "command"
        case .envelope: "envelope.open"
        case .me: "person.crop.circle"
        }
    }

    /// 中间列标题（"会话 / 好友列表 / Crew / 来信 / 我"）。
    var middleColumnTitle: String {
        switch self {
        case .messages: "会话"
        case .friends: "好友"
        case .crew: "机组"
        case .envelope: "来信"
        case .me: "我"
        }
    }

    /// 中间列空态文案，提示这里将来会装什么。
    var middleColumnEmpty: String {
        switch self {
        case .messages: "会话列表会出现在这里"
        case .friends: "好友 / Bot 列表会出现在这里"
        case .crew: "v1 Crew Tab 即将上线"
        case .envelope: "来信 feed 会出现在这里"
        case .me: "账号与钱包条目会出现在这里"
        }
    }

    /// 右栏空态文案（选中一项后才显示真实详情）。
    var detailColumnEmpty: String {
        switch self {
        case .messages: "选中一条会话以查看消息"
        case .friends: "选中一位好友以查看资料"
        case .crew: "选中 Crew 频道查看详情"
        case .envelope: "选中一封来信查看正文"
        case .me: "选中条目查看详情"
        }
    }
}

struct MacRootView: View {
    @State private var selectedTab: MacTab = .messages
    /// 中间列的选中项。骨架阶段没有真实条目,所以这里只是 `String?`
    /// 占位 —— 后续接入会话 / 好友 / 来信时换成对应的 ID 类型。
    @State private var selectedItemId: String? = nil
    /// 跨 tab 跳转待定值(好友点 bot → 切到消息 tab 选中该会话)。切 tab 的
    /// onChange 会消费它,避免被「切 tab 清 selection」覆盖——确定性、无竞态。
    @State private var pendingConversationJump: String? = nil

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            middleColumn
        } detail: {
            detailColumn
        }
        // 还原登录窗的透明 + 圆角裁剪,否则主界面继承透明窗 → 不自带材质的
        // 空态列(右栏 MacEmptyColumn)直接透到桌面。见 MacMainWindowStyler。
        .background(MacMainWindowStyler())
        .onChange(of: selectedTab) { _, _ in
            // 切 tab 时清掉中间列的选中,避免上一个 tab 的 selection 串到下一个
            // tab 的右栏;但若是程序触发的跨 tab 跳转,改为选中目标会话。
            if let jump = pendingConversationJump {
                selectedItemId = jump
                pendingConversationJump = nil
            } else {
                selectedItemId = nil
            }
        }
    }

    // MARK: - Columns

    private var sidebar: some View {
        List(MacTab.allCases, selection: $selectedTab) { tab in
            Label(tab.title, systemImage: tab.systemImage)
                .tag(tab)
        }
        .navigationTitle("PendingBot")
        .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 200)
    }

    @ViewBuilder
    private var middleColumn: some View {
        switch selectedTab {
        case .messages:
            // T0.1 — 消息 tab 中列接入真实会话列表;选中一个会话后右栏是聊天。
            MacConversationListColumn(selectedConversationId: $selectedItemId)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        case .friends:
            // T0.1 — 好友 tab 中列:机器人 + 人类好友列表。点 bot → 跳到消息 tab
            // 选中它的会话(确定性 pendingConversationJump 状态机)。
            MacFriendsColumn(onOpenConversation: { convId in
                pendingConversationJump = convId
                selectedTab = .messages
            })
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        case .envelope:
            // T0.1 — 来信 tab 中列:奏折/信件 feed;选中看正文。
            MacEnvelopeColumn(selectedEnvelopeId: $selectedItemId)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        case .crew:
            // T4.5 — Crew tab 中列接入真实机组列表;选中一个 crew 后右栏看它的
            // 服务端 session(跨端 viewer)。其余 crew 业务(创建 / 群聊 / 详情)
            // 仍是 iOS-only,Mac 端后续渐进接入。
            MacCrewListColumn(selectedCrewId: $selectedItemId)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        default:
            MacEmptyColumn(message: selectedTab.middleColumnEmpty)
                .navigationTitle(selectedTab.middleColumnTitle)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch selectedTab {
        case .me:
            // T0.1 P0 已接入真实数据 — 展示 AccountStore.current 的账号信息,
            // 提供退出登录。subject / 钱包 / 注销账号 留给 T0.1 P1+。
            // 注:Mac 三列下,「我」tab 直接把账号详情放到右栏(中间列保持空态),
            // 因为「我」tab 没有可枚举的 list 内容。
            MacMeView()
        case .messages:
            if let convId = selectedItemId {
                MacChatView(conversationId: convId)
                    .id(convId)
            } else {
                MacEmptyColumn(message: selectedTab.detailColumnEmpty, prominent: true)
            }
        case .crew:
            if let crewId = selectedItemId {
                MacRemoteSessionsView(crewId: crewId)
            } else {
                MacEmptyColumn(message: selectedTab.detailColumnEmpty, prominent: true)
            }
        default:
            MacEmptyColumn(message: selectedTab.detailColumnEmpty, prominent: true)
        }
    }
}

/// Placeholder column used by both the middle and detail panes while
/// the real business surfaces are still iOS-only.
private struct MacEmptyColumn: View {
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

/// Reverts the cosmetic window surgery `MacLoginWindowStyler` applied to the
/// shared `NSWindow` for the login card (transparent backing + 22pt corner
/// clip on the contentView). The login and the main app live in the SAME
/// WindowGroup window, so without this the main app inherits a transparent,
/// corner-masked window — empty panes that don't paint their own material
/// (e.g. the detail column's `MacEmptyColumn`) show straight through to the
/// desktop. Here we put the window back to a normal opaque app window.
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
            // 登录窗复用同一个 NSWindow,透明设置可能在视图切换后才被
            // NavigationSplitView 合成过分隔区 → 首帧残留一条没铺到的细缝。
            // 单次 async restore 赶不上那一帧,所以再挂这几个事件补一拍,
            // 不依赖单一时机(跟 MacLoginWindowStyler 同套路)。
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
            // 强制整窗立即重绘,把首帧那条瞬态细缝在当帧就补掉,
            // 不用等用户重开窗口触发的下一次重布局。
            window.viewsNeedDisplay = true
            window.displayIfNeeded()
        }
    }
}

#Preview {
    MacRootView()
}
#endif
