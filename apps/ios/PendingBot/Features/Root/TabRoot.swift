import SwiftUI

/// Four-tab root: 消息 / 好友 / 奏折 / 我.
///
/// 奏折 hosts a feed of articles each bot has written for the user;
/// review surfaces inline in conversations as log cards.
///
/// Two layouts driven by horizontal size class:
///   • compact (iPhone): system `TabView` with the bottom tab bar
///   • regular (iPad / Mac Catalyst): the active tab is rendered
///     directly (no system tab bar), and each tab embeds a
///     `SidebarTabBar` at the bottom of its left column — the
///     WeChat / QQ iPad placement.
struct TabRoot: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.useSidebarLayout) private var sidebarLayout

    // Persisted across launches so reopening the app on iPad puts the
    // user back where they were. SceneStorage keeps it per-window which
    // matches Catalyst multi-window expectations.
    @SceneStorage("topTab") private var selectedRaw: String = TopTab.message.rawValue

    private var selected: Binding<TopTab> {
        Binding(
            get: { TopTab(rawValue: selectedRaw) ?? .message },
            set: { selectedRaw = $0.rawValue }
        )
    }

    var body: some View {
        if store.current != nil {
            Group {
                if sidebarLayout {
                    regularBody
                } else {
                    compactBody
                }
            }
            .environment(\.api, APIClient())
            .environment(\.account, store.current)
            .environment(\.topTabSelection, selected)
            .onChange(of: store.current) { _, _ in Haptics.tap() }
        } else {
            // Defensive — RootView wouldn't have shown TabRoot otherwise.
            WelcomeView()
        }
    }

    // ── Compact (iPhone) ────────────────────────────────────────────────────

    private var compactBody: some View {
        TabView(selection: selected) {
            MessageTabView()
                .tabItem { Label(TopTab.message.label, systemImage: TopTab.message.systemImage) }
                .tag(TopTab.message)

            FriendsTabView()
                .tabItem { Label(TopTab.friends.label, systemImage: TopTab.friends.systemImage) }
                .tag(TopTab.friends)

            ScrollTabView()
                .tabItem { Label(TopTab.scroll.label, systemImage: TopTab.scroll.systemImage) }
                .tag(TopTab.scroll)

            MeTabView()
                .tabItem { Label(TopTab.me.label, systemImage: TopTab.me.systemImage) }
                .tag(TopTab.me)
        }
    }

    // ── Regular (iPad landscape, Mac Catalyst) ──────────────────────────────

    @ViewBuilder
    private var regularBody: some View {
        switch selected.wrappedValue {
        case .message: MessageTabView()
        case .friends: FriendsTabView()
        case .scroll:  ScrollTabView()
        case .me:      MeTabView()
        }
    }
}

// ── EnvironmentValues ───────────────────────────────────────────────────────
// The TabRoot owns the active APIClient + Account; child views read them
// via @Environment so we don't have to thread bindings through every layer.

private struct AccountKey: EnvironmentKey { static let defaultValue: Account? = nil }
private struct APIKey: EnvironmentKey { static let defaultValue: APIClient? = nil }

extension EnvironmentValues {
    var account: Account? {
        get { self[AccountKey.self] }
        set { self[AccountKey.self] = newValue }
    }
    var api: APIClient? {
        get { self[APIKey.self] }
        set { self[APIKey.self] = newValue }
    }
}
