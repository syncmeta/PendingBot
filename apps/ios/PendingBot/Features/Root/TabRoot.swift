import SwiftUI

/// Three-tab root: 消息 / 好友 / 我.
///
/// Discuss / Surf / Review tabs are gone — discuss conversations land in
/// the message list with a 「议论」 badge; surf is accessed from a bot
/// friend's view; review surfaces inline as log cards.
struct TabRoot: View {
    @EnvironmentObject var store: AccountStore

    var body: some View {
        if let current = store.current {
            TabView {
                MessageTabView()
                    .tabItem { Label("消息", systemImage: "bubble.left") }

                FriendsTabView()
                    .tabItem { Label("好友", systemImage: "person.2") }

                MeTabView()
                    .tabItem { Label("我", systemImage: "person.crop.circle") }
            }
            .environment(\.api, APIClient())
            .environment(\.account, current)
            .onChange(of: store.current) { _, _ in Haptics.tap() }
        } else {
            // Defensive — RootView wouldn't have shown TabRoot otherwise.
            WelcomeView()
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
