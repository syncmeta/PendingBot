#if os(iOS)
import SwiftUI

/// Full-screen call surface. Two visible metrics: elapsed time and the
/// per-call PND cost. Balance is deliberately absent — the user sees the
/// new balance on the Wallet/Me tab after they hang up. Keeping it off
/// the call UI removes a mental anchor that would distract mid-conversation.
///
/// State source is CallSession (@Observable). The view's lifecycle is:
///   - On `.task`, call session.start() — idempotent (guard against
///     non-idle phase), so re-appearing after a minimize round-trip
///     is a no-op rather than a re-mint.
///   - Tap on the hang up button → session.hangUp(); the .terminated
///     phase handler calls `callCenter.clearVoiceCall()` which collapses
///     the cover binding.
///   - Tap on the top-leading chevron-down → `callCenter.minimize()`.
///     Cover dismisses, session keeps running, floating pill on TabRoot
///     replaces this surface until the user taps it to re-expand.
///   - On terminate(.regionUnsupported) we show an alert + link; the
///     alert's button clears the slot.
struct CallView: View {
    @Bindable var session: CallSession
    @Environment(CallCenter.self) private var callCenter
    @Environment(\.openURL) private var openURL

    // Pulled out so the region-unsupported alert payload survives the
    // .terminated phase transition.
    @State private var regionAlert: RegionAlert?
    @State private var errorAlert: String?
    @State private var showingDiagnostics = false

    private struct RegionAlert: Identifiable {
        let id = UUID()
        let country: String?
        let supportedURL: URL?
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                avatar
                Text(session.botDisplayName)
                    .font(Theme.Fonts.title2).bold()
                Text(statusText)
                    .font(Theme.Fonts.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                metrics
                Spacer()
                controlRow
                    .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity)
            .padding()
            minimizeButton
                .padding(.top, 12)
                .padding(.leading, 12)
            VStack {
                HStack {
                    Spacer()
                    CallDiagnosticsButton(
                        snapshot: session.diagnostics,
                        isPresented: $showingDiagnostics,
                    )
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                }
                if showingDiagnostics {
                    HStack {
                        Spacer()
                        CallDiagnosticsPanel(snapshot: session.diagnostics)
                            .padding(.trailing, 12)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer()
            }
        }
        .task {
            updateProximityMonitoring()
            await session.start()
        }
        .onChange(of: session.phase) { _, new in
            handlePhaseChange(new)
            updateProximityMonitoring()
        }
        .onChange(of: session.isSpeakerOn) { _, _ in
            updateProximityMonitoring()
        }
        .onDisappear {
            // Proximity-driven screen blanking is only useful while the
            // full-screen UI is showing; when the user minimizes (and
            // is browsing other tabs) we don't want the screen blanking
            // as they tilt the phone. `.task` re-enables it on re-expand.
            UIDevice.current.isProximityMonitoringEnabled = false
        }
        .alert(item: $regionAlert) { alert in
            let support = alert.supportedURL
            return Alert(
                title: Text("无法接通"),
                message: Text(regionAlertBody(country: alert.country)),
                primaryButton: .default(Text("查看支持地区")) {
                    if let support { openURL(support) }
                    callCenter.clearVoiceCall()
                },
                secondaryButton: .cancel(Text("关闭")) {
                    callCenter.clearVoiceCall()
                },
            )
        }
        .alert(
            "通话异常",
            isPresented: Binding(
                get: { errorAlert != nil },
                set: { if !$0 { errorAlert = nil } },
            ),
            actions: {
                Button("好") { callCenter.clearVoiceCall() }
            },
            message: {
                Text(errorAlert ?? "")
            },
        )
    }

    // MARK: - Subviews

    private var avatar: some View {
        // Same emoji avatar the conversation header shows — emoji keyed
        // to the bot, tint keyed to the conversation — so the call screen
        // shows a recognisable "who you're talking to".
        BotAvatar(
            emojiSeed: session.botId,
            colorSeed: session.conversationId,
            size: 120,
        )
    }

