import SwiftUI
import OSLog

private let log = Logger.category("settings")

/// Lock-screen notification body preview mode. Mirrored to the worker via
/// /v1/me/profile so the edge push fan-out can render the alert per-user.
/// Raw string matches the server-side `notification_preview_mode` union.
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

/// 设置 — pushed from the 我 tab. Native settings list. New app-wide
/// settings go here rather than scattered inline on the 我 page.
struct SettingsView: View {
    /// Voice-call transport preference, read by CallSession.start() — the
    /// key matches CallSession.transportDefaultsKey.
    /// "auto" | "webrtc" | "turn" | "websocket".
    @AppStorage("voice_transport") private var voiceTransport = "auto"

    /// Local mirror of the server-side notification_preview_mode. Picker
    /// edits this; .onChange syncs the new value to /v1/me/profile so the
    /// edge push fan-out picks it up.
    @AppStorage("notification_preview_mode") private var previewModeRaw = NotificationPreviewMode.generic.rawValue

    /// App-wide appearance override (跟随系统/浅/深). Device-local, not synced.
    /// Both `@main` scenes read the same key and drive `.preferredColorScheme`.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.default.rawValue

    private var previewMode: NotificationPreviewMode {
        NotificationPreviewMode(rawValue: previewModeRaw) ?? .generic
    }

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .default
    }

    var body: some View {
        Form {
            Section {
                Picker("外观", selection: Binding(
                    get: { appearance },
                    set: { appearanceRaw = $0.rawValue }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("外观")
            } footer: {
                Text("「跟随系统」随设备的浅色/深色自动切换；也可固定为浅色或深色。")
            }

            Section {
                Picker("锁屏通知预览", selection: Binding(
                    get: { previewMode },
                    set: { previewModeRaw = $0.rawValue }
                )) {
                    ForEach(NotificationPreviewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } header: {
                Text("通知")
            } footer: {
                Text("锁屏推送显示内容：「新消息」最隐私；「发送者名字」便于识别来源；「名字：内容预览」最方便但会泄露消息文本。")
            }

            Section {
                Picker("通话连接模式", selection: $voiceTransport) {
                    Text("自动").tag("auto")
                    Text("WebRTC").tag("webrtc")
                    Text("WebRTC（TURN中转）").tag("turn")
                    Text("WebSocket").tag("websocket")
                }
            } header: {
                Text("语音通话")
            } footer: {
                Text("「自动」依次尝试 WebRTC、WebRTC（TURN中转）、WebSocket。WebRTC 直连延迟最低，但受 OpenAI 地区限制；TURN 中转经 Cloudflare 转发，不受地区限制；WebSocket 全程经服务器中转，兜底用。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("设置")
        .inlineNavTitle()
        .tint(Theme.Palette.accent)
        .task {
            // Pull authoritative value on view appear in case the user
            // changed it on another device. Cheap — single GET.
            await refreshPreviewModeFromServer()
        }
        .onChange(of: previewModeRaw) { _, newValue in
            Task { await syncPreviewModeToServer(rawValue: newValue) }
        }
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
            // Non-fatal — keep showing the local value. Picker still
            // works; next change will retry the write.
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
            // Write failed (auth, network). Keep the local state — next
            // toggle will re-attempt. Don't roll back the picker, since a
            // future retry will reconcile.
            log.warning("profile patch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
