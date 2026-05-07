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
                // Two-color brand (#044735 + #fdfcfa) — light theme only.
                // Following system would force us to design + maintain a
                // dark variant we don't actually want.
                .preferredColorScheme(.light)
                .tint(Theme.Palette.accent)
                .background(Theme.Palette.canvas.ignoresSafeArea())
                #if targetEnvironment(macCatalyst)
                // Catalyst inherits CFBundleDisplayName ("大绿豆") into the
                // window titlebar by default — clear it so the chrome stays
                // out of the way of the in-app TabHeaderBar.
                .onAppear {
                    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                        scene.title = ""
                        scene.titlebar?.titleVisibility = .hidden
                    }
                }
                #endif
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
                    // Hydrate auth + start observing AFTER the first frame
                    // paints — keeps the launch screen short on real-device
                    // debug builds where SupabaseClient lazy init is heavy.
                    accountStore.bootstrap()
                    unreadStore.bind(account: accountStore.current)
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
        } else if store.hasBootstrapped == false {
            // Right after sign-in we run the random-name + random-avatar
            // onboarding. While `hasBootstrapped` is still nil (refresh
            // in flight) we show TabRoot to avoid a flash of onboarding
            // for users who already finished it on a previous launch.
            ProfileBootstrapView()
                .environmentObject(store)
        } else {
            TabRoot()
                .id(store.current?.id)
        }
    }
}
