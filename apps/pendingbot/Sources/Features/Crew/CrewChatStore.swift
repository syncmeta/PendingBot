import Foundation
import Observation
import Supabase

// T4.6 P1 — view-model for the crew chat surface. Owns the adapted
// message list + session/child rows + the mention candidate set, and
// drives the optimistic human-post path.
//
// T4.5 — now LIVE: a crew IS a conversation, so the existing
// `conv:<crewId>` RealtimeHub topic fans out crew_announcements +
// crew_sessions row changes. `start(detail:)` opens that channel after the
// first cold `load()`; `apply` / `applySession` upsert the live frames.
// `load()` remains the cold-start + pull-to-refresh fallback.

@MainActor
@Observable
final class CrewChatStore {
    let crewId: String
    private let api: APIClient

    /// Adapted, sorted (oldest-first) chat rows + their resolved sender.
    private(set) var rows: [CrewChatRow] = []
    private(set) var sessions: [CrewSessionRow] = []
    /// Child crew links (from the already-loaded crew detail).
    private(set) var children: [CrewLinkV2] = []
    /// Mention candidates for the composer picker.
    private(set) var mentionCandidates: [CrewMentionCandidate] = []

    private(set) var loading = false
    var error: String?

    /// Bumped each time `rows` changes by an append/replace so the list can
    /// scroll to bottom on new content.
    private(set) var revision = 0

    /// Latest adapter (member + session indexes), rebuilt on every cold
    /// `load()`. Live frames adapt against this so a single announcement /
    /// session row resolves its sender name without a re-fetch.
    private var adapter: CrewChatAdapter?
    /// Live conv-channel subscription token, set by `start`, cleared by
    /// `stop`. Non-nil ⇒ already subscribed (idempotency guard).
    private var realtimeToken: ConvSubscriptionToken?

    /// permission_request_ids whose decide() call is in flight — the card
    /// reads this to disable its buttons while we wait for the status flip.
    private(set) var decidingPermissionIds: Set<String> = []

    init(crewId: String, api: APIClient) {
        self.crewId = crewId
        self.api = api
    }

    /// One adapted chat row. Normal posts render as a bubble (the
    /// `ChatMessage` BubbleView + per-message `GroupBubbleSender`). Rows
    /// whose announcement `message_kind == 'permission_request'` render as
    /// an inline permission card instead — `permission` carries the decoded
    /// payload and `permissionSessionLabel` the requesting session's name.
    /// `message` is still populated for both variants (it supplies the row
    /// id + created_at used for dedupe / sorting).
    struct CrewChatRow: Identifiable, Equatable {
        let message: ChatMessage
        let sender: GroupBubbleSender?
        /// Non-nil ⇒ render the permission card instead of a bubble.
        var permission: PermissionRequestPayload? = nil
        var permissionSessionLabel: String? = nil
        /// Non-nil ⇒ render the task-dispatch card (#242 遥控 v1).
        var taskRequest: CrewTaskRequestPayload? = nil
        var id: String { message.id }
        var isPermission: Bool { permission != nil }
    }

    // MARK: - Load

    /// Concurrently pull announcements + sessions + members, plus refresh
    /// the crew detail for children + captain fallback name. Adapt + sort.
    func load(detail: CrewDetailV2? = nil) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            async let annsTask = api.getCrewAnnouncements(crewId)
            async let sessionsTask = api.getCrewSessions(crewId)
            async let membersTask = api.getCrewMembers(crewId)

            let anns = try await annsTask
            let sessionRows = try await sessionsTask
            let members = try await membersTask

            let captainName = detail?.captain?.displayName
            let memberIndex = CrewMemberIndex(members: members, captainFallbackName: captainName)
            let sessionIndex = CrewSessionIndex(sessions: sessionRows)
            let adapter = CrewChatAdapter(crewId: crewId, members: memberIndex, sessions: sessionIndex)
            self.adapter = adapter

