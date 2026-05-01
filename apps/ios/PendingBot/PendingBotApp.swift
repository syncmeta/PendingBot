import SwiftUI

@main
struct PendingBotApp: App {
    @StateObject private var accountStore = AccountStore.shared
    @StateObject private var unreadStore = UnreadStore.shared

    init() {
        Haptics.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(accountStore)
                .environmentObject(unreadStore)
                // Two-color brand (#044735 + #fdfcfa) — light theme only.
                // Following system would force us to design + maintain a
                // dark variant we don't actually want.
                .preferredColorScheme(.light)
                .tint(Theme.Palette.accent)
                .background(Theme.Palette.canvas.ignoresSafeArea())
                .onChange(of: accountStore.current) { _, new in
                    unreadStore.bind(account: new)
                }
                .task {
                    unreadStore.bind(account: accountStore.current)
                    // Touch the Supabase client so its singleton initializes
                    // and the keychain-persisted session loads on first frame.
                    _ = SupabaseStack.shared
                }
        }
    }
}

/// Decides whether to show onboarding or the main TabView based on auth state.
struct RootView: View {
    @EnvironmentObject var store: AccountStore

    var body: some View {
        if store.current == nil {
            WelcomeView()
        } else {
            TabRoot()
                // Re-instantiate downstream views when the user switches
                // identities — the .id() forces a full rebuild.
                .id(store.current?.id)
        }
    }
}
