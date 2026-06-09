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
/// 现阶段只在 macOS 接入(iPad 翻转留给后续 task)。**五个 tab 全部**取共享
/// `FeatureSurface` 的 `listColumn` / `detailColumn`(「我」无 list,壳给中列
/// 空态、右栏放 `detailColumn`),不再有任何 Mac 平行列。每个 tab 持有各自的
/// 强类型 selection,壳把同一个 binding 喂给中列(写)和右栏(读)。
/// `#else`(iOS,此处暂未启用)各 tab 给跨平台占位 Text。
struct WideRootView: View {
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

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            middleColumn
        } detail: {
            detailColumn
        }
    }

    // MARK: - Columns

    private var sidebar: some View {
        // 单选侧栏:`List(selection:)` 要 `Binding<SelectionValue?>`,而
        // `selectedTab` 是非可选的 —— 派生一个永不为 nil 的 optional 绑定,
        // 两端(iOS/macOS)都能用同一个初始化器。
        let tabSelection = Binding<TopTab?>(
            get: { selectedTab },
            set: { if let new = $0 { selectedTab = new } }
        )
        return List(selection: tabSelection) {
            ForEach(TopTab.allCases) { tab in
                Label(tab.label, systemImage: tab.systemImage)
                    .tag(tab)
            }
        }
        .navigationTitle("PendingBot")
        .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 200)
    }

    @ViewBuilder
    private var middleColumn: some View {
        #if os(macOS)
        switch selectedTab {
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
        #else
        WidePlaceholderColumn(message: selectedTab.label)
            .navigationTitle(selectedTab.label)
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        #endif
    }

    @ViewBuilder
    private var detailColumn: some View {
        #if os(macOS)
        switch selectedTab {
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
        #else
        WidePlaceholderColumn(message: selectedTab.label, prominent: true)
        #endif
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
    }
}
