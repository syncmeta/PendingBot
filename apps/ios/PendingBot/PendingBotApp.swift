import SwiftUI

@main
struct PendingBotApp: App {
    @StateObject private var accountStore = AccountStore.shared
    @StateObject private var unreadStore = UnreadStore.shared
    @StateObject private var modelCatalog = ModelCatalog.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Swap URLCache.shared for one whose backing dir is marked
        // NSFileProtectionCompleteUnlessOpen — attachment image bytes
        // cached by AsyncImage / ServerImage now sit encrypted at rest
        // while the device is locked. Must happen before the first
        // network request, hence early-init not .task.
        ProtectedURLCache.install()
        Haptics.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(accountStore)
                .environmentObject(unreadStore)
                .environmentObject(modelCatalog)
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
                    await accountStore.bootstrap()
                    unreadStore.bind(account: accountStore.current)
                    modelCatalog.loadIfNeeded()
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
    @Environment(\.scenePhase) private var scenePhase

    private var shouldObscure: Bool {
        scenePhase != .active && store.current != nil
    }

    var body: some View {
        Group {
            if !store.sessionHydrated {
                // bootstrap() runs in `.task` (after first frame) so we can't
                // know auth state synchronously — paint a launch-screen lookalike
                // until it's resolved, otherwise already-signed-in users see a
                // flash of WelcomeView before TabRoot.
                SplashView()
            } else if store.current == nil {
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
        // Privacy cover for the app-switcher snapshot. iOS captures a
        // screenshot of the frontmost frame during `.inactive` (the
        // transition phase before `.background`); without a cover, that
        // snapshot — kept in /var/mobile/.../Snapshots — shows the last
        // open conversation verbatim. Blurring the content during
        // `.inactive` redacts the snapshot while keeping the user's
        // mental model intact (no surprise launch screen on return).
        // Only signed-in surfaces need the cover.
        .blur(radius: shouldObscure ? 30 : 0)
        .animation(.easeInOut(duration: 0.15), value: scenePhase)
        // One-shot recovery banner: fires the first time we sign back in
        // while a deletion tombstone was still pending. AccountStore flips
        // accountRecovered after cancel_account_deletion() returned true.
        .alert("账号已恢复", isPresented: $store.accountRecovered) {
            Button("好") {}
        } message: {
            Text("你之前申请的注销已取消，账号和数据都还在。")
        }
    }
}

/// Mirrors the UILaunchScreen in Info.plist (Cream bg + LaunchLogo) so the
/// transition from system launch screen to SwiftUI is seamless while
/// AccountStore hydrates the persisted session.
private struct SplashView: View {
    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            // Asset is 384×384 @3x → 128pt natural size, matching the
            // UIKit launch screen rendering so the handoff is invisible.
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)
        }
    }
}
