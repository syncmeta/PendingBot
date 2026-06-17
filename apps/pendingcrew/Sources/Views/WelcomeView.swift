import SwiftUI

/// PendingCrew 登录入口页(iOS 路径)。
///
/// **接合 v2(spec 2026-06-10):双轨作废,本地为家**。macOS 上 `AppModel.isConfigured`
/// 恒为 true(本地 backend 常驻)→ RootView 直进主界面,**这页在 macOS 永不渲染**。
/// 它现在只服务 **iOS/iPad**:iOS 暂无本地后端(LocalRunner 是 macOS-only),仍需
/// 先扫码登录拿 device-grant 才能进。
///
/// 逻辑：检测到本机已登录(共享 keychain 有家族凭据)→ 先展示确认卡；
/// 用户确认 → `model.tryFamilySSO()` mint；失败/无凭据 → 降到 `LoginView`。
struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingLogin = false
    @State private var minting = false
    @State private var mintError: String?

    var body: some View {
        Group {
            if let identity = CrewLoginIdentity.current(), !showingLogin {
                VStack(spacing: 16) {
                    AccountConfirmCard(
                        identity: identity,
                        isBusy: minting,
                        onContinue: {
                            minting = true
                            mintError = nil
                            Task {
                                let ok = await model.tryFamilySSO()
                                minting = false
                                if !ok {
                                    // 凭据可能失效 —— 落到登录页让用户重新登录。
                                    mintError = "本机登录凭据可能已失效，请重新登录。"
                                    showingLogin = true
                                }
                            }
                        },
                        onUseOther: { showingLogin = true }
                    )
                    if let mintError {
                        Text(mintError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                LoginView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
