import SwiftUI

/// Full-screen group voice call surface. The room is born empty —
/// /voice/start no longer auto-pulls every bot and no longer rings any
/// human. The caller invites others by tapping "叫机器人来" / "叫真人来"
/// from this screen; everyone else stays silent until explicitly rung.
///
/// Layout (top → bottom):
///   * Header  — group title + status ("等其他人进" / "通话中" / elapsed)
///   * Invite  — two capsule CTAs that open sheets
///   * Roster  — joined humans + bots (avatar + name only), then a
///               "正在拉" section for pending invites
///   * Toolbar — 免提 / 离开 / 散会; the last is only present for
///               privileged callers and brings up a 2nd-tap confirm.
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
    @State private var showingRingHuman = false
    /// True while the "结束所有人的通话" confirmation alert is up.
    @State private var showingEndConfirm = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.top, 24)
                    .padding(.horizontal)
                inviteRow
                    .padding(.top, 16)
                    .padding(.horizontal)
                ScrollView {
                    rosterSection
                        .padding(.horizontal, 32)
                        .padding(.top, 28)
                }
                Spacer(minLength: 0)
                toolbar
                    .padding(.bottom, 28)
            }
        }
        .task { await session.start() }
        .onChange(of: session.phase) { _, new in handlePhaseChange(new) }
        .onChange(of: session.actionError) { _, new in
            if let new { actionAlert = new; session.actionError = nil }
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
        .sheet(isPresented: $showingAddBot) { addBotSheet }
        .sheet(isPresented: $showingRingHuman) { ringHumanSheet }
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
        .alert(
            "结束所有人的通话？",
            isPresented: $showingEndConfirm,
            actions: {
                Button("取消", role: .cancel) {}
                Button("结束", role: .destructive) {
                    Task {
                        await session.endCall()
                        dismiss()
                    }
                }
            },
            message: {
                Text("通话中的所有人都会被断开。")
            },
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text(session.groupTitle.isEmpty ? "群语音" : session.groupTitle)
                .font(.title2).bold()
                .multilineTextAlignment(.center)
                .lineLimit(2)
            // Single status slot: "接通中" while connecting, elapsed time
            // (+ optional PND) once connected. Same vertical position so
            // the layout doesn't jump on the connect transition.
            statusSlot
        }
    }

    @ViewBuilder
    private var statusSlot: some View {
        if session.phase == .connected {
            HStack(spacing: 10) {
                Text(elapsedDisplay)
                    .monospacedDigit()
                // PND figure stays hidden until the first turn settles —
                // a "0 PND" alongside the timer for the first 1–2 s reads
                // as broken.
                if session.cumulativePnd > 0 {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("\(session.cumulativePnd) PND")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.title3)
        } else {
            Text(statusText)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Invite CTAs

    private var inviteRow: some View {
        HStack(spacing: 14) {
            inviteButton(
                title: "叫机器人",
                systemImage: "sparkle",
                tint: Self.botInviteInk,
            ) {
                Haptics.tap()
                showingAddBot = true
            }
            inviteButton(
                title: "叫真人",
                systemImage: "person.wave.2.fill",
                tint: .primary,
            ) {
                Haptics.tap()
                showingRingHuman = true
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Deep navy used for the "叫机器人" pill — picked to read as
    /// distinctly "bot" against the brand green / human accent without
    /// borrowing one of the existing tag colours.
    private static let botInviteInk = Color(hex: 0x1E3A8A)

    private func inviteButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.body)
                Text(title)
                    .font(.body).fontWeight(.medium)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color(.systemBackground)))
            .overlay(
                Capsule().stroke(Color(.separator), lineWidth: 0.5),
            )
        }
        .disabled(!isCallLive)
    }

    // MARK: - Roster

    private var rosterSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Joined first — the caller themselves plus any peers/bots.
            // Avatars sit in an adaptive grid; the kind-coloured halo
            // around each avatar replaces the (now removed) text label.
            sectionHeader(text: "通话中")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 72), spacing: 22)],
                alignment: .leading,
                spacing: 22,
            ) {
                avatarTile(
                    sender: GroupBubbleSender(
                        kind: .user,
                        id: session.currentUserId,
                        displayName: "我",
                        avatarPath: nil,
                        avatarSeed: session.currentUserId,
                    ),
                    showMenu: false,
                )
                ForEach(session.humanParticipants, id: \.id) { p in
                    avatarTile(sender: p, showMenu: session.isPrivileged)
                }
                ForEach(session.botParticipants, id: \.id) { p in
                    avatarTile(sender: p, showMenu: session.isPrivileged)
                }
            }

            // Pending — invited but haven't joined yet.
            if !session.pendingParticipants.isEmpty {
                sectionHeader(text: "正在拉")
                VStack(spacing: 10) {
                    ForEach(
                        Array(session.pendingParticipants.enumerated()),
                        id: \.offset,
                    ) { _, item in
                        pendingRow(
                            sender: item.sender,
                            statusText: item.kind == .bot ? "机器人连接中…" : "等对方接听",
                            cancelInviteAction: {
                                Task { await session.cancelInvite(id: item.sender.id) }
                            },
                        )
                    }
                }
            }
        }
    }

    /// Single grid cell: the participant's avatar with a kind-coloured
    /// outer shadow (human → pale green / accentBg; bot → pale amber).
    /// Tapping a tile opens the privileged action menu when allowed; the
    /// caller's own tile is inert.
    private func avatarTile(
        sender: GroupBubbleSender,
        showMenu: Bool,
    ) -> some View {
        let haloColor: Color = sender.kind == .bot
            ? Theme.Palette.amberBg
            : Theme.Palette.accentBg
        let avatar = Group {
            if sender.kind == .bot {
                BotAvatar(
                    emojiSeed: sender.id,
                    colorSeed: session.conversationId,
                    size: 56,
                )
            } else {
                UserAvatar(
                    seed: sender.avatarSeed,
                    attachmentId: sender.avatarPath,
                    size: 56,
                )
            }
        }
        .shadow(color: haloColor, radius: 6, x: 0, y: 0)
        .shadow(color: haloColor.opacity(0.7), radius: 12, x: 0, y: 0)

        return Group {
            if showMenu, isCallLive {
                Menu {
                    Button("设为管理员") {
                        Task { await session.designateAdmin(id: sender.id) }
                    }
                    Button("移出通话", role: .destructive) {
                        Task { await session.kick(kind: sender.kind, id: sender.id) }
                    }
                } label: { avatar }
            } else {
                avatar
            }
        }
    }

    private func pendingRow(
        sender: GroupBubbleSender,
        statusText: String,
        cancelInviteAction: @escaping () -> Void,
    ) -> some View {
        HStack(spacing: 12) {
            if sender.kind == .bot {
                BotAvatar(
                    emojiSeed: sender.id,
                    colorSeed: session.conversationId,
                    size: 36,
                )
            } else {
                UserAvatar(
                    seed: sender.avatarSeed,
                    attachmentId: sender.avatarPath,
                    size: 36,
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(sender.displayName)
                    .font(.body)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: cancelInviteAction) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("取消邀请")
        }
    }

    private func sectionHeader(text: String) -> some View {
        Text(text)
            .font(.footnote).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 28) {
            labeledControl("免提") { speakerButton }
            labeledControl("离开") { hangUpButton }
            if session.isPrivileged {
                labeledControl("散会") { endAllButton }
            }
        }
    }

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
                .frame(width: 64, height: 64)
                .background(Circle().fill(.red))
        }
        .disabled(isHangUpDisabled)
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

    // MARK: - End all (toolbar, privileged + 2nd confirmation)

    private var endAllButton: some View {
        Button {
            Haptics.tap()
            showingEndConfirm = true
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(.orange))
        }
        .disabled(isHangUpDisabled)
        .accessibilityLabel("散会")
    }

    // MARK: - Sheets

    private var addBotSheet: some View {
        NavigationStack {
            List {
                if session.addableBots.isEmpty {
                    Text("没有可拉进来的机器人")
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
            .navigationTitle("叫机器人来")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingAddBot = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var ringHumanSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("被选中的人会收到一条来电提醒；没被选中的群成员不会响铃。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    if session.ringableHumans.isEmpty {
                        Text("群里没有可拉的真人")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(session.ringableHumans, id: \.id) { user in
                            Button {
                                showingRingHuman = false
                                Task { await session.ringHuman(id: user.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    UserAvatar(
                                        seed: user.avatarSeed,
                                        attachmentId: user.avatarPath,
                                        size: 36,
                                    )
                                    Text(user.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "phone.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("叫真人来")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingRingHuman = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Phase

    private var statusText: String {
        switch session.phase {
        case .idle, .connecting: return "接通中"
        case .connected:         return session.isAlone ? "等其他人进" : "通话中"
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
