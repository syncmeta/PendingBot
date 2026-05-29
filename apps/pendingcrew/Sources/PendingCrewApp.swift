import SwiftUI

@main
struct PendingCrewApp: App {
    @StateObject private var model: AppModel
    @StateObject private var crewStore: CrewStore

    init() {
        let appModel = AppModel()
        _model = StateObject(wrappedValue: appModel)
        _crewStore = StateObject(wrappedValue: CrewStore(appModel: appModel))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(crewStore)
                #if os(macOS)
                .frame(minWidth: 1040, minHeight: 680)
                .modifier(FirstLaunchDisclosureGate())
                #endif
        }
    }
}

#if os(macOS)
/// Spec v2 §8.4 — 把 "本机 agent = 完整用户权限" 的 disclosure modal 挂在
/// RootView 之上。仅每台机第一次启动 PendingCrew 时显示一次,接受后写
/// `UserDefaults` 不再弹。RootView 始终渲染在背后(用户接受前看不到也点不
/// 到主界面 —— sheet 是 modal)。
private struct FirstLaunchDisclosureGate: ViewModifier {
    /// 用 `@State` 而不是常量 —— `markAccepted()` 同步改 UserDefaults 后 SwiftUI
    /// 不会自动重渲(UserDefaults 不是 @Published);我们手动把 sheet 收起来。
    @State private var showing: Bool = !FirstLaunchDisclosure.isAccepted()

    func body(content: Content) -> some View {
        content.sheet(isPresented: $showing) {
            FirstLaunchDisclosureView {
                FirstLaunchDisclosure.markAccepted()
                showing = false
            }
            // `.interactiveDismissDisabled` 防用户 Esc / 点空白处绕过 modal。
            // disclosure 必须主动接受。
            .interactiveDismissDisabled()
        }
    }
}
#endif

/// 启动路由(T5.1 + T5.2)。三种顶层态:
/// 1. **WelcomeView** — 没凭据 + 没 BYOK key → 用户先选路径(扫码登录 / BYOK)
/// 2. **LoginView / LocalSetupView** — 用户已选路径,正在完成对应配置;
///    完成的那一刻 `AppModel.mode` 变化让 RootView 自动切到 #3
/// 3. **主界面** — Mac 走 `MacThreePaneView`,iPad/iOS 走 `IPadPlaceholderView`
///
/// `flow` 由 RootView 本地持有,仅用于"我点了 WelcomeView 的哪个按钮"
/// 这种 UI 瞬态;凭据本身的有无是真实数据源(AppModel)。一旦凭据写下来,
/// flow 跳回 .welcome 不影响主界面 —— `model.isConfigured` 优先取胜。
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var crewStore: CrewStore

    enum Flow {
        case welcome
        case login
        case localSetup
    }

    /// 本地 UI 选择 — 仅在 `!model.isConfigured` 时生效。
    /// 凭据写入后 `model.isConfigured == true` 优先,flow 无所谓。
    @State private var flow: Flow = .welcome

    var body: some View {
        Group {
            if model.isConfigured {
                authenticatedRoot
            } else {
                switch flow {
                case .welcome:
                    WelcomeView { choice in
                        switch choice {
                        case .login: flow = .login
                        case .localSetup: flow = .localSetup
                        }
                    }
                case .login:
                    LoginView()
                case .localSetup:
                    #if os(macOS)
                    LocalSetupView(onCancel: { flow = .welcome })
                    #else
                    // iOS 不该走到这里(WelcomeView 上根本不显示 BYOK 按钮),
                    // 兜底回 welcome。
                    WelcomeView { _ in flow = .welcome }
                    #endif
                }
            }
        }
        // 凭据消失(签出)时清 crew 缓存 + flow 回 welcome。
        .onChange(of: model.isConfigured) { _, configured in
            if !configured {
                crewStore.reset()
                flow = .welcome
            }
        }
    }

    @ViewBuilder
    private var authenticatedRoot: some View {
        #if os(iOS)
        IPadPlaceholderView()
        #else
        MacThreePaneView()
        #endif
    }
}

#if os(iOS)
struct IPadPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("PendingCrew iPad")
                .font(.largeTitle)
            Text("等待 peer / Fly machine 连接\n(scaffold — Phase 4.5 / v1.1 上线)")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif

// MacThreePaneView 实现挪到 Mac/Views/MacRootView.swift。
