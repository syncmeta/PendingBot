import SwiftUI

/// Full-screen call surface. Two visible metrics: elapsed time and the
/// per-call PND cost. Balance is deliberately absent — the user sees the
/// new balance on the Wallet/Me tab after they hang up. Keeping it off
/// the call UI removes a mental anchor that would distract mid-conversation.
///
/// State source is CallSession (@Observable). The view's lifecycle is:
///   - On `.task`, call session.start() — that mints the worker session
///     and brings up the transport.
///   - Tap on the hang up button → session.hangUp(), then dismiss.
///   - On terminate(.regionUnsupported) we show an alert + link rather
///     than the in-call UI.
struct CallView: View {
    @Bindable var session: CallSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var elapsedDisplay: String = "00:00"
    @State private var tickTimer: Timer?

    // Pulled out so the region-unsupported alert payload survives the
    // .terminated phase transition.
    @State private var regionAlert: RegionAlert?
    @State private var errorAlert: String?

    private struct RegionAlert: Identifiable {
        let id = UUID()
        let country: String?
        let supportedURL: URL?
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                avatar
                Text(session.botDisplayName)
                    .font(.title2).bold()
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                metrics
                Spacer()
                hangUpButton
                    .padding(.bottom, 40)
            }
            .padding()
        }
        .task { await session.start() }
        .onChange(of: session.phase) { _, new in
            handlePhaseChange(new)
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
        .alert(item: $regionAlert) { alert in
            let support = alert.supportedURL
            return Alert(
                title: Text("无法接通"),
                message: Text(regionAlertBody(country: alert.country)),
                primaryButton: .default(Text("查看支持地区")) {
                    if let support { openURL(support) }
                },
                secondaryButton: .cancel(Text("关闭")) { dismiss() },
            )
        }
        .alert(
            "通话异常",
            isPresented: Binding(
                get: { errorAlert != nil },
                set: { if !$0 { errorAlert = nil } },
            ),
            actions: {
                Button("好") { dismiss() }
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
        // Running cost is no longer shown live — metering moved
        // server-side (RealtimeMeterDO), so the device doesn't see
        // per-turn spend. The call's cost settles into audit_log.
        Text("通话 \(elapsedDisplay)")
            .monospacedDigit()
            .font(.title3)
    }

    private var hangUpButton: some View {
        Button {
            Task {
                await session.hangUp()
                dismiss()
            }
        } label: {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(Circle().fill(.red))
        }
        .disabled(isHangUpDisabled)
    }

    // MARK: - Phase reactions

    private var statusText: String {
        switch session.phase {
        case .idle, .connecting: return "正在接通…"
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
            startElapsedTicker()
        case .terminated(let reason):
            tickTimer?.invalidate()
            tickTimer = nil
            switch reason {
            case .regionUnsupported(let country, let url):
                regionAlert = RegionAlert(country: country, supportedURL: url)
            case .startupError(let m), .remoteError(let m):
                errorAlert = m
            case .noBalance:
                errorAlert = "余额不足，通话结束"
            case .network:
                errorAlert = "网络中断，通话结束"
            case .user:
                // Voluntary hang up — view's hangUpButton already calls dismiss.
                break
            }
        default:
            break
        }
    }

    private func startElapsedTicker() {
        tickTimer?.invalidate()
        elapsedDisplay = "00:00"
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard let start = session.connectedAt else { return }
            let total = Int(Date().timeIntervalSince(start))
            let mm = total / 60
            let ss = total % 60
            elapsedDisplay = String(format: "%02d:%02d", mm, ss)
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
