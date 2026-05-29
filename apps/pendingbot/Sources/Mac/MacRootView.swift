#if os(macOS)
import SwiftUI

/// PendingBot Mac 端的 5 tab 基础壳 — T1.4 partial。
///
/// 信息架构对齐 spec v2 §11.1（消息 / 好友 / Crew / 来信 / 我）。当前阶段
/// 只是 NavigationSplitView 占位:sidebar 列出 5 个 tab,detail 区每个 tab
/// 都是 Phase 2 实际内容的提示卡。Mac 端真正接入业务（会话流、好友列表、
/// Crew 详情、subject 钱包等）留给后续 task 渐进做。
///
/// iPad 维持 iOS 分支（TabView），不走这条 NavigationSplitView 路径 ——
/// iPad-specific 适配跟 Crew Tab 一起 Phase 2 再做。
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
}

struct MacRootView: View {
    @State private var selectedTab: MacTab = .messages

    var body: some View {
        NavigationSplitView {
            List(MacTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .navigationTitle("PendingBot")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detailContent
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .messages:
            MacTabPlaceholder(
                title: "消息",
                note: "Phase 2 接入现有 iOS 会话列表 + 消息流"
            )
        case .friends:
            MacTabPlaceholder(title: "好友", note: "Phase 2")
        case .crew:
            MacTabPlaceholder(
                title: "Crew",
                note: "Phase 2 — 见 spec v2 §11.2,接 spec v2 §6 的 crew 群聊 UI"
            )
        case .envelope:
            MacTabPlaceholder(title: "来信", note: "Phase 2")
        case .me:
            // T0.1 P0 已接入真实数据 — 展示 AccountStore.current 的账号信息,
            // 提供退出登录。subject / 钱包 / 注销账号 留给 T0.1 P1+。
            MacMeView()
        }
    }
}

private struct MacTabPlaceholder: View {
    let title: String
    let note: String

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 36, weight: .semibold))
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    MacRootView()
}
#endif
