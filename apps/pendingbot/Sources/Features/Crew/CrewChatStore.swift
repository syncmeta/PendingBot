import Foundation
import Observation

// T4.6 P1 — view-model for the crew chat surface. Owns the adapted
// message list + session/child rows + the mention candidate set, and
// drives the optimistic human-post path. Poll-only in P1 (no live push):
// the list refreshes via pull-to-refresh and a reload after each send.
// Live push is T4.5 (SessionProxyDO carries session/permission frames but
// no new-crew-message frame) — logged in tech-debt.

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

    init(crewId: String, api: APIClient) {
        self.crewId = crewId
        self.api = api
    }

    /// One adapted chat row: the `ChatMessage` BubbleView renders plus the
    /// per-message `GroupBubbleSender` (sender name above the bubble).
    struct CrewChatRow: Identifiable, Equatable {
        let message: ChatMessage
        let sender: GroupBubbleSender?
        var id: String { message.id }
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

            // Preserve any in-flight optimistic rows (status == sending) so
            // a refresh that races a send doesn't drop the local bubble.
            let pending = rows.filter { $0.message.isSending || $0.message.isFailed }
            var adapted = adapter.adapt(anns).map { CrewChatRow(message: $0.message, sender: $0.sender) }
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

    /// Re-send a failed local bubble.
    func retry(_ rowId: String, mentions: [CrewMentionInput], detail: CrewDetailV2?) async {
        guard let row = rows.first(where: { $0.id == rowId }) else { return }
        markRemoved(rowId)
        await send(content: row.message.content, mentions: mentions, detail: detail)
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
