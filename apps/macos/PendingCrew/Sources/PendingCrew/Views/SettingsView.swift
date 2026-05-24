import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("连接") {
                TextField("API URL", text: $model.apiBaseURL)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("保存") {
                    model.saveSettings()
                    Task { await model.refreshAll() }
                }
                .keyboardShortcut(.defaultAction)

                Button("退出登录") {
                    model.clearDeviceGrant()
                }
            }

            Section("扫码登录") {
                Button("生成 PendingCrew 登录二维码") {
                    Task { await model.startDeviceLogin() }
                }

                if let challenge = model.deviceLoginChallenge {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("验证码：\(challenge.code)")
                            .font(.headline)
                        Text(challenge.qrPayload)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    Button("检查手机确认结果") {
                        Task { await model.pollDeviceLogin() }
                    }
                }

                if let token = model.deviceGrantToken {
                    Text("已保存设备 grant：\(token.prefix(12))…")
                        .foregroundStyle(.secondary)
                }
            }

#if DEBUG
            Section("调试") {
                SecureField("调试用户 JWT", text: $model.debugUserJWT)
                    .textFieldStyle(.roundedBorder)

                Button("清空调试 JWT") {
                    model.clearDebugUserJWT()
                }
            }
#endif
        }
        .padding(20)
    }
}
