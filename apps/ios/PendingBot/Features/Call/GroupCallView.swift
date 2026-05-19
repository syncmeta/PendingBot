import SwiftUI

/// Full-screen group voice call surface. Parallels `CallView` (1:1) but
/// shows the call's bot roster and — for a privileged caller (initiator
/// or group owner/admin) — per-bot remove controls, an add-bot picker,
/// and an "end call" action.
struct GroupCallView: View {
    @Bindable var session: GroupCallSession
    @Environment(\.dismiss) private var dismiss

    @State private var elapsedDisplay = "00:00"
    @State private var tickTimer: Timer?
    /// Non-fatal action feedback (e.g. a kick the worker rejected). The
    /// alert just dismisses itself — the call stays live.
    @State private var actionAlert: String?
    /// Terminal error — the call is over; the alert's button dismisses
    /// the whole call screen.
    @State private var fatalAlert: String?
    @State private var showingAddBot = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                header
                Spacer(minLength: 0)
                rosterView
                Spacer(minLength: 0)
                metrics
                controlRow
                    .padding(.bottom, 32)
            }
            .padding()
        }
        .task {
            await session.start()
        }
        .onChange(of: session.phase) { _, new in
            handlePhaseChange(new)
        }
        .onChange(of: session.actionError) { _, new in
            if let new { actionAlert = new; session.actionError = nil }
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
        .sheet(isPresented: $showingAddBot) {
            addBotSheet
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { actionAlert != nil },
                set: { if !$0 { actionAlert = nil } },
            ),
            actions: { Button("好") {} },
            message: { Text(actionAlert ?? "") },
        )
        .alert(
            "通话结束",
            isPresented: Binding(
                get: { fatalAlert != nil },
                set: { if !$0 { fatalAlert = nil } },
            ),
            actions: { Button("好") { dismiss() } },
            message: { Text(fatalAlert ?? "") },
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("群语音")
                .font(.title2).bold()
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    // MARK: - Roster

    private var rosterView: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(session.botParticipants, id: \.id) { bot in
                    participantRow(bot)
                }
                if session.botParticipants.isEmpty {
                    Text("正在召集机器人…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private func participantRow(_ bot: GroupBubbleSender) -> some View {
        HStack(spacing: 12) {
            BotAvatar(
                emojiSeed: bot.id,
                colorSeed: session.conversationId,
                size: 44,
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.displayName)
                    .font(.body).fontWeight(.medium)
                Text("机器人")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.isPrivileged, isCallLive {
                Menu {
                    Button("设为管理员") {
                        Task { await session.designateAdmin(id: bot.id) }
                    }
                    Button("移出通话", role: .destructive) {
                        Task { await session.kick(kind: .bot, id: bot.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground)),
        )
    }

    // MARK: - Metrics

    private var metrics: some View {
        Text("通话 \(elapsedDisplay)")
            .monospacedDigit()
            .font(.title3)
    }

    // MARK: - Controls

    private var controlRow: some View {
        HStack(alignment: .top, spacing: 22) {
            labeledControl("扬声器") { speakerButton }
            if session.isPrivileged {
                labeledControl("加机器人") { addBotButton }
            }
            labeledControl("离开") { hangUpButton }
            if session.isPrivileged {
                labeledControl("结束通话") { endCallButton }
            }
        }
    }

    /// A control button with a caption underneath — the red "leave" and
    /// orange "end call" buttons are otherwise easy to confuse.
    @ViewBuilder
    private func labeledControl<C: View>(
        _ label: String,
        @ViewBuilder _ content: () -> C,
    ) -> some View {
        VStack(spacing: 6) {
            content()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var speakerButton: some View {
        circleButton(
            systemImage: session.isSpeakerOn ? "speaker.wave.2.fill" : "speaker.fill",
            active: session.isSpeakerOn,
        ) {
            session.toggleSpeaker()
            Haptics.tap()
        }
        .disabled(!isCallLive)
    }

    private var addBotButton: some View {
        circleButton(systemImage: "person.badge.plus", active: false) {
            Haptics.tap()
            showingAddBot = true
        }
        .disabled(!isCallLive)
    }

    private var hangUpButton: some View {
        Button {
            Task {
                await session.hangUp()
                dismiss()
            }
        } label: {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(Circle().fill(.red))
        }
        .disabled(isHangUpDisabled)
    }

    private var endCallButton: some View {
        Button {
            Task {
                await session.endCall()
                dismiss()
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(.orange))
        }
        .disabled(isHangUpDisabled)
        .accessibilityLabel("结束通话")
    }

    private func circleButton(
        systemImage: String,
        active: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(active ? Color.white : Color.primary)
                .frame(width: 56, height: 56)
                .background(
                    Circle().fill(
                        active
                            ? AnyShapeStyle(Theme.Palette.accent)
                            : AnyShapeStyle(Color(.secondarySystemBackground)),
                    ),
                )
        }
    }

    // MARK: - Add-bot sheet

    private var addBotSheet: some View {
        NavigationStack {
            List {
                if session.addableBots.isEmpty {
                    Text("群里的机器人都已在通话中")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.addableBots, id: \.id) { bot in
                        Button {
                            showingAddBot = false
                            Task { await session.addBot(id: bot.id) }
                        } label: {
                            HStack(spacing: 12) {
                                BotAvatar(
                                    emojiSeed: bot.id,
                                    colorSeed: session.conversationId,
                                    size: 36,
                                )
                                Text(bot.displayName)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加机器人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingAddBot = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Phase

    private var statusText: String {
        switch session.phase {
        case .idle, .connecting: return "正在接通…"
        case .connected:         return "通话中"
        case .hangingUp:         return "结束中…"
        case .terminated:        return "已结束"
        }
    }

    private var isCallLive: Bool {
        switch session.phase {
        case .connecting, .connected: return true
        default: return false
        }
    }

    private var isHangUpDisabled: Bool {
        switch session.phase {
        case .hangingUp, .terminated: return true
        default: return false
        }
    }

    private func handlePhaseChange(_ phase: GroupCallSession.Phase) {
        switch phase {
        case .connected:
            startElapsedTicker()
        case .terminated(let reason):
            tickTimer?.invalidate()
            tickTimer = nil
            switch reason {
            case .user, .ended:
                // Voluntary — the tapped button already calls dismiss.
                break
            case .startupError(let m), .remoteError(let m):
                fatalAlert = m.isEmpty ? "通话失败" : m
            case .noBalance:
                fatalAlert = "余额不足，通话结束"
            case .network:
                fatalAlert = "网络中断，通话结束"
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
            elapsedDisplay = String(format: "%02d:%02d", total / 60, total % 60)
        }
    }
}
