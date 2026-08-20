import SwiftUI

#if os(iOS)

@main
struct PendingBotApp: App {
    @StateObject private var accountStore = AccountStore.shared
    @StateObject private var unreadStore = UnreadStore.shared
    @StateObject private var modelCatalog = ModelCatalog.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// App-wide appearance override (跟随系统/浅/深), set in 设置. `.system`
    /// resolves to nil → follow the OS. Replaces the old hard-forced `.light`.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.default.rawValue

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
            // Init telemetry / billing-identity SDKs before the first frame so
            // Sentry catches launch crashes. No-ops for any SDK whose key is
            // unset (see Telemetry / HostedConfig).
            Telemetry.shared.configure()
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
                // Appearance honors the 设置 override: 跟随系统/浅/深.
                // `.system` → nil → follow the OS. The brand's dark variant
                // (2026-06-11 spec) is carried by the adaptive `Theme.Palette`.
                .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .default).colorScheme)
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
                    // 换号守卫:新旧 user id 均非 nil 且不同 = 会话被原地换成
                    // 另一个账号(没经过 signOut,本地缓存还是上一个账号的)。
                    // 触发与登出同级的本地清库(见 handleAccountSwitch)。
                    // 正常 token 刷新是同 id(Account 含 jwt,Equatable 变化
                    // 也会进 onChange),id 相等即跳过,不会误清。
                    if let oldId = old?.id, let newId = new?.id, oldId != newId {
                        accountStore.handleAccountSwitch()
                    }
                    unreadStore.bind(account: new)
                    // Keep telemetry / billing-identity SDKs in sync with the
                    // active session: identify on sign-in, reset on sign-out.
                    if let id = new?.id {
                        Telemetry.shared.identify(id)
                    } else {
                        Telemetry.shared.reset()
                    }
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
                    // launch, kick off the push registration flow now and
                    // re-assert telemetry identity (cold launch may hydrate
                    // `current` before onChange is observing).
                    if let id = accountStore.current?.id {
                        Telemetry.shared.identify(id)
                    }
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

/// PendingBot Mac 端 @main — 已登录走跨平台三列壳 `WideRootView`;消息 /
/// 好友 / 来信 / 我 tab 均接共享 `FeatureSurface`。
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
    // 共享 feature 视图(MessageTab/Envelope/SidebarTabBar)都声明了
    // @EnvironmentObject UnreadStore — 不注入会在首屏 load() 即断言崩溃。
    @StateObject private var unreadStore = UnreadStore.shared
    // 外观覆盖(跟随系统/浅/深),设置里改;`.system`→nil→跟随系统。
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.default.rawValue

    init() {
        // 跟 iOS 入口对齐:首帧前 init 观测/计费身份 SDK(空 key 自动 no-op)。
        MainActor.assumeIsolated {
            Telemetry.shared.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            // macOS 走会话 gate(未登录 → MacWelcomeView,已登录 → 跨平台
            // 三列 shell WideRootView),跟 iOS RootView 一致。
            MacRootGate()
                .environmentObject(accountStore)
                .environmentObject(modelCatalog)
                .environmentObject(unreadStore)
                // 跟 iOS TabRoot 一致:注入 \.api / \.account。这两个
                // EnvironmentKey 的值原本只在 iOS 的 Tabroot 注入,Mac @main
                // 漏了 —— 共享 Features/* 视图里读 \.api 的(模型选择器走
                // /v1/models、远程 session 等)在 Mac 上拿到 nil,模型列表
                // 的 load() 在 `guard let api else { return }` 直接返回、
                // loading 永远停在 true → 一直转圈、建不了机器人。
                .environment(\.api, APIClient())
                .environment(\.account, accountStore.current)
                // macOS 把 Form 默认渲染成 `.columns`(左标签/右控件的裸网格,
                // 分组标题成几行裸文字 —— 看着像"没套样式")。`.formStyle` 是
                // 会向下级联的环境修饰符,在 scene 根设一次,主窗里所有共享
                // Form(设置/建管机器人/群设置/会话设置…)都继承到分组卡片
                // 外观,跟 iOS 默认的 `.grouped` 对齐。iOS 段无此修饰(默认即
                // grouped),互不影响。
                .formStyle(.grouped)
                // 跟 iOS 一致:外观跟随设置(跟随系统/浅/深)。深色变体由
                // 自适应 Theme.Palette 承载(2026-06-11 spec)。
                .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .default).colorScheme)
                // 跟 iOS 一致:登录态变化时同步观测/计费身份。
                .onChange(of: accountStore.current) { _, new in
                    unreadStore.bind(account: new)
                    if let id = new?.id {
                        Telemetry.shared.identify(id)
                    } else {
                        Telemetry.shared.reset()
                    }
                }
                .task {
                    // 跟 iOS 入口对齐:.task 里 hydrate 持久化的 supabase
                    // session,避免冷启动直接闪过 "未登录" 态。
                    await accountStore.bootstrap()
                    unreadStore.bind(account: accountStore.current)
                    // 冷启动已登录:补一次 identify(onChange 可能尚未在观测)。
                    if let id = accountStore.current?.id {
                        Telemetry.shared.identify(id)
                    }
                }
        }
        // 去掉窗口标题栏那条「大绿豆」标题条,让内容(尤其登录页)成一整片
        // full-bleed 画布;红绿灯交通灯按钮仍浮在左上角内容之上。
        .windowStyle(.hiddenTitleBar)
        // 窗口大小跟内容走:登录页是紧凑小窗,登录后 WideRootView 自己声明
        // 920×620 的主 app 尺寸(且仍可自由缩放)。
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
                // Settings 是独立场景,不从主窗继承环境;跟主窗一样补注
                // \.api / \.account,设置里的模型选择器等才能读到。
                .environment(\.api, APIClient())
                .environment(\.account, accountStore.current)
                // Settings 是独立场景,不继承主窗的 `.formStyle` —— 单独设一次,
                // 让 ⌘, 设置窗里的 Form 也是分组卡片而非 macOS 默认的 columns。
                .formStyle(.grouped)
                // 独立场景不继承主窗的 preferredColorScheme —— 单独绑同一个
                // 设置,这样在 ⌘, 窗里改外观时它本身也即时重绘。
                .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .default).colorScheme)
        }
    }
}

#endif