            // Preserve any in-flight optimistic rows (status == sending) so
            // a refresh that races a send doesn't drop the local bubble.
            let pending = rows.filter { $0.message.isSending || $0.message.isFailed }
            var adapted = adapter.adapt(anns).map {
                CrewChatRow(message: $0.message, sender: $0.sender,
                            permission: $0.permission,
                            permissionSessionLabel: $0.permissionSessionLabel,
                            taskRequest: $0.taskRequest)
            }
            // Drop pending rows that the server has now echoed back.
            let serverIds = Set(adapted.map(\.id))
            adapted.append(contentsOf: pending.filter { !serverIds.contains($0.id) })
            adapted.sort { $0.message.created_at < $1.message.created_at }

            self.rows = adapted
            self.sessions = sessionRows
            if let detail { self.children = detail.children }
            self.mentionCandidates = Self.buildCandidates(members: members, sessions: sessionRows)
            self.revision += 1
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Live subscription (T4.5)

    /// Open the crew's conv-channel and route crew_announcements /
    /// crew_sessions frames into the appliers. Idempotent — a second call
    /// while already subscribed is a no-op (re-entering the view after a
    /// reload must not double-subscribe). Call after the first successful
    /// `load()` so the adapter (member/session indexes) is ready.
    func start(detail _: CrewDetailV2? = nil) async {
        guard realtimeToken == nil, !crewId.isEmpty else { return }
        realtimeToken = await RealtimeManager.shared.startConvChannel(
            conversationId: crewId,
            onMessage: { _ in },
            onCrewAnnouncement: { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            },
            onCrewSession: { [weak self] event in
                Task { @MainActor in self?.applySession(event) }
            }
        )
    }

    /// Drop the live subscription. Call on view disappear.
    func stop() async {
        guard let token = realtimeToken else { return }
        realtimeToken = nil
        await RealtimeManager.shared.stopConvChannel(token)
    }

    /// crew_announcements INSERT/UPDATE → upsert into `rows` by message id.
    /// INSERT = a new whiteboard post / permission card; UPDATE = a
    /// permission status flip (decide() stamps approved/denied onto the
    /// row, which fans back here). Re-sort + bump revision on any change.
    func apply(_ event: CrewAnnouncementEvent) {
        guard let row = Self.decodeAnnouncement(event.record),
              let adapter else { return }
        // Skip our own still-pending optimistic bubble's echo — `send()`
        // already reloads to fold the canonical row, and the live frame
        // carries no client id to match a local-* row, so an optimistic
        // row stays put until that reload replaces it. Dedupe is purely by
        // canonical id below; the optimistic local-<uuid> id never collides.
        let adapted = adapter.adapt(row)
        let newRow = CrewChatRow(message: adapted.message, sender: adapted.sender,
                                 permission: adapted.permission,
                                 permissionSessionLabel: adapted.permissionSessionLabel,
                                 taskRequest: adapted.taskRequest)
        if let idx = rows.firstIndex(where: { $0.id == newRow.id }) {
            rows[idx] = newRow
        } else {
            rows.append(newRow)
        }
        rows.sort { $0.message.created_at < $1.message.created_at }
        revision += 1
    }

    /// crew_sessions INSERT/UPDATE → upsert into `sessions` by id so the
    /// session index / status stays live. Bumps revision so any session-
    /// derived label refreshes.
    func applySession(_ event: CrewSessionEvent) {
        guard let row = Self.decodeSession(event.record) else { return }
        if let idx = sessions.firstIndex(where: { $0.id == row.id }) {
            sessions[idx] = row
        } else {
            sessions.append(row)
        }
        revision += 1
    }

    // MARK: - Live record decoders

