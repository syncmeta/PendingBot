#if os(macOS)
import SwiftUI

/// BYOK 配置页(未登录直接用路径)。
///
/// 在 WelcomeView 点 "不登录直接用 (BYOK)" 后到达。三个 SecureField 收
/// Anthropic / OpenAI / Gemini provider key,至少一个非空即可完成。
///
/// 写盘走 `AppModel.saveByokConfig(_:)` → `BYOKConfig.save()` → Keychain。
/// 不做 key 验证(scope 之外);写入后 AppModel.mode 转 `.byok`,RootView
/// 自动切到 `MacThreePaneView`。
///
/// **跟 LoginView 平级**:WelcomeView 在登录 / BYOK 之间二选一,选完 mode
/// 锁定;本次 scope 内不支持在 app 内切回 WelcomeView(签出走清凭据 +
/// 用户手动重启)。这里的"取消"按钮回退到 WelcomeView 仅在 mode 未锁定的
/// 瞬态下成立(用户刚从 Welcome 进来还没保存)。
struct LocalSetupView: View {
    @EnvironmentObject private var model: AppModel
    /// 父 RootView 把 flow 状态传下来,这里 cancel/save 完通知它切回 welcome
    /// 或主界面。本组件不直接依赖路由 enum,以便将来从设置页复用。
    var onCancel: () -> Void = {}

    @State private var anthropicKey: String = ""
    @State private var openaiKey: String = ""
    @State private var geminiKey: String = ""
    @State private var saving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 520)
        .padding(.vertical, 4)
        .task {
            // 进来时把已存在的 BYOK 值回填 —— 用户从 WelcomeView 进 BYOK 后
            // 又退出来再回又点 BYOK 应当看到之前填了什么(虽然本次 scope 不
            // 走 BYOK→未配置 的路径,但这里写一次复用风险低)。
            let snapshot = BYOKConfig.load()
            anthropicKey = snapshot.anthropicKey ?? ""
            openaiKey = snapshot.openaiKey ?? ""
            geminiKey = snapshot.geminiKey ?? ""
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("API key（选填 · 默认用本机已登录的订阅，不需要填）")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                keyField(
                    label: "Anthropic",
                    hint: "sk-ant-...",
                    text: $anthropicKey,
                    description: "Claude 系列模型。控制台:console.anthropic.com"
                )
                keyField(
                    label: "OpenAI",
                    hint: "sk-...",
                    text: $openaiKey,
                    description: "GPT 系列模型。控制台:platform.openai.com"
                )
                keyField(
                    label: "Google Gemini",
                    hint: "AIza...",
                    text: $geminiKey,
                    description: "Gemini 系列模型。控制台:aistudio.google.com"
                )
                Text("以上 key 仅用于未来的 API-key 额度池路径（SDK / `-p`）；留空就用本机订阅。\n本次选定后 mode 锁定为本机模式;切回登录态需重启 app 并退出本机模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func keyField(
        label: String,
        hint: String,
        text: Binding<String>,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout.weight(.medium))
            SecureField(hint, text: text)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
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
        errorMessage = nil
        let config = BYOKConfig(
            anthropicKey: trimNil(anthropicKey),
            openaiKey: trimNil(openaiKey),
            geminiKey: trimNil(geminiKey)
        )
        // key 选填、best-effort 存；失败也不挡进入（本机模式不需要 key）。
        do { try model.saveByokConfig(config) }
        catch { print("[local-setup] save optional key failed: \(error)") }
        // 进入本机模式（与有没有 key 无关）—— RootView 监听 mode 切换自动跳主界面。
        model.enterLocalMode()
        saving = false
    }

    private func trimNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
#endif
