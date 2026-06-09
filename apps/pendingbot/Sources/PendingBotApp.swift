import SwiftUI

#if os(iOS)

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
        // Wire CallKit → app navigation. Set the closures here (rather
        // than later in .task) so a VoIP push that wakes us from a cold
        // launch and answers immediately still finds an `onIncomingAnswer`
        // hook to route into the conversation. App-launch init runs
        // before AppDelegate.didFinishLaunching's `bootstrap()`, which
        // is when the CallKit provider's delegate goes live.
        MainActor.assumeIsolated {
            CallKitManager.shared.onIncomingAnswer = { convId in
                // The two slots are read by different consumers:
                //   • MessageTabView.onChange(pendingNavConversationId)
                //     navigates the nav stack / sidebar selection.
                //   • ConversationView.onAppear(pendingAutoJoinConversationId)
                //     auto-opens GroupCallView so the user doesn't have
                //     to tap "join" after accepting in CallKit.
                IncomingCallStore.shared.pendingNavConversationId = convId
                IncomingCallStore.shared.pendingAutoJoinConversationId = convId
            }
            CallKitManager.shared.onIncomingDecline = { convId in
                // User declined via CallKit's incoming UI — release the
                // pending invite on the server so the inviter's UI drops
                // the ringing chip. Best-effort: a network failure here
                // just means the inviter sees a slightly delayed pending
                // entry expire on its own.
                Task { @MainActor in
                    guard let uid = AccountStore.shared.current?.id else { return }
                    try? await VoiceCallAPI().groupVoiceCancelInvite(
                        conversationId: convId,
                        targetId: uid,
                    )
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(accountStore)
                .environmentObject(unreadStore)
                .environmentObject(modelCatalog)
                // CallCenter is the app-level owner of the currently
                // active voice / group call — kept here (not inside a
                // tab) so the session survives navigation and the
                // floating-pill / cover hosted on TabRoot can read it.
                .environment(CallCenter.shared)
                // Two-color brand (#044735 + #fdfcfa) — light theme only.
                // Following system would force us to design + maintain a
                // dark variant we don't actually want.
                .preferredColorScheme(.light)
                .tint(Theme.Palette.accent)
                .background(Theme.Palette.canvas.ignoresSafeArea())
                // Universal links (applinks:bot.pendingname.com). SwiftUI
                // delivers both custom-scheme and associated-domain URLs
                // here. Bot-share links (/b/<slug>) get parked in
                // DeepLinkStore for the friends tab to consume.
                .onOpenURL { url in
                    DeepLinkStore.shared.handle(url)
                }
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

#elseif os(macOS)

/// PendingBot Mac 端 @main — T0.1 partial:5 tab 框架仍是 NavigationSplitView,
/// "我" tab 已接入真实 AccountStore(MacMeView),其余 tab 暂为 placeholder。
///
/// AccountStore 是单例,本来不依赖 EnvironmentObject 注入,但 SwiftUI
/// `@EnvironmentObject` 在 Mac 端 + macOS 14 起对 ObservableObject 的
/// 变更追踪比直接读单例更可靠(不需要在每个子视图里订阅),所以这里仍按
/// iOS 一致的方式把 AccountStore.shared 当 environmentObject 注入。
/// 窗口最小尺寸 1100x700,跟 PendingCrew Mac 端的体感保持一致。
@main
struct PendingBotApp: App {
    @StateObject private var accountStore = AccountStore.shared
    // 跟 iOS 一致:把 ModelCatalog.shared 当 environmentObject 注入,供
    // 共享建/管机器人面的模型选择器读目录。
    @StateObject private var modelCatalog = ModelCatalog.shared

    var body: some Scene {
        WindowGroup {
            // macOS 走会话 gate(未登录 → MacWelcomeView,已登录 → 跨平台
            // 三列 shell WideRootView),跟 iOS RootView 一致。
            MacRootGate()
                .environmentObject(accountStore)
                .environmentObject(modelCatalog)
                .task {
                    // 跟 iOS 入口对齐:.task 里 hydrate 持久化的 supabase
                    // session,避免冷启动直接闪过 "未登录" 态。
                    await accountStore.bootstrap()
                }
        }
        // 去掉窗口标题栏那条「大绿豆」标题条,让内容(尤其登录页)成一整片
        // full-bleed 画布;红绿灯交通灯按钮仍浮在左上角内容之上。
        .windowStyle(.hiddenTitleBar)
        // 窗口大小跟内容走:登录页是紧凑小窗,登录后 WideRootView 自己声明
        // minWidth 1100/minHeight 700 → 窗口长到主 app 尺寸(且仍可自由缩放)。
        .windowResizability(.contentSize)
        // A8:原生菜单栏命令(新建机器人 ⌘N / 新建会话 ⇧⌘N / 搜索 ⌘F)。
        .commands { AppCommands() }

        // A8:macOS 系统设置场景。用 SwiftUI 的 `Settings` 场景把 ⌘, 绑到
        // SettingsRootView;Settings 场景是独立窗口,environmentObject 不会从
        // WindowGroup 继承过来,所以这里单独注入 accountStore / modelCatalog。
        Settings {
            SettingsRootView()
                .environmentObject(accountStore)
                .environmentObject(modelCatalog)
        }
    }
}

#endif
