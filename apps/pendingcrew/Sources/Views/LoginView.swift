import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 未登录态首屏。
///
/// 流程（spec v2 §4.4）：
/// 1. 用户点 "扫码登录到 PendingBot 账号" → 调
///    `POST /v1/device-login/challenges`（不传 subjectId，让 PendingBot
///    端选 subject）
/// 2. 渲染 QR + 验证码；同时启动 polling task 每 2s 调
///    `GET /v1/device-login/challenges/:id`
/// 3. PendingBot 用户扫码 + 在手机端选 subject + 批准 → poll 拿到
///    `deviceGrantToken` → `model.saveDeviceGrantToken(token)`
/// 4. AppModel 切换到 isAuthenticated，RootView 自动切回三栏 placeholder
///
/// scaffold 阶段不暴露 "选 subject" UI — 这一步在 PendingBot 手机端做
/// （iOS subject picker，T1.3 P2）。
struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var challenge: DeviceLoginChallenge?
    @State private var status: Status = .idle
    @State private var pollTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var familySSOBusy = false

    enum Status: Equatable {
        case idle
        case requesting
        case waitingForApproval
        case approved
        case error
    }

    var body: some View {
        VStack(spacing: 24) {
            header
            switch status {
            case .idle:
                idleSection
            case .requesting:
                ProgressView("正在生成登录二维码…")
                    .controlSize(.regular)
            case .waitingForApproval:
                challengeSection
            case .approved:
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("登录成功，正在进入…")
                        .foregroundStyle(.secondary)
                }
            case .error:
                errorSection
            }
            Spacer()
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("PendingCrew")
                .font(.largeTitle.weight(.semibold))
            Text("从 PendingBot 扫码授权这台设备")
                .foregroundStyle(.secondary)
        }
    }

    private var idleSection: some View {
        VStack(spacing: 12) {
            if model.familySSOAvailable {
                Button {
                    Task {
                        familySSOBusy = true
                        let ok = await model.tryFamilySSO()
                        familySSOBusy = false
                        if ok {
                            status = .approved
                        } else {
                            errorMessage = "本机 PendingBot 登录凭据可能已失效，请改用扫码登录。"
                            status = .error
                        }
                    }
                } label: {
                    Label("用本机 PendingBot 账号登录", systemImage: "person.crop.circle.badge.checkmark")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(familySSOBusy)

                Text("或")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                start()
            } label: {
                Label("扫码登录到 PendingBot 账号", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Text("默认以本人 user_account 身份登录；在 PendingBot 端可以\n切换到自己有 owner / admin 权限的群账号。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var challengeSection: some View {
        guard let challenge else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(spacing: 16) {
                if let image = qrImage(payload: challenge.qrPayload) {
                    image
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(8)
                        .background(.white)
                        .cornerRadius(8)
                } else {
                    Text("无法生成二维码")
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    Text("或在 PendingBot 输入验证码")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(challenge.code)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .tracking(2)
                }
                ProgressView()
                    .controlSize(.small)
                Text("等待 PendingBot 端批准（4 分钟内有效）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("取消", role: .cancel) { cancel() }
                    .buttonStyle(.borderless)
            }
        )
    }

    private var errorSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(errorMessage ?? "登录失败")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("重试") { start() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Flow

    private func start() {
        errorMessage = nil
        status = .requesting
        pollTask?.cancel()
        Task {
            do {
                let api = makeAPI()
                let created = try await api.createDeviceLoginChallenge(subjectId: nil)
                challenge = created
                status = .waitingForApproval
                startPolling(challenge: created, api: api)
            } catch {
                errorMessage = error.localizedDescription
                status = .error
            }
        }
    }

    private func startPolling(challenge: DeviceLoginChallenge, api: PendingCrewAPI) {
        // 4 分钟超时上限 (challenge.expiresAt 在 server 端是 10 分钟,
        // 但 spec 要求 client 侧 4 分钟超时, 提前提示用户)。
        let deadline = Date().addingTimeInterval(4 * 60)
        pollTask = Task {
            while !Task.isCancelled {
                if Date() > deadline {
                    await MainActor.run {
                        errorMessage = "等待批准超时,请重新发起。"
                        status = .error
                    }
                    return
                }
                do {
                    let response = try await api.pollDeviceLoginChallenge(
                        challengeId: challenge.challengeId,
                        secret: challenge.secret
                    )
                    if response.status == "approved",
                       let token = response.deviceGrantToken {
                        await MainActor.run {
                            do {
                                try model.saveDeviceGrantToken(token)
                                // 家族凭据（pfa_*）只在 consume 这一拍随 grant
                                // 下发 —— 落进共享 keychain 组，家族 app 之后
                                // 静默 mint 免扫码（登录 SSO C1）。subjectId
                                // 缺失就不存（凭据没有默认 mint 目标没意义）。
                                if let fam = response.familyCredential,
                                   let sid = response.subjectId {
                                    model.saveFamilyCredential(token: fam, subjectId: sid)
                                }
                                status = .approved
                            } catch {
                                errorMessage = "保存登录凭据失败: \(error.localizedDescription)"
                                status = .error
                            }
                        }
                        return
                    }
                    if response.status == "rejected" {
                        await MainActor.run {
                            errorMessage = "登录请求被拒绝。"
                            status = .error
                        }
                        return
                    }
                    if response.status == "expired" {
                        await MainActor.run {
                            errorMessage = "二维码已过期,请重新发起。"
                            status = .error
                        }
                        return
                    }
                } catch let PendingCrewAPIError.http(httpStatus, code, message) {
                    // 410 session_expired / 409 conflict — 终态
                    if httpStatus == 410 || code == "session_expired" {
                        await MainActor.run {
                            errorMessage = message ?? "二维码已过期,请重新发起。"
                            status = .error
                        }
                        return
                    }
                    // 其它瞬时错误就继续重试,不打扰用户
                } catch {
                    // 网络抖动 — 继续 poll
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func cancel() {
        pollTask?.cancel()
        pollTask = nil
        challenge = nil
        status = .idle
        errorMessage = nil
    }

    private func makeAPI() -> PendingCrewAPI {
        let url = URL(string: model.apiBaseURL) ?? URL(string: "https://api.pendingname.com")!
        return PendingCrewAPI(baseURL: url)
    }

    // MARK: - QR rendering

    private func qrImage(payload: String) -> Image? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if canImport(AppKit)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
        return Image(nsImage: nsImage)
        #elseif canImport(UIKit)
        let uiImage = UIImage(cgImage: cgImage)
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }
}
