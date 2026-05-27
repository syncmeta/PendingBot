import CoreImage.CIFilterBuiltins
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
                    HStack(alignment: .top, spacing: 16) {
                        PendingCrewQRCode(payload: challenge.qrPayload)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("验证码：\(challenge.code)")
                                .font(.headline)
                            Text("生成后会自动检查手机确认结果。扫码失败时可复制 payload。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(challenge.qrPayload)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(5)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .task(id: challenge.challengeId) {
                        await pollUntilApproved(challengeId: challenge.challengeId)
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

    private func pollUntilApproved(challengeId: String) async {
        for _ in 0..<120 {
            guard !Task.isCancelled else { return }
            guard model.deviceGrantToken == nil else { return }
            guard model.deviceLoginChallenge?.challengeId == challengeId else { return }

            await model.pollDeviceLogin()

            guard model.deviceGrantToken == nil else { return }
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
        }
    }
}

private struct PendingCrewQRCode: View {
    let payload: String

    var body: some View {
        if let image = makeQRCode(payload) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.quaternary)
                }
                .accessibilityLabel("PendingCrew 登录二维码")
        } else {
            ContentUnavailableView("二维码生成失败", systemImage: "qrcode")
                .frame(width: 204, height: 204)
        }
    }

    private func makeQRCode(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
