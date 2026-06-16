import SwiftUI

/// PendingCrew 登录入口页(iOS 路径)。
///
/// **接合 v2(spec 2026-06-10):双轨作废,本地为家**。macOS 上 `AppModel.isConfigured`
/// 恒为 true(本地 backend 常驻)→ RootView 直进主界面,**这页在 macOS 永不渲染**。
/// 它现在只服务 **iOS/iPad**:iOS 暂无本地后端(LocalRunner 是 macOS-only),仍需
/// 先扫码登录拿 device-grant 才能进。
///
/// 点「登录」走 device-login QR(`LoginView`)。状态切换的真正触发是 LoginView
/// 拿到 token 后 `AppModel.credential` 变化、`isConfigured` 翻 true,RootView
/// `@Published` 重新求值自动 route —— 这里**不直接**操作 AppModel。
struct WelcomeView: View {
    var onLogin: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 24)
            header
            Spacer(minLength: 8)
            loginButton
            Spacer(minLength: 16)
            footnote
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - sections

    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("PendingCrew")
                .font(.largeTitle.weight(.semibold))
            Text("登录以开始")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var loginButton: some View {
        Button(action: onLogin) {
            HStack(spacing: 14) {
                Image(systemName: "qrcode")
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("登录 PendingBot 账号")
                        .font(.headline)
                    Text("扫码授权这台机器,解锁云端 crew")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 480)
    }

    private var footnote: some View {
        Text("iPad 路径仅支持扫码登录;本机模式(驱动本机已登录的 claude/codex)是 Mac 专属(v1.0)。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}
