import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Cross-platform chat data source (T0.1 macOS 消息 tab)
//
// A minimal, gate-free read/send surface for the conversation list + 1:1 text
// chat, used by the macOS PendingBot 消息 tab (`Sources/Mac/Views/MacMessagesView.swift`).
//
// iOS's equivalent logic is inlined inside `MessageTabView` / `ConversationView`
// (a verified but UIKit-coupled View), so it can't be reused as-is; rather than
// refactor the iOS 范本 (regression risk while it's the proven baseline), this
// is a fresh minimal service that mirrors the same Supabase queries + reuses the
// verified `ChatStream` SSE for sending. The macOS 第一版 deliberately drops:
// unread badges, group/user_user peer resolution, attachments, Realtime push
// (poll instead). iOS can migrate onto this service later for DRY.
//
// 时间戳规避: the queries intentionally DON'T `select` any timestamptz column
// (updated_at / created_at). `order(...)` still sorts on them server-side; the
// client just renders in returned order. This sidesteps the Decodable
// String-vs-Int-vs-Date ambiguity that would otherwise fail the whole decode.
// ─────────────────────────────────────────────────────────────────────

/// One conversation-list row for the macOS 消息 tab.
struct ChatConversationSummary: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let preview: String
    /// `user_bot` / `self` / `user_user` / `group` — drives a small badge.
    let conversationType: String?
    let unreadCount: Int
}

/// One message bubble row for the macOS chat view.
struct ChatMessageRow: Identifiable, Equatable, Hashable {
    let id: String
    /// `user` / `assistant` / `bot` / `system` / `log` (raw messages.role).
    let role: String
    let content: String
    let seq: Int?

    /// Right-aligned (mine) only for human-sent rows.
    var isMine: Bool { role == "user" }
    /// Left-aligned bot reply.
    var isBot: Bool { role == "assistant" || role == "bot" }
    /// Tool-trace / control rows that aren't conversational bubbles — hidden.
    var isHidden: Bool { role == "log" }
}

enum ChatDataSource {
    // MARK: conversation list

    /// The conversation list (most-recent first), projected to a thin summary.
    /// Runs the SAME query as iOS's `MessageTabView.load()` via the shared
    /// `ConversationFetch.list()` — no hand-copied query here anymore — and just
    /// keeps the columns the macOS list renders (title / preview / unread).
    static func listConversations() async throws -> [ChatConversationSummary] {
        let rows = try await ConversationFetch.list()
        return rows.map { row in
            let title = [row.title, row.bot?.display_name]
                .compactMap { $0 }
                .first { !$0.isEmpty } ?? "未命名"
            let preview = (row.unread?.first?.last_message_preview ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return ChatConversationSummary(
                id: row.id,
                title: title,
                preview: preview,
                conversationType: row.conversation_type,
                unreadCount: row.unread?.first?.unread_count ?? 0
            )
        }
    }

    // MARK: message history

    /// Messages for one conversation, oldest→newest (server-ordered by
    /// message_seq then created_at). Tool-trace `log` rows are kept in the raw
    /// result; the view hides them via `ChatMessageRow.isHidden`.
    static func loadMessages(conversationId: String, limit: Int = 200) async throws -> [ChatMessageRow] {
        struct Row: Decodable {
            let id: String
            let role: String?
            let content: String?
            let message_seq: Int?
        }
        let rows: [Row] = try await SupabaseStack.shared
            .from("messages")
            .select("id, role, content, message_seq")
            .eq("conversation_id", value: conversationId)
            .order("message_seq", ascending: true)
            .order("created_at", ascending: true)
            .limit(limit)
            .execute()
            .value

        return rows.map {
            ChatMessageRow(
                id: $0.id,
                role: $0.role ?? "assistant",
                content: $0.content ?? "",
                seq: $0.message_seq
            )
        }
    }

    // MARK: send

    /// Send a user text message and stream the bot reply. Reuses the verified
    /// `ChatStream` SSE wire format. Caller iterates the events (connected /
    /// token / bubble / done / error) and updates its bubble list.
    static func sendMessage(conversationId: String, text: String) -> AsyncThrowingStream<ChatEvent, Error> {
        let body: [String: Any] = [
            "clientMessageId": UUID().uuidString,
            "conversationId": conversationId,
            "newMessage": text,
        ]
        return ChatStream().send(body: body, path: "v1/messages")
    }
}
