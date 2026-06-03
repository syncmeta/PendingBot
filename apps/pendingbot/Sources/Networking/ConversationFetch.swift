import Foundation
import Supabase
import OSLog

private let log = Logger.category("conv-fetch")

// ─────────────────────────────────────────────────────────────────────
// MARK: - Shared conversation-list fetch (iOS + macOS one implementation)
//
// The canonical Supabase query for the top-level conversation list lives here
// so both the iOS `MessageTabView` (which layers a GRDB cache + peer-resolution
// on top) and the macOS `ChatDataSource` (which projects a thin summary) run the
// SAME query shape — same table, same embeds, same filters, same ordering. This
// is the single source of truth for "which columns / joins the conversation list
// reads"; before, iOS inlined it and macOS kept a hand-copied subset that could
// drift. Both now call `ConversationFetch.list()`.
//
// The query returns the iOS superset (`bot` model fields, `unread` last-message
// metadata, `participants` for user_user peer resolution). macOS ignores the
// extra columns; iOS uses them. Keeping one query means a列改了两端一起改, never
// one-side drift.
// ─────────────────────────────────────────────────────────────────────

/// One conversation-list row, decoded straight from the canonical query.
/// `asConversation` collapses it into the shared `Conversation` model; callers
/// that need the raw embeds (`unread` / `participants`) read them directly.
struct ConvListRow: Decodable {
    static func parseTimestamp(_ s: String) -> Int? {
        if let secs = ServerTimestamp.parse(s).map({ Int($0.timeIntervalSince1970) }) {
            return secs
        }
        log.warning("timestamp parse failed: \(s, privacy: .public)")
        return nil
    }

    let id: String
    let bot_id: String?
    let user_id: String?
    let title: String?
    let conversation_type: String?
    let feature: String?
    let round_count: Int?
    let updated_at: String? // ISO 8601
    let bot: BotJoin?
    // PostgREST returns the embedded user_unread_counts as an array
    // (the FK has no unique constraint on conversation_id alone — one
    // row per (user, conv)). With !inner + RLS, callers see at most one.
    let unread: [UnreadJoin]?
    let participants: [ParticipantJoin]?
    struct BotJoin: Decodable {
        let display_name: String?
        let model_id: String?
        let visibility: String?
        let creator_id: String?
    }
    struct UnreadJoin: Decodable {
        let last_message_id: String?
        let last_message_at: String?
        let last_message_preview: String?
        let unread_count: Int?
    }
    struct ParticipantJoin: Decodable {
        let participant_type: String
        let participant_id: String
    }
    var asConversation: Conversation {
        let unreadRow = unread?.first
        let secs: Int = {
            if let s = unreadRow?.last_message_at,
               let ts = ConvListRow.parseTimestamp(s) {
                return ts
            }
            if let updated_at, let ts = ConvListRow.parseTimestamp(updated_at) {
                return ts
            }
            return 0
        }()
        return Conversation(
            id: id,
            bot_id: bot_id ?? "",
            user_id: user_id ?? "",
            title: title,
            feature_type: feature,
            conversation_type: conversation_type,
            last_activity_at: secs,
            round_count: round_count,
            bot_name: bot?.display_name,
            last_message_content: unreadRow?.last_message_preview,
            last_message_sender_type: nil,
            last_message_id: unreadRow?.last_message_id
        )
    }
}

enum ConversationFetch {
    /// The conversation list, server-ordered (updated_at desc, id asc tie-break).
    ///
    /// - `user_unread_counts!inner` makes the unread embed an INNER JOIN so convs
    ///   that never received a non-recap message (no unread row) drop out — this
    ///   is the empty-conversation filter.
    /// - `participants` is embedded so user_user rows can resolve the peer's id
    ///   without a second round-trip (RLS lets a participant see both rows).
    /// - subagent child conversations are excluded — they open from the parent
    ///   tool trace, never as top-level list rows.
    static func list() async throws -> [ConvListRow] {
        try await SupabaseStack.shared
            .from("conversations")
            .select("""
                id, bot_id, user_id, title, conversation_type, feature, round_count, updated_at,
                bot:bots!conversations_bot_id_fkey(display_name, model_id, visibility, creator_id),
                unread:user_unread_counts!inner(last_message_id, last_message_at, last_message_preview, unread_count),
                participants:conversation_participants(participant_type, participant_id)
            """)
            .neq("conversation_type", value: "subagent")
            .order("updated_at", ascending: false)
            .order("id", ascending: true)
            .execute()
            .value
    }
}