    /// Build a `CrewAnnouncementRow` from a raw `[String: AnyJSON]` realtime
    /// frame, field-by-field (the ConversationView+Realtime pattern — no
    /// top-level JSONDecoder round-trip). Live frames carry no `mentions`
    /// join, so `mentions: []`. Returns nil if the id/text is missing.
    static func decodeAnnouncement(_ r: [String: AnyJSON]) -> CrewAnnouncementRow? {
        guard let id = r["id"]?.stringValue else { return nil }
        // `payload` is a jsonb cell. Re-encode the AnyJSON value to bytes
        // and JSONDecode it into PermissionRequestPayload (decodeLogPayload
        // returns nil on missing / literal-null / wrong-shape). For non-
        // permission rows the payload decodes to an all-nil struct that the
        // adapter never reads — only message_kind=='permission_request'
        // consults it.
        let payload: PermissionRequestPayload? = r["payload"].flatMap {
            decodeLogPayload($0, as: PermissionRequestPayload.self)
        }
        // Same cell, leniently decoded as a task-request body — only
        // message_kind=='task_request' rows ever read it (#242 遥控 v1).
        let task: CrewTaskRequestPayload? = r["payload"].flatMap {
            decodeLogPayload($0, as: CrewTaskRequestPayload.self)
        }
        return CrewAnnouncementRow(
            id: id,
            crew_conversation_id: r["crew_conversation_id"]?.stringValue ?? "",
            responsible_subject_id: r["responsible_subject_id"]?.stringValue,
            sender_kind: r["sender_kind"]?.stringValue ?? "system",
            sender_member_id: r["sender_member_id"]?.stringValue,
            sender_session_id: r["sender_session_id"]?.stringValue,
            recipient_mode: r["recipient_mode"]?.stringValue,
            message_kind: r["message_kind"]?.stringValue ?? "text",
            board_visible: r["board_visible"]?.boolValue ?? true,
            summary: r["summary"]?.stringValue ?? "",
            payload: (payload != nil || task != nil)
                ? LenientPermissionPayload(value: payload, task: task)
                : nil,
            created_at: r["created_at"]?.stringValue ?? "",
            mentions: []
        )
    }

    static func decodeSession(_ r: [String: AnyJSON]) -> CrewSessionRow? {
        guard let id = r["id"]?.stringValue else { return nil }
        return CrewSessionRow(
            id: id,
            crew_conversation_id: r["crew_conversation_id"]?.stringValue ?? "",
            responsible_subject_id: r["responsible_subject_id"]?.stringValue,
            runner_kind: r["runner_kind"]?.stringValue,
            status: r["status"]?.stringValue ?? "",
            task_brief: r["task_brief"]?.stringValue,
            progress_summary: r["progress_summary"]?.stringValue,
            created_at: r["created_at"]?.stringValue ?? "",
            started_at: r["started_at"]?.stringValue,
            finished_at: r["finished_at"]?.stringValue
        )
    }

    // MARK: - Send (optimistic)

    /// Optimistically insert a `sending` bubble, post it, then reload to
    /// pick up the canonical row (and any fan-out). On failure, mark the
    /// local bubble `failed` so the user can retry.
    func send(content: String, mentions: [CrewMentionInput], detail: CrewDetailV2?) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let localId = "local-\(UUID().uuidString)"
        let optimistic = ChatMessage(
            id: localId,
            conversation_id: crewId,
            sender_type: "user",
            sender_id: "",
            content: trimmed,
            created_at: Int(Date().timeIntervalSince1970),
            attachments: nil,
            status: "sending"
        )
        let meSender = GroupBubbleSender(
            kind: .user, id: "me", displayName: "我",
            avatarPath: nil, avatarSeed: "me-\(crewId)"
        )
        rows.append(CrewChatRow(message: optimistic, sender: meSender))
        revision += 1

