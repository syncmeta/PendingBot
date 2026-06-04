#if os(macOS)
import SwiftUI
import OSLog

private let log = Logger.category("settings")

/// Lock-screen notification body preview mode. Mirror of the iOS
/// `NotificationPreviewMode` in `Sources/Features/Me/SettingsView.swift` —
/// raw string matches the server-side `notification_preview_mode` union and
/// is synced via PATCH /v1/me/profile so the edge push fan-out renders the
/// alert per-user.
private enum NotificationPreviewMode: String, CaseIterable, Identifiable {
    case generic        // 固定显示 "新消息"
    case name           // 只显示发送者名字
    case nameContent = "name_content" // 名字：内容预览

    var id: String { rawValue }

    var label: String {
        switch self {
        case .generic:     return "新消息"
        case .name:        return "发送者名字"
        case .nameContent: return "名字：内容预览"
        }
    }
}

/// 设置 (Mac) — native re-draw of iOS `SettingsView`. Same cross-platform
/// data channels: `@AppStorage` for the local-mirror keys and `APIClient`
/// for the server PATCH/GET. Presented as a `.sheet` from `MacMeView`
/// (the 我 page lives in the `NavigationSplitView` detail, where a
/// `NavigationLink` push is unreliable — a sheet is the stable choice).
struct MacSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// Voice-call transport preference, read by CallSession.start() — key
    /// matches CallSession.transportDefaultsKey.
    /// "auto" | "webrtc" | "turn" | "websocket".
    @AppStorage("voice_transport") private var voiceTransport = "auto"

    /// Local mirror of the server-side notification_preview_mode. Picker
    /// edits this; .onChange syncs the new value to /v1/me/profile.
    @AppStorage("notification_preview_mode") private var previewModeRaw = NotificationPreviewMode.generic.rawValue

    private var previewMode: NotificationPreviewMode {
        NotificationPreviewMode(rawValue: previewModeRaw) ?? .generic
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section {
                    Picker("锁屏通知预览", selection: Binding(
                        get: { previewMode },
                        set: { previewModeRaw = $0.rawValue }
                    )) {
                        ForEach(NotificationPreviewMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Text("锁屏推送显示内容：「新消息」最隐私；「发送者名字」便于识别来源；「名字：内容预览」最方便但会泄露消息文本。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("通知")
                }

                Section {
                    Picker("通话连接模式", selection: $voiceTransport) {
                        Text("自动").tag("auto")
                        Text("WebRTC").tag("webrtc")
                        Text("WebRTC（TURN中转）").tag("turn")
                        Text("WebSocket").tag("websocket")
                    }
                    Text("「自动」依次尝试 WebRTC、WebRTC（TURN中转）、WebSocket。WebRTC 直连延迟最低，但受 OpenAI 地区限制；TURN 中转经 Cloudflare 转发，不受地区限制；WebSocket 全程经服务器中转，兜底用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("语音通话")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Theme.Palette.canvas)
        .tint(Theme.Palette.accent)
        .task {
            // Pull authoritative value on appear in case it changed on
            // another device. Cheap — single GET.
            await refreshPreviewModeFromServer()
        }
        .onChange(of: previewModeRaw) { _, newValue in
            Task { await syncPreviewModeToServer(rawValue: newValue) }
        }
    }

    private var header: some View {
        HStack {
            Text("设置")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Spacer()
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func refreshPreviewModeFromServer() async {
        do {
            struct ProfileResponse: Decodable {
                let notification_preview_mode: String
            }
            let resp: ProfileResponse = try await APIClient().get("v1/me/profile")
            if resp.notification_preview_mode != previewModeRaw {
                previewModeRaw = resp.notification_preview_mode
            }
        } catch {
            log.warning("profile fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func syncPreviewModeToServer(rawValue: String) async {
        struct ProfilePatch: Encodable {
            let notification_preview_mode: String
        }
        do {
            try await APIClient().patchVoid("v1/me/profile", body: ProfilePatch(notification_preview_mode: rawValue))
        } catch {
            log.warning("profile patch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
