import SwiftUI

@main
struct PendingBotApp: App {
    @StateObject private var accountStore = AccountStore.shared
    @StateObject private var unreadStore = UnreadStore.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Haptics.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(accountStore)
                .environmentObject(unreadStore)
                // Follow the system trait — Theme palette has matched
                // light + dark variants.
                .tint(Theme.Palette.accent)
                .background(Theme.Palette.canvas.ignoresSafeArea())
                .onChange(of: accountStore.current) { old, new in
                    unreadStore.bind(account: new)
                    // Sign-in transition (nil → account) is the moment to
                    // hand APNS over to PushService — the user has just
                    // authorized us to call /v1/devices/register.
                    if old == nil, new != nil {
                        Task { await PushService.shared.onSignedIn() }
                    }
                }
                .task {
                    unreadStore.bind(account: accountStore.current)
                    // Touch the Supabase client so its singleton initializes
                    // and the keychain-persisted session loads on first frame.
                    _ = SupabaseStack.shared
                    // If the user is already signed in from a previous
                    // launch, kick off the push registration flow now.
                    if accountStore.current != nil {
                        await PushService.shared.onSignedIn()
                    }
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
