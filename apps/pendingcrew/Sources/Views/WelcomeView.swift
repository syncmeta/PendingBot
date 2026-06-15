import SwiftUI

/// PendingCrew 启动选择页(T5.1 + T5.2)。
///
/// 首次进入(没有 device-grant token)显示这页,让用户在两条路径里挑:
/// - **登录 PendingBot 账号** — 走 device-login QR(`LoginView`),享 unified
///   billing + 云端 crew(Fly machine)。
/// - **本机模式(Mac 专属)** — 驱动本机已登录的 claude/codex,无需 key,
///   只在本机跑 crew。`LocalSetupView` 点"进入"即可。
///
/// iOS / iPad 不显本机模式按钮 — 本机后端(LocalRunner)是 macOS-only。
///
/// 选择信号通过 closure 返回 RootView,由 RootView 切换 `flow` state。这里
/// **不直接** 操作 AppModel —— 状态切换的真正触发是 LoginView 拿到 token
/// 或 LocalSetupView 调 `model.enterLocalMode()` 后 `AppModel.localModeSelected`
/// 变化,RootView `@Published` 重新求值自动 route。
struct WelcomeView: View {
    enum Choice {
        case login
        case localSetup
    }

    var onChoose: (Choice) -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 24)
            header
            Spacer(minLength: 8)
            buttons
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
            Text("选择启动方式")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 14) {
            choiceButton(
                icon: "qrcode",
                title: "登录 PendingBot 账号",
                subtitle: "扫码授权这台机器,解锁云端 crew"
            ) {
                onChoose(.login)
            }
            #if os(macOS)
            choiceButton(
                icon: "laptopcomputer",
                title: "用本机的 claude / codex",
                subtitle: "驱动本机已登录的 claude code / codex，无需 key，只在本机跑 crew"
            ) {
                onChoose(.localSetup)
            }
            #endif
        }
        .frame(maxWidth: 480)
    }

    private func choiceButton(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
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
    }

    @ViewBuilder
    private var footnote: some View {
        VStack(spacing: 4) {
            #if os(macOS)
            Text("两种模式各有取舍:登录走 PendingBot 账户管线、可用 Fly 云端机器;本机模式驱动本机已登录的 claude/codex,无需 key,只在本机跑 crew。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Text("一次选定后本版不可在 app 内切换 — 想换模式需清掉对应凭据后重启。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            #else
            Text("iPad 路径仅支持扫码登录;BYOK 是 Mac 专属(v1.0)。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            #endif
        }
    }
}
