import SwiftUI

/// 设置 — pushed from the 我 tab. Native settings list. Currently holds a
/// single knob: the voice-call connection mode. New app-wide settings go
/// here rather than scattered inline on the 我 page.
struct SettingsView: View {
    /// Voice-call transport preference, read by CallSession.start() — the
    /// key matches CallSession.transportDefaultsKey.
    /// "auto" | "webrtc" | "turn" | "websocket".
    @AppStorage("voice_transport") private var voiceTransport = "auto"

    var body: some View {
        Form {
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
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.Palette.accent)
    }
}
