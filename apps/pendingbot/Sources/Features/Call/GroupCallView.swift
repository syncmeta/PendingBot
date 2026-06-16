#if os(iOS)
import WebKit
import SwiftUI

/// Full-screen group voice call surface. The room is a Cloudflare
/// RealtimeKit meeting; this view embeds the user's WebRTC participant
/// and keeps the native controls, roster, diagnostics and billing chrome
/// around it.
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
    @Environment(CallCenter.self) private var callCenter
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
    @State private var showingDiagnostics = false

    var body: some View {
        callContent
            .task { await session.start() }
            .onChange(of: session.phase) { _, new in handlePhaseChange(new) }
            .onChange(of: session.actionError) { _, new in
                if let new { actionAlert = new; session.actionError = nil }
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
                actions: { Button("好") { callCenter.clearGroupCall() } },
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
                            // .terminated phase clears the slot via handlePhaseChange.
                        }
                    }
                },
                message: {
                    Text("通话中的所有人都会被断开。")
                },
            )
    }

    @ViewBuilder
    private var callContent: some View {
        ZStack(alignment: .topLeading) {
            Theme.Palette.canvas.ignoresSafeArea()
            if let room = session.realtimeKitRoom {
                RealtimeKitParticipantView(
                    token: room.human.token,
                    meetingId: room.meeting.id,
                    allowsInteraction: false,
                    onEvent: { event in
                        session.handleRealtimeKitParticipantEvent(event)
                    },
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                topBar
                    .padding(.top, 44)
                    .padding(.leading, 24)
                    .padding(.trailing, 76)
                if session.isReconnecting {
                    reconnectingBanner
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                ScrollView {
                    rosterSection
                        .padding(.horizontal, 32)
                        .padding(.top, 28)
                }
                Spacer(minLength: 0)
            }
            bottomControls
            minimizeButton
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 44)
                .padding(.trailing, 16)
            diagnosticsLayer
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            inviteRow
                .padding(.bottom, 18)
            toolbar
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .zIndex(4)
    }

    // MARK: - Top bar

    /// Title + status on the left across the top.
    private var topBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(session.groupTitle.isEmpty ? "群语音" : session.groupTitle)
                .font(Theme.Fonts.title3).bold()
                .lineLimit(1)
            inlineStatus
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var inlineStatus: some View {
        if session.phase == .connected, let start = session.connectedAt {
            HStack(spacing: 8) {
                TimelineView(.periodic(from: start, by: 1.0)) { ctx in
                    Text(Self.formatElapsed(ctx.date.timeIntervalSince(start)))
                        .font(Theme.Fonts.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if session.cumulativePncMicros > 0 {
                    Text("\(WalletV2Format.formatPnc(session.cumulativePncMicros)) PNC")
                        .font(Theme.Fonts.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(statusText)
                .font(Theme.Fonts.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Transient banner shown while the server's media container link is
    /// dropped and the RoomVoiceDO is re-dialing + replaying room state.
    /// Cleared by the next `.state` frame (resync ok) or by teardown
    /// (`.ended`, when the DO gave up after its bounded retries).
    private var reconnectingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("重连中…")
                .font(Theme.Fonts.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Palette.surface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.Palette.hairline, lineWidth: 0.5),
        )
        .accessibilityLabel("通话重连中")
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Top-leading collapse button — see `CallView.minimizeButton` for
    /// the rationale. Hides the full-screen surface but keeps the
    /// RealtimeKit participant alive.
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
                    Circle().fill(Theme.Palette.surface),
                )
                .overlay(
                    Circle()
                        .stroke(Theme.Palette.hairline, lineWidth: 0.5),
                )
        }
        .accessibilityLabel("收起")
    }

    private var diagnosticsLayer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            CallDiagnosticsButton(
                snapshot: session.diagnostics,
                isPresented: $showingDiagnostics,
            )
            .padding(.top, 44)
            .padding(.trailing, 68)
            if showingDiagnostics {
                CallDiagnosticsPanel(snapshot: session.diagnostics)
                    .padding(.trailing, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Two invite CTAs sitting just above the toolbar, centered as a
    /// balanced pair.
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
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(Theme.Fonts.subheadline)
                Text(title)
                    .font(Theme.Fonts.subheadline).fontWeight(.medium)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(Capsule().fill(Theme.Palette.surface))
            .overlay(
                Capsule().stroke(Theme.Palette.hairline, lineWidth: 0.5),
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
        .overlay(
            Circle()
                .stroke(isSpeaking(sender: sender) ? Color.green : Color.clear, lineWidth: 3)
                .frame(width: 64, height: 64)
        )

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

    private func isSpeaking(sender: GroupBubbleSender) -> Bool {
        session.diagnostics.participants.contains {
            $0.id == sender.id
                && $0.speaking
                && ($0.kind == (sender.kind == .bot ? .bot : .human)
                    || (sender.id == session.currentUserId && $0.kind == .local))
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
                    .font(Theme.Fonts.body)
                Text(statusText)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: cancelInviteAction) {
                Image(systemName: "xmark.circle.fill")
                    .font(Theme.Fonts.glyph(size: 22))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("取消邀请")
        }
    }

    private func sectionHeader(text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.footnote).fontWeight(.semibold)
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
                .font(Theme.Fonts.caption2)
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
                // .terminated phase clears the slot via handlePhaseChange.
            }
        } label: {
            Image(systemName: "phone.down.fill")
                .font(Theme.Fonts.glyph(size: 26))
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
                .font(Theme.Fonts.glyph(size: 22))
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
                .font(Theme.Fonts.glyph(size: 22, weight: .semibold))
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
                        .font(Theme.Fonts.footnote)
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
            Haptics.connected()
        case .terminated(let reason):
            switch reason {
            case .user, .ended:
                // Voluntary — drop the slot immediately so the full
                // screen collapses (or the pill disappears).
                callCenter.clearGroupCall()
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
}

enum RealtimeKitParticipantEvent: Sendable {
    case joined
    case localAudioEnabled
    case remoteAudioAttached(String)
    case failed(String)
}

struct RealtimeKitParticipantView: UIViewRepresentable {
    let token: String
    let meetingId: String
    var allowsInteraction: Bool = true
    var onEvent: (RealtimeKitParticipantEvent) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "rtkLog")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.isUserInteractionEnabled = allowsInteraction
        webView.loadHTMLString(html, baseURL: URL(string: "https://pendingbot.local"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
    }

    private var html: String {
        let encodedToken = Self.jsString(token)
        let encodedMeetingId = Self.jsString(meetingId)
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            body { margin: 0; padding: 20px; background: #0b1220; color: #f8fafc; }
            button { width: 100%; border: 0; border-radius: 12px; padding: 14px; font-size: 17px; font-weight: 650; }
            .card { border: 1px solid rgba(255,255,255,.18); border-radius: 12px; padding: 14px; margin-top: 14px; background: rgba(255,255,255,.08); }
            .muted { color: #94a3b8; font-size: 13px; overflow-wrap: anywhere; }
            #log { white-space: pre-wrap; font-family: ui-monospace, Menlo, monospace; font-size: 12px; }
          </style>
        </head>
        <body>
          <h2>群语音</h2>
          <div class="muted">meeting: <span id="meeting"></span></div>
          <div class="card">
            <button id="join">重新连接音频</button>
          </div>
          <div class="card">
            <div id="state">idle</div>
            <div id="log" class="muted"></div>
          </div>
          <script src="https://cdn.jsdelivr.net/npm/@cloudflare/realtimekit@1.4.0/dist/browser.js"></script>
          <script>
            const authToken = \(encodedToken);
            const meetingId = \(encodedMeetingId);
            const state = document.getElementById('state');
            const log = document.getElementById('log');
            let joining = false;
            let joined = false;
            let manualSubscriptionUnavailable = false;
            let manualSubscriptionNoticeLogged = false;
            let meeting = null;
            let localStream = null;
            const remoteAudio = new Map();
            const remoteTrackIds = new Map();
            const subscribedParticipants = new Set();
            document.getElementById('meeting').textContent = meetingId;
            function post(type, payload = {}) {
              try {
                window.webkit && window.webkit.messageHandlers.rtkLog.postMessage({
                  type,
                  ...payload
                });
              } catch (_) {}
            }
            function append(msg) {
              log.textContent += "\\n" + new Date().toISOString().slice(11, 19) + " " + msg;
              post('log', { message: String(msg) });
            }
            function participantArray(map) {
              if (!map) return [];
              if (typeof map.toArray === 'function') return map.toArray();
              if (typeof map.values === 'function') return Array.from(map.values());
              return Object.values(map);
            }
            function participantKey(participant) {
              return String(participant && (participant.id || participant.peerId || participant.userId) || '');
            }
            function attachRemoteAudio(participant, audioTrack) {
              const track = audioTrack || (participant && participant.audioTrack);
              if (!track) return;
              const key = participantKey(participant);
              if (!key) return;
              let audio = remoteAudio.get(key);
              if (audio && remoteTrackIds.get(key) === track.id) return;
              if (!audio) {
                audio = document.createElement('audio');
                audio.autoplay = true;
                audio.playsInline = true;
                audio.controls = false;
                audio.muted = false;
                audio.style.display = 'none';
                document.body.appendChild(audio);
                remoteAudio.set(key, audio);
              }
              audio.autoplay = true;
              audio.playsInline = true;
              audio.controls = false;
              audio.muted = false;
              audio.srcObject = new MediaStream([track]);
              remoteTrackIds.set(key, track.id);
              audio.play().then(() => {
                append('remote audio attached ' + key);
                post('remote-audio-attached', { participantId: key });
              }).catch((err) => {
                append('remote audio play failed ' + key + ' ' + err);
              });
            }
            function wireParticipant(participant) {
              if (!participant) return;
              if (participant.audioTrack) attachRemoteAudio(participant, participant.audioTrack);
              if (participant.audioEnabled && participant.audioTrack) {
                attachRemoteAudio(participant, participant.audioTrack);
              }
            }
            async function subscribeParticipant(participant) {
              if (!meeting || !participant) return;
              const key = participantKey(participant);
              if (!key) return;
              if (
                meeting.participants &&
                typeof meeting.participants.subscribe === 'function' &&
                !manualSubscriptionUnavailable &&
                !subscribedParticipants.has(key)
              ) {
                try {
                  subscribedParticipants.add(key);
                  await meeting.participants.subscribe([key], ['audio']);
                  append('subscribed audio ' + key);
                } catch (err) {
                  if (String(err).includes('ERR1206')) {
                    manualSubscriptionUnavailable = true;
                    if (!manualSubscriptionNoticeLogged) {
                      manualSubscriptionNoticeLogged = true;
                      append('manual subscription unavailable; using auto audio');
                    }
                  } else {
                    subscribedParticipants.delete(key);
                    append('subscribe failed ' + key + ' ' + err);
                  }
                }
              }
              wireParticipant(participant);
            }
            function wireAllParticipants() {
              for (const p of participantArray(meeting && meeting.participants && meeting.participants.joined)) {
                subscribeParticipant(p);
              }
              for (const p of participantArray(meeting && meeting.participants && meeting.participants.active)) {
                subscribeParticipant(p);
              }
            }
            function onAudioUpdate(participant, update) {
              const payload = update || {};
              const enabled = payload.audioEnabled !== undefined ? payload.audioEnabled : participant.audioEnabled;
              const track = payload.audioTrack || participant.audioTrack;
              if (enabled && track) attachRemoteAudio(participant, track);
            }
            async function enableLocalAudio() {
              if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
                append('getUserMedia unavailable; falling back to SDK audio');
                await meeting.self.enableAudio();
                return;
              }
              localStream = await navigator.mediaDevices.getUserMedia({
                audio: {
                  echoCancellation: true,
                  noiseSuppression: true,
                  autoGainControl: true
                },
                video: false
              });
              const track = localStream.getAudioTracks()[0];
              if (!track) throw new Error('no local microphone track');
              try {
                await meeting.self.enableAudio(track);
              } catch (err) {
                append('enableAudio(track) failed; trying SDK default ' + err);
                await meeting.self.enableAudio();
              }
              append('local audio enabled');
              post('local-audio-enabled');
            }
            async function join() {
              if (joining || joined) return;
              joining = true;
              try {
                state.textContent = 'initializing';
                if (!window.RealtimeKitClient) {
                  throw new Error('RealtimeKitClient global missing');
                }
                meeting = await RealtimeKitClient.init({
                  authToken,
                  defaults: { audio: false, video: false }
                });
                window.__rtkMeeting = meeting;
                state.textContent = 'joining';
                if (typeof meeting.join === 'function') {
                  await meeting.join();
                } else if (typeof meeting.joinRoom === 'function') {
                  await meeting.joinRoom();
                } else {
                  throw new Error('meeting has no join method');
                }
                await enableLocalAudio();
                if (meeting.participants && meeting.participants.joined) {
                  meeting.participants.joined.on('participantJoined', wireAllParticipants);
                  meeting.participants.joined.on('participantsUpdate', wireAllParticipants);
                  meeting.participants.joined.on('audioUpdate', onAudioUpdate);
                }
                if (meeting.participants && meeting.participants.active) {
                  meeting.participants.active.on('participantJoined', wireAllParticipants);
                  meeting.participants.active.on('participantsUpdate', wireAllParticipants);
                  meeting.participants.active.on('audioUpdate', onAudioUpdate);
                }
                wireAllParticipants();
                state.textContent = 'joined';
                joined = true;
                append('joined');
                post('joined');
              } catch (err) {
                state.textContent = 'failed';
                const message = String(err && err.stack ? err.stack : err);
                append(message);
                post('failed', { message });
              } finally {
                joining = false;
              }
            }
            document.getElementById('join').addEventListener('click', join);
            window.addEventListener('load', () => setTimeout(join, 100));
          </script>
        </body>
        </html>
        """
    }

    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        var onEvent: (RealtimeKitParticipantEvent) -> Void

        init(onEvent: @escaping (RealtimeKitParticipantEvent) -> Void) {
            self.onEvent = onEvent
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
        ) {
            if message.name == "rtkLog" {
                print("[rtk-webview]", message.body)
                guard let body = message.body as? [String: Any],
                      let type = body["type"] as? String
                else { return }
                Task { @MainActor [onEvent] in
                    switch type {
                    case "joined":
                        onEvent(.joined)
                    case "local-audio-enabled":
                        onEvent(.localAudioEnabled)
                    case "remote-audio-attached":
                        onEvent(.remoteAudioAttached(body["participantId"] as? String ?? ""))
                    case "failed":
                        onEvent(.failed(body["message"] as? String ?? ""))
                    default:
                        break
                    }
                }
            }
        }

        @available(iOS 15.0, *)
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void,
        ) {
            decisionHandler(.grant)
        }
    }
}
#endif
