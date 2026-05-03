import SwiftUI

/// Four-tab root: 消息 / 好友 / 奏折 / 我.
///
/// 奏折 hosts a feed of articles each bot has written for the user;
/// review surfaces inline in conversations as log cards.
struct TabRoot: View {
    @EnvironmentObject var store: AccountStore

    var body: some View {
        if let current = store.current {
            TabView {
                MessageTabView()
                    .tabItem { Label("消息", systemImage: "bubble.left") }

                FriendsTabView()
                    .tabItem { Label("好友", systemImage: "person.2") }

                ScrollTabView()
                    .tabItem { Label("奏折", systemImage: "scroll") }

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