    private var metrics: some View {
        // Server-side meter (RealtimeMeterDO) publishes per-turn spend
        // over the conv hub, so we have a running PND figure to show.
        // It stays hidden until the first turn settles — a "本次通话的费用：0 PND"
        // sitting below the timer for the first 1–2 s of "talking
        // but no usage yet" reads as broken.
        //
        // Elapsed display ticks via TimelineView so the same date
        // formatting can power the minimized floating pill without
        // sharing a Timer between two views. Pre-connect we show a
        // placeholder so the layout doesn't jump.
        VStack(spacing: 6) {
            if let start = session.connectedAt {
                TimelineView(.periodic(from: start, by: 1.0)) { ctx in
                    Text(Self.formatElapsed(ctx.date.timeIntervalSince(start)))
                        .font(Theme.Fonts.title3)
                        .monospacedDigit()
                }
            } else {
                Text("00:00")
                    .font(Theme.Fonts.title3)
                    .monospacedDigit()
                    .opacity(0)
            }
            if session.cumulativePncMicros > 0 {
                Text("本次通话的费用：\(WalletV2Format.formatPnc(session.cumulativePncMicros)) PNC")
                    .font(Theme.Fonts.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Top-leading collapse button — hides the full-screen surface but
    /// keeps the call running; the user navigates to other tabs and
    /// taps the floating pill to come back. Disabled before connect so
    /// a user can't strand themselves on a half-opened call with
    /// nowhere visible to hang up (the pill only shows after the cover
    /// dismisses, and the cover dismisses only on minimize).
    private var minimizeButton: some View {
        Button {
            Haptics.tap()
            callCenter.minimize()
        } label: {
            Image(systemName: "chevron.down")
                .font(Theme.Fonts.glyph(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(Color(.secondarySystemBackground)),
                )
        }
        .accessibilityLabel("收起")
    }

    private var controlRow: some View {
        HStack(spacing: 44) {
            speakerButton
            hangUpButton
        }
    }

    private var speakerButton: some View {
        Button {
            session.toggleSpeaker()
            Haptics.tap()
        } label: {
            Image(systemName: session.isSpeakerOn ? "speaker.wave.2.fill" : "speaker.fill")
                .font(Theme.Fonts.glyph(size: 24))
                .foregroundStyle(session.isSpeakerOn ? Color.white : Color.primary)
                .frame(width: 64, height: 64)
                .background(
                    Circle().fill(
                        session.isSpeakerOn
                            ? AnyShapeStyle(Theme.Palette.accent)
                            : AnyShapeStyle(Color(.secondarySystemBackground))
                    )
                )
        }
        .disabled(isCallInactive)
    }

    private var hangUpButton: some View {
        // Once tapped, the button dims to a lighter red and stops
        // responding while the disconnect tone plays — the call screen
        // stays up until the session reports `.terminated`, which clears
        // the slot via handlePhaseChange. Mirrors the system phone app's
        // ending-call button.
        Button {
            guard !isHangUpDisabled else { return }
            Task { await session.hangUp() }
        } label: {
            Image(systemName: "phone.down.fill")
                .font(Theme.Fonts.glyph(size: 28))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(
                    Circle().fill(
                        isHangUpDisabled ? Color.red.opacity(0.45) : Color.red,
                    ),
                )
        }
        .animation(.easeOut(duration: 0.2), value: isHangUpDisabled)
    }

    /// True once the call has left its live phases — the speaker toggle
    /// has nothing to act on.
    private var isCallInactive: Bool {
        switch session.phase {
        case .connecting, .connected: return false
        default: return true
        }
    }

    /// Drives the proximity sensor: blank the screen when the device is
    /// held to the ear, but only while the call is live and on the
    /// earpiece (speaker mode means the phone is away from the face).
    private func updateProximityMonitoring() {
        UIDevice.current.isProximityMonitoringEnabled =
            !isCallInactive && !session.isSpeakerOn
    }

    // MARK: - Phase reactions

    private var statusText: String {
        switch session.phase {
        case .idle, .connecting: return "正在呼叫…"
        case .connected:         return "通话中"
        case .hangingUp:         return "结束中…"
        case .terminated:        return "已结束"
        }
    }

    private var isHangUpDisabled: Bool {
        if case .hangingUp = session.phase { return true }
        if case .terminated = session.phase { return true }
        return false
    }

    private func handlePhaseChange(_ phase: CallSession.Phase) {
        switch phase {
        case .connected:
            Haptics.connected()
        case .terminated(let reason):
            // Alerts that need user acknowledgement: the alert button
            // calls `callCenter.clearVoiceCall()` so the cover stays up
            // until the user reads the message. Voluntary / bot-driven /
            // CallKit-driven ends drop straight away.
            switch reason {
            case .regionUnsupported(let country, let url):
                regionAlert = RegionAlert(country: country, supportedURL: url)
            case .startupError(let m), .remoteError(let m):
                errorAlert = m
            case .noBalance:
                errorAlert = "余额不足，通话结束"
            case .network:
                errorAlert = "网络中断，通话结束"
            case .user, .botEnded:
                callCenter.clearVoiceCall()
            }
        default:
            break
        }
    }

    private func regionAlertBody(country: String?) -> String {
        // Worker already sends a locale-aware message via t(); but if the
        // alert fires from a cached-route source we may not have it. Fall
        // back to a static line that still names OpenAI explicitly.
        if let country, !country.isEmpty {
            return "打电话要直连 OpenAI，你当前所在地区（\(country)）不在它支持的国家或地区。"
        }
        return "打电话要直连 OpenAI，检查你的网络是否处于它支持的国家或地区。"
    }
}
#endif
