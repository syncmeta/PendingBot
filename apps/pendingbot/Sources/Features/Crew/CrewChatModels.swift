#if os(iOS)
import Foundation

// T4.6 P1 — adapter that turns the snake_case crew whiteboard feed
// (`CrewAnnouncementRow`) into the `ChatMessage` shape `BubbleView`
// already renders, plus the `GroupBubbleSender` that puts each sender's
// name above its bubble. No `BubbleView` refactor — we reuse the existing
// group-chat grammar (sentinel `sender_type` + groupSender) the same way
// proposal / permission cards piggyback on it.

// MARK: - ISO-8601 → epoch

/// `ChatMessage.created_at` is an `Int` epoch, but the snake_case crew
/// routes hand back `created_at` as an ISO-8601 *string*. Parse both the
/// fractional-seconds and plain variants; on failure fall back to 0 so the
/// row still sorts deterministically (oldest-first) rather than crashing
/// or jumping around.
enum CrewTimestamp {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Epoch seconds for an ISO-8601 string, or 0 on parse failure.
    static func epoch(_ iso: String) -> Int {
        if let d = fractional.date(from: iso) { return Int(d.timeIntervalSince1970) }
        if let d = plain.date(from: iso) { return Int(d.timeIntervalSince1970) }
        return 0
    }
}

// MARK: - Member display-name resolution

/// Resolves a crew member's display name + a stable avatar seed from the
/// `/members` list, keyed by `temporary_group_members.id`
/// (= announcement.sender_member_id). Built once per load.
struct CrewMemberIndex {
    /// member id → (displayName, isHuman, seed)
    private let byId: [String: (name: String, isHuman: Bool, seed: String)]
    /// The captain (master_bot) member, if the crew has one — used to
    /// label system / captain posts when sender_member_id doesn't resolve.
    let captainName: String?

    init(members: [CrewMemberRow], captainFallbackName: String?) {
        var map: [String: (name: String, isHuman: Bool, seed: String)] = [:]
        var captain: String? = nil
        for m in members {
            let name = m.display_name?.isEmpty == false
                ? m.display_name!
                : String(m.id.prefix(6))
            let isHuman = m.member_kind == "human"
            // Stable avatar seed: prefer the concrete identity id so the
            // same person/bot renders the same glyph across viewers.
            let seed = m.user_id ?? m.bot_id ?? m.code_session_id ?? m.id
            map[m.id] = (name, isHuman, seed)
            if m.member_kind == "bot", captain == nil {
                captain = name
            }
        }
        self.byId = map
        self.captainName = captain ?? captainFallbackName
    }

    func name(forMember id: String?) -> String? {
        guard let id else { return nil }
        return byId[id]?.name
    }
    func isHuman(memberId id: String?) -> Bool {
        guard let id else { return false }
        return byId[id]?.isHuman ?? false
    }
    func seed(forMember id: String?) -> String? {
        guard let id else { return nil }
        return byId[id]?.seed
    }
}

// MARK: - Session label resolution

/// Maps a `crew_sessions.id` to a short human label for the
/// `GroupBubbleSender` name on agent posts.
struct CrewSessionIndex {
    private let byId: [String: String]

    init(sessions: [CrewSessionRow]) {
        var map: [String: String] = [:]
        for s in sessions {
            let brief = s.task_brief?.isEmpty == false ? s.task_brief! : nil
            let runner = s.runner_kind.map(Self.runnerLabel) ?? "Session"
            map[s.id] = brief ?? runner
        }
        self.byId = map
    }

    func label(forSession id: String?) -> String? {
        guard let id else { return nil }
        return byId[id]
    }

    static func runnerLabel(_ runner: String) -> String {
        switch runner {
        case "local_claude_code": return "Claude Code"
        case "local_codex":       return "Codex"
        default:                  return runner
        }
    }
}

// MARK: - Adapter

/// Adapts crew announcement rows + the member/session indexes into the
/// `(ChatMessage, GroupBubbleSender?)` pairs the message list renders.
///
/// Side mapping (plan R5, robust against `sender_kind` vocab drift):
///   • `sender_session_id != nil` → agent / session post → bot side, with
///     the session label as the sender name.
///   • else, a human member → user side (everyone's human posts render as
///     "mine" — see P1 simplification below — labelled with display_name).
///   • else (captain / system) → bot side, labelled captain / "系统".
///
/// P1 simplification (logged in tech-debt): the feed gives
/// `sender_member_id`, not my user_id, so we can't split me-vs-other
/// humans. All human posts render on the user (right) side with their
/// display name above the bubble, which still reads as a multi-party
/// group thread.
struct CrewChatAdapter {
    let crewId: String
    let members: CrewMemberIndex
    let sessions: CrewSessionIndex

