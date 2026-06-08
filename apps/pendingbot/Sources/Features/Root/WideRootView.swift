import SwiftUI

/// 共享三列宽屏壳 — A5。
///
/// 这是 `Mac/MacRootView.swift` 的跨平台化升级:同样的 `NavigationSplitView`
/// 三列骨架(tab 侧栏 / 中间 list / 右栏 detail)+ 同样的确定性
/// `pendingConversationJump` 选择状态机,但类型本身不带 `os()` guard,
/// 用共享的 `TopTab` 而非 Mac-private 的 `MacTab`。
///
/// ```
/// ┌──────────┬────────────────┬───────────────────────────┐
/// │ tab      │ list / index   │ detail (conversation / …) │
/// │ sidebar  │                │                            │
/// └──────────┴────────────────┴───────────────────────────┘
/// ```
///
/// 现阶段只在 macOS 接入(iPad 翻转留给后续 task)。已迁移的 tab(消息 / 好友)
/// 中列 / 右栏直接取共享 `FeatureSurface` 的 `listColumn` / `detailColumn`;
/// 未迁移的 tab(Crew / 来信 / 我)继续渲染现有可用的 Mac 平行列,不退化成
/// 空 placeholder。`#else`(iOS,此处暂未启用)各 tab 给跨平台占位 Text。
struct WideRootView: View {
    @State private var selectedTab: TopTab = .message
    /// 中间列的选中项。**未迁移**的 tab(crew / envelope)仍用 `String?` ID
    /// 占位驱动它们的 Mac 平行列。已迁移的好友 / 消息 tab 改用下面各自的
    /// 强类型 selection。
    @State private var selectedItemId: String? = nil
    /// 好友 tab 的选中项 —— 直接持有共享 `FriendsTabView` 的 `Selection`
    /// (`PendingPeer`),壳把同一个 binding 喂给 list 列(写)和 detail 列(读)。
    @State private var friendsSelection: PendingPeer? = nil
    /// 消息 tab 的选中项 —— 共享 `MessageTabView` 的 `Selection`(`ChatDest`)。
    @State private var messagesSelection: ChatDest? = nil
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
            // 来信 tab 中列:奏折/信件 feed;选中看正文。
            MacEnvelopeColumn(selectedEnvelopeId: $selectedItemId)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        case .crew:
            // Crew tab 中列接入真实机组列表;选中一个 crew 后右栏看它的
            // 服务端 session(跨端 viewer)。
            MacCrewListColumn(selectedCrewId: $selectedItemId)
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
            // 因为「我」tab 没有可枚举的 list 内容。
            MacMeView()
        case .message:
            // 消息 detail = 共享 surface 的 detail 列,纯从 selection(ChatDest)
            // 解析。注意:这是与 list 列不同的 `MessageTabView()` 实例,二者
            // @State 互相不可见 —— detail 的 `bot(for:)` 读不到 list 列加载的
            // `bots`,会传 `bot: nil`;ConversationView 设计上能从
            // `pendingPeer?.peerId ?? conversation.bot_id` 自行解析 botId,所以
            // 仍可用(Phase 7 真机验证 bot 元信息渲染)。
            MessageTabView().detailColumn(selection: messagesSelection)
        case .crew:
            if let crewId = selectedItemId {
                MacRemoteSessionsView(crewId: crewId)
            } else {
                WidePlaceholderColumn(message: "选中 Crew 频道查看详情", prominent: true)
            }
        case .friends:
            // 好友 detail = 共享 surface 的 detail 列,纯从 selection(PendingPeer)
            // 解析(同上 separate-@State 注意点:`bot: nil`,ConversationView 自解析)。
            FriendsTabView().detailColumn(selection: friendsSelection)
        case .envelope:
            if let envelopeId = selectedItemId {
                MacEnvelopeDetail(envelopeId: envelopeId)
                    .id(envelopeId)
            } else {
                WidePlaceholderColumn(message: "选中一封来信查看正文", prominent: true)
            }
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
