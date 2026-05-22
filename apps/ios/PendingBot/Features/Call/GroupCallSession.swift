import Foundation
import AVFoundation
import Supabase

/// State container for a group voice call. `GroupCallView` owns one and
/// binds its UI to the @Observable state. Parallels `CallSession` (1:1)
/// but the transport is `GroupCallTransport` (SFU WebRTC) and the bots
/// live server-side in a RoomVoiceDO — so there is no closing recap and
/// no transport chain, just one SFU peer connection.
@MainActor
@Observable
final class GroupCallSession {

    // MARK: - State

    enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case hangingUp
        case terminated(TerminateReason)
    }

    enum TerminateReason: Equatable, Sendable {
        case user              // the caller left
        case ended             // the whole call ended
        case noBalance         // billing gate
        case network           // transport-level failure
        case remoteError(String)
        case startupError(String)
    }

    var phase: Phase = .idle

    /// Wall-clock moment the call connected — `GroupCallView`'s timer
    /// formats elapsed time from it. nil while connecting.
    var connectedAt: Date?

    var isSpeakerOn: Bool = false

    /// Running PND spend across all bot legs in the room, fed by the
    /// `voice_cost` frames RoomVoiceDO publishes on the conv hub after
    /// every settleTurn. 0 until the first turn — view hides the figure
    /// until then so an empty "0 PND" doesn't sit on the screen.
    var cumulativePnd: Int = 0

    /// Current bot roster, as the transport learns it from /join and
    /// any later re-sync. Drives the participant list.
    var roster: [GroupBotRosterEntry] = []

    /// Other humans currently in the call (peers). The caller themselves
    /// is reflected separately through `phase == .connected` — they don't
    /// appear in this list.
    var humanRoster: [GroupHumanRosterEntry] = []

    /// Participants invited into the call but who haven't joined yet —
    /// humans whose phones are ringing, or bots in the middle of coming
    /// up. Rendered below the joined list in the call UI.
    var pendingInvites: [GroupPendingEntry] = []

    /// True when the caller may kick / end / designate — they opened the
    /// call, or they are a group owner/admin.
    var isPrivileged: Bool = false

    /// Transient banner text for a failed privileged action (e.g. a kick
    /// the worker rejected with 403). The view clears it.
    var actionError: String?

    /// Live WebRTC + media-container diagnostics for the call screen.
    var diagnostics = CallDiagnosticsSnapshot()

    // MARK: - Inputs

    let conversationId: String
    let currentUserId: String
    /// Group conversation's display title — shown as the call screen
    /// header. Empty string falls back to a generic "群语音" in the view.
    let groupTitle: String
    /// Group members keyed "bot:<id>" / "user:<id>" — name + avatar
    /// lookup for the participant list. Sourced from the conversation's
    /// `groupSenders` map.
    let members: [String: GroupBubbleSender]

    // MARK: - Dependencies

    private let api: VoiceCallAPI
    private var transport: GroupCallTransport?
    private var didInitiate = false
    private var groupRoleIsAdmin = false
    private var latestTransportDiagnostics = CallDiagnosticsSnapshot()
    private var latestMediaDiagnostics: GroupMediaDiagnostics?

    /// CallKit handle for this call. Two ways it gets populated:
    ///   • Incoming (PushKit-driven): start() claims the UUID that
    ///     CallKitManager surfaced when the VoIP push landed; CallKit
    ///     already has an active call from CXAnswerCallAction.
    ///   • Outgoing (manual join from the in-conv banner): start() asks
    ///     CallKitManager to mint a fresh outgoing CallKit call.
    /// nil only if CallKit declined the request (e.g. user on a real
    /// PSTN call); the in-app UI still works without the system surface.
    private var callKitUUID: UUID?

    /// Conv-hub subscription feeding `cumulativePnd` from server-side
    /// per-turn voice_cost events. Dropped on terminate.
    private var costSubscription: ConvSubscriptionToken?

    /// Keepalive task that posts /voice/heartbeat on a fixed cadence so
    /// the DO knows we're still in the room. Without it, an iOS process
    /// kill / network drop / forgotten /voice/leave would leave a ghost
    /// call running on the worker. Cancelled on terminate.
    private var heartbeatTask: Task<Void, Never>?

    /// Cadence for the heartbeat above. DO times out at 30 s, so 10 s
    /// gives us two retries' worth of headroom.
    private static let heartbeatIntervalNanos: UInt64 = 10_000_000_000

    /// Total time to wait for the call to connect before giving up.
    private static let connectTimeoutNanos: UInt64 = 20_000_000_000

    init(
        conversationId: String,
        currentUserId: String,
        groupTitle: String,
        members: [String: GroupBubbleSender],
        api: VoiceCallAPI,
    ) {
        self.conversationId = conversationId
        self.currentUserId = currentUserId
        self.groupTitle = groupTitle
        self.members = members
        self.api = api
    }

    // MARK: - Derived

    /// Bots in the call, resolved to their display identity. A bot the
    /// group-senders map doesn't know (rare) falls back to an id-prefix.
    var botParticipants: [GroupBubbleSender] {
        roster.map { entry in
            members["bot:\(entry.botId)"]
                ?? GroupBubbleSender(
                    kind: .bot,
                    id: entry.botId,
                    displayName: "机器人 " + String(entry.botId.prefix(6)),
                    avatarPath: nil,
                    avatarSeed: entry.botId,
                )
        }
    }

    /// Other humans in the call (excluding the caller themselves).
    var humanParticipants: [GroupBubbleSender] {
        humanRoster.compactMap { entry in
            entry.humanId == currentUserId
                ? nil
                : (members["user:\(entry.humanId)"]
                    ?? GroupBubbleSender(
                        kind: .user,
                        id: entry.humanId,
                        displayName: String(entry.humanId.prefix(6)),
                        avatarPath: nil,
                        avatarSeed: entry.humanId,
                    ))
        }
    }

    /// Pending invites resolved to display identities + their kind, for
    /// the "ringing" section under the joined list.
    var pendingParticipants: [(sender: GroupBubbleSender, kind: GroupBubbleSender.Kind)] {
        pendingInvites.compactMap { p in
            let kind: GroupBubbleSender.Kind = p.kind == "bot" ? .bot : .user
            let lookupKey = (kind == .bot ? "bot:" : "user:") + p.id
            let sender = members[lookupKey]
                ?? GroupBubbleSender(
                    kind: kind,
                    id: p.id,
                    displayName: String(p.id.prefix(6)),
                    avatarPath: nil,
                    avatarSeed: p.id,
                )
            return (sender, kind)
        }
    }

    /// Group bots not currently in the call — candidates for add-bot.
    var addableBots: [GroupBubbleSender] {
        let inCall = Set(roster.map(\.botId))
        let pendingIds = Set(pendingInvites.filter { $0.kind == "bot" }.map(\.id))
        return members.values
            .filter { $0.kind == .bot && !inCall.contains($0.id) && !pendingIds.contains($0.id) }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Group humans (excluding the caller) not currently in the call and
    /// not already being rung — candidates for the "叫真人来" sheet.
    var ringableHumans: [GroupBubbleSender] {
        let inCall = Set(humanRoster.map(\.humanId))
        let pendingIds = Set(pendingInvites.filter { $0.kind == "human" }.map(\.id))
        return members.values
            .filter {
                $0.kind == .user
                && $0.id != currentUserId
                && !inCall.contains($0.id)
                && !pendingIds.contains($0.id)
            }
            .sorted { $0.displayName < $1.displayName }
    }

    /// True when the caller is the only one in the call — UI shows
    /// "等其他人进" rather than the regular "通话中" status.
    var isAlone: Bool {
        humanParticipants.isEmpty && botParticipants.isEmpty
    }

    // MARK: - Lifecycle

    func start() async {
        guard phase == .idle else { return }
        phase = .connecting

        // Hook into CallKit. If we got here because a VoIP push fired
        // and the user accepted on the CallKit incoming UI, the
        // manager already has an active call UUID for this conv — claim
        // it. Otherwise (manual join from the in-conv banner) mint a
        // fresh outgoing CallKit call. Either way the CallKit teardown
        // path lands on hangUp(), so the in-app and system controls
        // converge on one teardown.
        let cxManager = CallKitManager.shared
        if let claimed = cxManager.claimIncoming(forConversation: conversationId) {
            callKitUUID = claimed
            cxManager.setOnSystemEnd(claimed) { [weak self] in
                guard let self else { return }
                self.callKitUUID = nil
                Task { @MainActor in await self.hangUp() }
            }
        } else {
            let display = groupTitle.isEmpty ? "群语音" : groupTitle
            callKitUUID = cxManager.startOutgoingCall(
                displayName: display,
                onSystemEnd: { [weak self] in
                    guard let self else { return }
                    self.callKitUUID = nil
                    Task { @MainActor in await self.hangUp() }
                },
            )
        }

        await loadGroupRole()

        // Open the empty room (idempotent — a no-op if the call is
        // already running). Bots and other humans are NOT auto-pulled;
        // the caller invites them from the call UI. `initiated` tells us
        // if we're the one who opened it (and is thus privileged).
        let iceServers: [VoiceCallAPI.SessionResponse.IceServer]
        do {
            let started = try await api.groupVoiceStart(conversationId: conversationId)
            didInitiate = started.initiated ?? false
            iceServers = started.ice_servers ?? []
        } catch let err as VoiceCallError {
            await terminate(reason: translate(err))
            return
        } catch {
            await terminate(reason: .startupError(error.localizedDescription))
            return
        }
        if isTerminal(phase) { return }
        isPrivileged = didInitiate || groupRoleIsAdmin

        // Subscribe to the conv hub for `voice_cost` previews — every
        // bot's settleTurn fans out a delta + cumulative PND to every
        // joined human. The view reads cumulativePnd off this observer.
        await subscribeToCost()

        let transport = GroupCallTransport(
            conversationId: conversationId,
            api: api,
            iceServers: iceServers,
            delegate: self,
        )
        self.transport = transport

        // Watchdog — a transport that neither connects nor fails (ICE
        // silently stalls) shouldn't hang the connecting screen forever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.connectTimeoutNanos)
            guard let self, self.phase == .connecting else { return }
            await self.terminate(reason: .network)
        }

        await transport.start()
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.heartbeatIntervalNanos)
                if Task.isCancelled { return }
                guard !isTerminal(self.phase) else { return }
                do {
                    try await self.api.groupVoiceHeartbeat(conversationId: self.conversationId)
                } catch let VoiceCallError.other(status, code, _) where status == 404 || code == "not_in_room" {
                    // DO already forgot us — finalize already ran (or
                    // we missed too many beats while suspended). Tear
                    // down locally so the UI matches server truth.
                    if !isTerminal(self.phase) {
                        await self.terminate(reason: .ended)
                    }
                    return
                } catch {
                    // Transient — keep beating. The DO's 30s grace gives
                    // us two more attempts before it times us out.
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Read the caller's role in the group so owner/admins get the
    /// privileged controls even when they didn't open the call.
    private func loadGroupRole() async {
        struct Row: Decodable { let role: String? }
        do {
            let rows: [Row] = try await SupabaseStack.shared
                .from("conversation_participants")
                .select("role")
                .eq("conversation_id", value: conversationId)
                .eq("participant_type", value: "user")
                .eq("participant_id", value: currentUserId)
                .execute()
                .value
            let role = rows.first?.role
            groupRoleIsAdmin = role == "owner" || role == "admin"
        } catch {
            // Non-fatal — fall back to initiator-only privilege.
            groupRoleIsAdmin = false
        }
    }

    func toggleSpeaker() {
        let on = !isSpeakerOn
        do {
            try AVAudioSession.sharedInstance()
                .overrideOutputAudioPort(on ? .speaker : .none)
            isSpeakerOn = on
        } catch {
            // Non-fatal — leave the route + flag as they were.
        }
    }

    // MARK: - Caller actions

    /// The caller leaves the call. If they are the last human admin the
    /// worker ends the whole call — either way this device tears down.
    func hangUp() async {
        await terminate(reason: .user)
    }

    /// End the whole call for everyone. Privileged — the worker rejects
    /// it with 403 otherwise (surfaced via `actionError`).
    func endCall() async {
        guard !isTerminal(phase) else { return }
        phase = .hangingUp
        let transport = self.transport
        self.transport = nil
        stopHeartbeat()
        await unsubscribeFromCost()
        if let uuid = callKitUUID {
            callKitUUID = nil
            CallKitManager.shared.endCall(uuid: uuid)
        }
        Task { @MainActor in
            do {
                try await self.api.groupVoiceEnd(conversationId: self.conversationId)
            } catch {
                // Best-effort — we're tearing down locally regardless.
            }
            transport?.hangUp()
            // Reflect the room-gone state in the banner store right
            // away — endCall finalised the DO, and other clients will
            // pick it up via the broadcast 'ended' frame on their own.
            await ActiveVoiceCallStore.shared.refresh()
        }
        phase = .terminated(.ended)
    }

    /// Remove a bot or human from the call. Privileged.
    func kick(kind: GroupBubbleSender.Kind, id: String) async {
        do {
            try await api.groupVoiceKick(
                conversationId: conversationId,
                targetType: kind == .bot ? "bot" : "human",
                targetId: id,
            )
            // Reflect the removal — a re-sync re-reads the roster.
            await transport?.resyncRoster()
        } catch {
            actionError = kickErrorText(error)
        }
    }

    /// Grant call-admin powers to a human or bot. Privileged.
    func designateAdmin(id: String) async {
        do {
            try await api.groupVoiceDesignateAdmin(
                conversationId: conversationId,
                targetId: id,
            )
        } catch {
            actionError = "指定管理员失败"
        }
    }

    /// Add another group bot to the live call. Any participant may call
    /// this — bots no longer auto-join on /voice/start, so a human has
    /// to tap "叫机器人来" inside the call UI first.
    func addBot(id: String) async {
        do {
            try await api.groupVoiceAddBot(conversationId: conversationId, botId: id)
        } catch {
            actionError = "添加机器人失败"
            return
        }
        // The bot's SFU ingest track needs a moment to come up before it
        // appears in the roster — give it a beat, then re-sync.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await transport?.resyncRoster()
    }

    /// Ring a group human into the call. Sends an APNs push so their
    /// phone actually rings, and stages them in the pending set so the
    /// UI shows them as "正在拉".
    func ringHuman(id: String) async {
        do {
            try await api.groupVoiceRing(conversationId: conversationId, userId: id)
            // Optimistic — show them in pending immediately. The next
            // realtime/poll snapshot will replace this with the truth.
            if !pendingInvites.contains(where: { $0.id == id }) {
                pendingInvites.append(
                    GroupPendingEntry(
                        id: id,
                        kind: "human",
                        invitedAt: Date().timeIntervalSince1970 * 1000,
                        invitedBy: currentUserId,
                    ),
                )
            }
        } catch {
            actionError = "邀请失败，请重试"
        }
    }

    /// Drop a pending invite (cancel the ring).
    func cancelInvite(id: String) async {
        do {
            try await api.groupVoiceCancelInvite(
                conversationId: conversationId,
                targetId: id,
            )
            pendingInvites.removeAll { $0.id == id }
        } catch {
            actionError = "取消失败"
        }
    }

    // MARK: - Teardown

    private func terminate(reason: TerminateReason) async {
        guard !isTerminal(phase) else { return }
        phase = .hangingUp
        let transport = self.transport
        self.transport = nil
        stopHeartbeat()
        await unsubscribeFromCost()
        // Tell CallKit the call is done. Skipped when CallKit *drove*
        // the teardown (onSystemEnd already cleared callKitUUID) so we
        // don't double-end the action.
        if let uuid = callKitUUID {
            callKitUUID = nil
            CallKitManager.shared.endCall(uuid: uuid)
        }
        Task { @MainActor in
            transport?.hangUp()
            // Tell the worker we left so the room's human-admin invariant
            // and participant set stay correct. Skipped for `.ended` —
            // endCall already finalized the whole room.
            //
            // Retry once after a short backoff because the most common
            // terminate path is `.network`, where the first POST is
            // likely to fail for the same reason the call did. Without a
            // retry, the DO is left holding a stale human and the
            // in-conv banner stays stuck until the 30-min alarm.
            if reason != .ended {
                await self.bestEffortLeave()
            }
            // Refresh the active-calls index so the in-conv banner
            // reflects server truth — if the DO finalised (we were the
            // last human admin), the row is gone and the banner clears.
            await ActiveVoiceCallStore.shared.refresh()
        }
        phase = .terminated(reason)
    }

    /// POST /voice/leave with one retry — the first attempt often races
    /// the same network failure that triggered teardown.
    private func bestEffortLeave() async {
        for attempt in 0..<2 {
            do {
                try await api.groupVoiceLeave(conversationId: conversationId)
                return
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
    }

    /// Open a conv-hub subscription that feeds `cumulativePnd` from the
    /// server's voice_cost events. Other observers on the same channel
    /// (banners, message stream) keep working through this token —
    /// observers are independent.
    private func subscribeToCost() async {
        let token = await RealtimeManager.shared.startConvChannel(
            conversationId: conversationId,
            onMessage: { _ in },
            onVoiceCall: { [weak self] frame in
                Task { @MainActor [weak self] in
                    guard let self, frame.conversationId == self.conversationId else { return }
                    if let diagnostics = frame.diagnostics {
                        self.latestMediaDiagnostics = diagnostics
                        self.mergeDiagnostics()
                    }
                }
            },
            onVoiceCost: { [weak self] cost in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if cost.cumulativePnd > self.cumulativePnd {
                        self.cumulativePnd = cost.cumulativePnd
                    }
                }
            },
        )
        costSubscription = token
    }

    private func unsubscribeFromCost() async {
        if let token = costSubscription {
            costSubscription = nil
            await RealtimeManager.shared.stopConvChannel(token)
        }
    }

    private func isTerminal(_ p: Phase) -> Bool {
        switch p {
        case .terminated, .hangingUp: return true
        default: return false
        }
    }

    private func kickErrorText(_ error: Error) -> String {
        if case let VoiceCallError.other(status, _, _) = error {
            if status == 403 { return "你没有权限移除该成员" }
            if status == 409 { return "无法移除：群里必须保留一名管理员" }
        }
        return "移除成员失败"
    }

    private func translate(_ err: VoiceCallError) -> TerminateReason {
        switch err {
        case .insufficientBalance:
            return .noBalance
        case .routeUnavailable(let m), .other(_, _, let m):
            return .remoteError(m.isEmpty ? "通话失败" : m)
        case .sessionExpired:
            return .remoteError("通话会话已过期")
        case .regionUnsupported(_, let m, _):
            return .remoteError(m.isEmpty ? "通话失败" : m)
        }
    }
}

// MARK: - GroupCallTransportDelegate

extension GroupCallSession: GroupCallTransportDelegate {
    func transportDidConnect(_ t: GroupCallTransport) {
        guard t === transport, phase == .connecting else { return }
        connectedAt = Date()
        phase = .connected
        // /voice/join has landed by now (addHuman ran on the DO), so the
        // first heartbeat is safe to send — it'll find us in the room.
        startHeartbeat()
        // Flip the CallKit lock-screen UI to "in call" so the timer
        // starts and Control Center shows green.
        if let uuid = callKitUUID {
            CallKitManager.shared.reportCallConnected(uuid: uuid)
        }
    }

    func transport(_ t: GroupCallTransport, didUpdateRoster snapshot: GroupRosterSnapshot) {
        guard t === transport else { return }
        roster = snapshot.bots
        humanRoster = snapshot.humans
        pendingInvites = snapshot.pending
        if let diagnostics = snapshot.diagnostics {
            latestMediaDiagnostics = diagnostics
            mergeDiagnostics()
        }
    }

    func transport(_ t: GroupCallTransport, didUpdateDiagnostics snapshot: CallDiagnosticsSnapshot) {
        guard t === transport else { return }
        latestTransportDiagnostics = snapshot
        mergeDiagnostics()
    }

    func transport(
        _ t: GroupCallTransport,
        didFailWith reason: TerminateReason,
    ) async {
        guard t === transport else { return }
        if isTerminal(phase) { return }
        // Whether we failed during `connecting` (e.g. /voice/join 502'd
        // or ICE never completed) or mid-call (.disconnected → .failed),
        // run the same teardown: best-effort leave + refresh the banner
        // store so a stuck "通话中" row clears as soon as the DO finalises.
        await terminate(reason: reason)
    }

    private func mergeDiagnostics() {
        var snapshot = latestTransportDiagnostics
        let mediaParticipants = (latestMediaDiagnostics?.participants ?? [])
            .filter { !($0.kind == "human" && $0.id == currentUserId) }
            .map(mediaParticipant)
        let local = CallParticipantDiagnostic(
            kind: .local,
            id: currentUserId,
            displayName: "我",
            speaking: snapshot.localSpeaking,
            audioLevel: snapshot.localAudioLevel,
            playoutDepthMs: nil,
            underruns: nil,
            maxGapMs: nil,
            connected: true,
        )
        snapshot.participants = [local] + mediaParticipants
        if let active = snapshot.participants.first(where: \.speaking) {
            snapshot.activeSpeaker = active.displayName
        }
        if let bottleneck = mediaBottleneck(mediaParticipants) {
            snapshot.bottleneck = bottleneck
            if snapshot.quality == .unknown || snapshot.quality == .good {
                snapshot.quality = .fair
            }
        }
        diagnostics = snapshot
    }

    private func mediaParticipant(_ p: GroupMediaDiagnostics.Participant) -> CallParticipantDiagnostic {
        let kind: CallParticipantDiagnostic.Kind = p.kind == "bot" ? .bot : .human
        let sender = members["\(p.kind == "bot" ? "bot" : "user"):\(p.id)"]
        return CallParticipantDiagnostic(
            kind: kind,
            id: p.id,
            displayName: sender?.displayName ?? String(p.id.prefix(6)),
            speaking: p.speaking,
            audioLevel: p.audioLevel ?? 0,
            playoutDepthMs: p.playoutDepthMs,
            underruns: p.underruns,
            maxGapMs: p.maxGapMs,
            connected: p.streamConnected ?? p.ingestConnected ?? p.modelSessionReady,
        )
    }

    private func mediaBottleneck(_ participants: [CallParticipantDiagnostic]) -> String? {
        for p in participants where p.kind == .bot {
            if (p.underruns ?? 0) > 0 {
                return "\(p.displayName) 的容器播放缓冲发生欠载，优先看语音模型输出或 CF container 调度。"
            }
            if (p.maxGapMs ?? 0) >= 700 {
                return "\(p.displayName) 的模型音频增量间隔偏大，瓶颈更像语音模型输出。"
            }
            if let depth = p.playoutDepthMs, depth < 80, p.speaking {
                return "\(p.displayName) 的容器播放缓冲偏浅，可能出现机器人声音卡顿。"
            }
        }
        return nil
    }
}
