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

    /// Current bot roster, as the transport learns it from /join and
    /// any later re-sync. Drives the participant list.
    var roster: [GroupBotRosterEntry] = []

    /// True when the caller may kick / end / designate — they opened the
    /// call, or they are a group owner/admin.
    var isPrivileged: Bool = false

    /// Transient banner text for a failed privileged action (e.g. a kick
    /// the worker rejected with 403). The view clears it.
    var actionError: String?

    // MARK: - Inputs

    let conversationId: String
    let currentUserId: String
    /// Group members keyed "bot:<id>" / "user:<id>" — name + avatar
    /// lookup for the participant list. Sourced from the conversation's
    /// `groupSenders` map.
    let members: [String: GroupBubbleSender]

    // MARK: - Dependencies

    private let api: VoiceCallAPI
    private var transport: GroupCallTransport?
    private var didInitiate = false
    private var groupRoleIsAdmin = false

    /// Total time to wait for the call to connect before giving up.
    private static let connectTimeoutNanos: UInt64 = 20_000_000_000

    init(
        conversationId: String,
        currentUserId: String,
        members: [String: GroupBubbleSender],
        api: VoiceCallAPI,
    ) {
        self.conversationId = conversationId
        self.currentUserId = currentUserId
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

    /// Group bots not currently in the call — candidates for add-bot.
    var addableBots: [GroupBubbleSender] {
        let inCall = Set(roster.map(\.botId))
        return members.values
            .filter { $0.kind == .bot && !inCall.contains($0.id) }
            .sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Lifecycle

    func start() async {
        guard phase == .idle else { return }
        phase = .connecting

        await loadGroupRole()

        // Bring the room's bots online (idempotent — a no-op if the call
        // is already running). `initiated` tells us if we opened it.
        do {
            let started = try await api.groupVoiceStart(conversationId: conversationId)
            didInitiate = started.initiated ?? false
        } catch let err as VoiceCallError {
            phase = .terminated(translate(err))
            return
        } catch {
            phase = .terminated(.startupError(error.localizedDescription))
            return
        }
        if isTerminal(phase) { return }
        isPrivileged = didInitiate || groupRoleIsAdmin

        let transport = GroupCallTransport(
            conversationId: conversationId,
            api: api,
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
        Task { @MainActor in
            do {
                try await self.api.groupVoiceEnd(conversationId: self.conversationId)
            } catch {
                // Best-effort — we're tearing down locally regardless.
            }
            transport?.hangUp()
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

    /// Add another group bot to the live call.
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

    // MARK: - Teardown

    private func terminate(reason: TerminateReason) async {
        guard !isTerminal(phase) else { return }
        phase = .hangingUp
        let transport = self.transport
        self.transport = nil
        Task { @MainActor in
            transport?.hangUp()
            // Tell the worker we left so the room's human-admin invariant
            // and participant set stay correct. Skipped for `.ended` —
            // endCall already finalized the whole room.
            if reason != .ended {
                do {
                    try await self.api.groupVoiceLeave(
                        conversationId: self.conversationId)
                } catch {
                    // Best-effort — the DO also reaps stale humans.
                }
            }
        }
        phase = .terminated(reason)
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
    }

    func transport(_ t: GroupCallTransport, didUpdateRoster bots: [GroupBotRosterEntry]) {
        guard t === transport else { return }
        roster = bots
    }

    func transport(
        _ t: GroupCallTransport,
        didFailWith reason: TerminateReason,
    ) async {
        guard t === transport else { return }
        if isTerminal(phase) { return }
        if phase == .connecting {
            phase = .terminated(reason)
            return
        }
        await terminate(reason: reason)
    }
}