        do {
            _ = try await api.postCrewMessage(crewId: crewId, content: trimmed, mentions: mentions)
            // Reload to fold in the server row; the optimistic row is
            // dropped because load() only keeps still-sending/failed ones
            // and this one is no longer in `rows` after a successful reload.
            markRemoved(localId)
            await load(detail: detail)
        } catch {
            mark(localId, status: "failed")
            self.error = error.localizedDescription
        }
    }

    /// #242 遥控 v1 — queue a task for the crew's Mac: posts a
    /// `message_kind='task_request'` crew message whose payload the Mac
    /// relay picks up (`{ action: 'run_session', task_brief, runner_kind }`).
    /// No optimistic bubble — the dispatch sheet stays up until this
    /// returns, then the reload folds in the canonical card row.
    /// Returns true on success (the sheet dismisses on that).
    func sendTaskRequest(brief: String, runnerKind: String, detail: CrewDetailV2?) async -> Bool {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            _ = try await api.postCrewMessage(
                crewId: crewId,
                content: trimmed,
                mentions: [],
                messageKind: "task_request",
                payload: CrewTaskRequestPayload(
                    action: "run_session",
                    task_brief: trimmed,
                    runner_kind: runnerKind
                )
            )
            await load(detail: detail)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Re-send a failed local bubble.
    func retry(_ rowId: String, mentions: [CrewMentionInput], detail: CrewDetailV2?) async {
        guard let row = rows.first(where: { $0.id == rowId }) else { return }
        markRemoved(rowId)
        await send(content: row.message.content, mentions: mentions, detail: detail)
    }

    // MARK: - Permission decide (T4.5)

    /// Approve / deny a permission card by its permission_request_id. Marks
    /// the id in-flight (the card disables its buttons), calls the decide
    /// endpoint, then clears the flag. The endpoint stamps the new status
    /// onto the announcement, which fans back as a crew_announcements UPDATE
    /// and flips the card via `apply` — so the happy path needs no manual
    /// refresh. If no live frame arrives (or we hit a 409 already-decided),
    /// reload to reconcile. `detail` is the crew detail for the reload.
    func decide(permissionRequestId: String, approve: Bool, detail: CrewDetailV2?) async {
        guard !decidingPermissionIds.contains(permissionRequestId) else { return }
        decidingPermissionIds.insert(permissionRequestId)
        revision += 1
        defer {
            decidingPermissionIds.remove(permissionRequestId)
            revision += 1
        }
        do {
            _ = try await api.decidePermissionRequest(
                id: permissionRequestId,
                decision: approve ? .approve : .reject
            )
            // Belt-and-suspenders: if the live UPDATE frame is slow / dropped,
            // reload picks up the stamped status. Cheap relative to a decide.
            await load(detail: detail)
        } catch {
            // 409 permission_request_already_decided (or any other error):
            // reload to surface the authoritative status the server holds.
            if case let APIError.http(status, _, _, _) = error, status == 409 {
                await load(detail: detail)
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    private func mark(_ id: String, status: String) {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        let old = rows[idx]
        let updated = ChatMessage(
            id: old.message.id,
            conversation_id: old.message.conversation_id,
            sender_type: old.message.sender_type,
            sender_id: old.message.sender_id,
            content: old.message.content,
            created_at: old.message.created_at,
            attachments: old.message.attachments,
            status: status
        )
        rows[idx] = CrewChatRow(message: updated, sender: old.sender)
        revision += 1
    }

    private func markRemoved(_ id: String) {
        rows.removeAll { $0.id == id }
    }

    // MARK: - Mention candidates

    /// Builds the @人/@session/@captain candidate set from the member +
    /// session lists. `@broadcast` is implicit (no mention = everyone), so
    /// it is not a candidate row.
    private static func buildCandidates(
        members: [CrewMemberRow],
        sessions: [CrewSessionRow]
    ) -> [CrewMentionCandidate] {
        var out: [CrewMentionCandidate] = []
        for m in members {
            let name = m.display_name?.isEmpty == false ? m.display_name! : String(m.id.prefix(6))
            switch m.member_kind {
            case "human":
                // 'human' mentions are metadata-only server-side; target_id
                // is the member id (optional for routing).
                out.append(.init(kind: "human", targetId: m.id, label: name, glyph: "person"))
            case "bot":
                // The captain bot — server resolves 'captain' with no
                // target_id needed.
                out.append(.init(kind: "captain", targetId: nil, label: name, glyph: "person.crop.circle.badge.checkmark"))
            default:
                break
            }
        }
        for s in sessions {
            let label = s.task_brief?.isEmpty == false
                ? s.task_brief!
                : CrewSessionIndex.runnerLabel(s.runner_kind ?? "Session")
            out.append(.init(kind: "session", targetId: s.id, label: label, glyph: "terminal"))
        }
        return out
    }
}

/// One @mention candidate the composer picker can insert. `kind`/`targetId`
/// feed straight into `CrewMentionInput`.
struct CrewMentionCandidate: Identifiable, Hashable {
    let kind: String          // 'human' | 'session' | 'captain'
    let targetId: String?
    let label: String
    let glyph: String
    var id: String { "\(kind)-\(targetId ?? label)" }

    var mentionInput: CrewMentionInput { .init(kind: kind, target_id: targetId) }
}
