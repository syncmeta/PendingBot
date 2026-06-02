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
        case .crew: "Crew"
        case .envelope: "来信"
        case .me: "我"
        }
    }

    var systemImage: String {
        switch self {
        case .messages: "bubble.left.and.bubble.right"
        case .friends: "person.2"
        case .crew: "person.3.sequence"
        case .envelope: "envelope.open"
        case .me: "person.crop.circle"
        }
    }

    /// 中间列标题（"会话 / 好友列表 / Crew / 来信 / 我"）。
    var middleColumnTitle: String {
        switch self {
        case .messages: "会话"
        case .friends: "好友"
        case .crew: "Crew"
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

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            middleColumn
        } detail: {
            detailColumn
        }
        .onChange(of: selectedTab) { _, _ in
            // 切 tab 时清掉中间列的选中,避免上一个 tab 的 selection
            // 串到下一个 tab 的右栏。
            selectedItemId = nil
        }
    }

    // MARK: - Columns

    private var sidebar: some View {
        List(MacTab.allCases, selection: $selectedTab) { tab in
            Label(tab.title, systemImage: tab.systemImage)
                .tag(tab)
        }
        .navigationTitle("PendingBot")
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    }

    @ViewBuilder
    private var middleColumn: some View {
        switch selectedTab {
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
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            Text(message)
                .font(prominent ? .title3 : .callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    MacRootView()
}
#endif
