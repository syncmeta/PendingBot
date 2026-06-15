#if os(macOS)
import SwiftUI

/// 本机模式配置页(无需 key,进入即用本机已登录的 claude/codex)。
///
/// 在 WelcomeView 点 "用本机的 claude / codex" 后到达。
/// 无需填写任何 key —— PendingCrew 直接驱动本机已登录的 claude code / codex，
/// 使用它们自己的订阅额度。点"进入"后调 `model.enterLocalMode()`，
/// RootView 监听变化自动跳主界面。
struct LocalSetupView: View {
    @EnvironmentObject private var model: AppModel
    /// 父 RootView 把 flow 状态传下来,这里 cancel/save 完通知它切回 welcome
    /// 或主界面。本组件不直接依赖路由 enum,以便将来从设置页复用。
    var onCancel: () -> Void = {}

    @State private var saving: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 360)
        .padding(.vertical, 4)
    }

    // MARK: - sections

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("用本机的 claude / codex")
                .font(.title3.weight(.semibold))
            Text("PendingCrew 直接驱动你本机**已登录**的 claude code / codex —— 用它们自己的订阅额度，**不需要 API key**。直接进入即可。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("直接进入即可，使用本机已登录的 claude / codex 订阅。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("返回") { onCancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(saving)
            Button {
                save()
            } label: {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("进入")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(saving)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - actions

    private func save() {
        saving = true
        model.enterLocalMode()
        saving = false
    }
}
#endif
