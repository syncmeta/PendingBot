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
            Image(systemName: "key.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("配置 LLM provider key")
                .font(.title3.weight(.semibold))
            Text("BYOK 模式:provider 凭据存本机 keychain。至少填一个即可。")
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
                Text("说明:本次配置后 mode 锁定为 BYOK。\n切回登录态需要重启 app 并清掉 BYOK 配置(下次重启再选)。")
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
                    Text("完成")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit || saving)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - actions

    private var canSubmit: Bool {
        let any = [anthropicKey, openaiKey, geminiKey].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return any
    }

    private func save() {
        saving = true
        errorMessage = nil
        let config = BYOKConfig(
            anthropicKey: trimNil(anthropicKey),
            openaiKey: trimNil(openaiKey),
            geminiKey: trimNil(geminiKey)
        )
        do {
            try model.saveByokConfig(config)
            // 写完不需要手动 dismiss —— RootView 会因为 model.mode 切换
            // 自动跳到 MacThreePaneView。
        } catch {
            errorMessage = "保存到 Keychain 失败:\(error.localizedDescription)"
        }
        saving = false
    }

    private func trimNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
#endif