    /// One adapted announcement: a normal bubble, or — when
    /// `message_kind == 'permission_request'` — a permission card carrying
    /// the decoded payload + the requesting session's label. `message` is
    /// always populated (id + created_at drive dedupe / sorting); for a
    /// permission row it doubles as the carrier the bubble path ignores.
    struct Adapted {
        let message: ChatMessage
        let sender: GroupBubbleSender?
        var permission: PermissionRequestPayload? = nil
        var permissionSessionLabel: String? = nil
    }

    func adapt(_ rows: [CrewAnnouncementRow]) -> [Adapted] {
        rows
            .map { adapt($0) }
            .sorted { $0.message.created_at < $1.message.created_at }
    }

    func adapt(_ row: CrewAnnouncementRow) -> Adapted {
        let epoch = CrewTimestamp.epoch(row.created_at)

        // Permission card (T4.5) — message_kind=='permission_request' rows
        // carry the request body in `payload`. Render the centered card
        // instead of a bubble. sessionLabel from the session index by
        // sender_session_id, fallback "Session". `message` is still built
        // (bot side, summary text) so id/created_at sort + the rare case
        // where payload is missing degrades to a plain bubble below.
        if row.message_kind == "permission_request", let payload = row.payload?.value {
            let label = sessions.label(forSession: row.sender_session_id) ?? "Session"
            let msg = ChatMessage(
                id: row.id,
                conversation_id: crewId,
                sender_type: "bot",
                sender_id: row.sender_session_id ?? "crew-permission-\(crewId)",
                content: row.summary,
                created_at: epoch,
                attachments: nil
            )
            return Adapted(message: msg, sender: nil,
                           permission: payload, permissionSessionLabel: label)
        }

        // Agent / session post → bot side.
        if let sessionId = row.sender_session_id {
            let label = sessions.label(forSession: sessionId) ?? "Session"
            let msg = ChatMessage(
                id: row.id,
                conversation_id: crewId,
                sender_type: "bot",
                sender_id: sessionId,
                content: row.summary,
                created_at: epoch,
                attachments: nil
            )
            let sender = GroupBubbleSender(
                kind: .bot, id: sessionId, displayName: label,
                avatarPath: nil, avatarSeed: sessionId
            )
            return Adapted(message: msg, sender: sender)
        }

        // Human member → user side.
        if members.isHuman(memberId: row.sender_member_id),
           let memberId = row.sender_member_id {
            let name = members.name(forMember: memberId) ?? "成员"
            let seed = members.seed(forMember: memberId) ?? memberId
            let msg = ChatMessage(
                id: row.id,
                conversation_id: crewId,
                // sentinel "user" + empty sender_id → BubbleView.isMine
                // returns true (P1: all humans on the user side).
                sender_type: "user",
                sender_id: "",
                content: row.summary,
                created_at: epoch,
                attachments: nil
            )
            let sender = GroupBubbleSender(
                kind: .user, id: memberId, displayName: name,
                avatarPath: nil, avatarSeed: seed
            )
            return Adapted(message: msg, sender: sender)
        }

        // Captain (master_bot) / system / unresolved → bot side.
        let name: String
        let seedId: String
        if let memberId = row.sender_member_id {
            name = members.name(forMember: memberId)
                ?? members.captainName
                ?? "机长"
            seedId = memberId
        } else if row.sender_kind == "system" {
            name = "系统"
            seedId = "crew-system-\(crewId)"
        } else {
            name = members.captainName ?? "机长"
            seedId = "crew-captain-\(crewId)"
        }
        let msg = ChatMessage(
            id: row.id,
            conversation_id: crewId,
            sender_type: "bot",
            sender_id: seedId,
            content: row.summary,
            created_at: epoch,
            attachments: nil
        )
        let sender = GroupBubbleSender(
            kind: .bot, id: seedId, displayName: name,
            avatarPath: nil, avatarSeed: seedId
        )
        return Adapted(message: msg, sender: sender)
    }
}
#endif
