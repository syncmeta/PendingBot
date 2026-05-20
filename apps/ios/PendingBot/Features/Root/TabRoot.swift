import SwiftUI

/// Four-tab root: 消息 / 好友 / 来信 / 我.
///
/// 来信 (Envelopes) hosts a feed of articles each bot has written for
/// the user; new envelopes are triggered from each conversation's
/// settings sheet.
///
/// Two layouts driven by horizontal size class:
///   • compact (iPhone): system `TabView` with the bottom tab bar
///   • regular (iPad / Mac Catalyst): the active tab is rendered
///     directly (no system tab bar), and each tab embeds a
///     `SidebarTabBar` at the bottom of its left column — the
///     WeChat / QQ iPad placement.
struct TabRoot: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject private var unread: UnreadStore
    @Environment(\.useSidebarLayout) private var sidebarLayout

    // Persisted across launches so reopening the app on iPad puts the
    // user back where they were. SceneStorage keeps it per-window which
    // matches Catalyst multi-window expectations.
    @SceneStorage("topTab") private var selectedRaw: String = TopTab.message.rawValue

    // Live selection source for the TabView. @State commits synchronously,
    // so the TabView never re-reads a stale value mid-transition — reading
    // @SceneStorage directly in the binding's getter caused a one-frame
    // flash back to the previous tab. Stays nil until the first switch so
    // the initial render still honours the persisted tab without a flash.
    @State private var liveTab: TopTab?

    private var selected: Binding<TopTab> {
        Binding(
            get: { liveTab ?? TopTab(rawValue: selectedRaw) ?? .message },
            set: { newValue in
                liveTab = newValue
                selectedRaw = newValue.rawValue
            }
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
        // 消息 tab badge — the system draws it on the tab item itself, so
        // it sits in the right place and never bleeds onto pushed or
        // presented views the way a hand-positioned overlay did.
        TabView(selection: selected) {
            MessageTabView()
                .tabItem { Label(TopTab.message.label, systemImage: TopTab.message.systemImage) }
                .badge(unread.totalUnreadCount)
                .tag(TopTab.message)

            FriendsTabView()
                .tabItem { Label(TopTab.friends.label, systemImage: TopTab.friends.systemImage) }
                .tag(TopTab.friends)

            EnvelopeTabView()
                .tabItem { Label(TopTab.envelope.label, systemImage: TopTab.envelope.systemImage) }
                .tag(TopTab.envelope)

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
        case .envelope: EnvelopeTabView()
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
