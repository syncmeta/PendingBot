import Foundation
import Supabase

// ─────────────────────────────────────────────────────────────────────
// MARK: - Shared message-history fetch (iOS + macOS one implementation)
//
// The canonical `messages` read for a conversation — same superset columns iOS
// renders (attachments / citations / tool-trace / recall / arena), returned
// chronological (oldest→newest). iOS layers its GRDB cache + the 200-line
// per-row dispatch on top of `MessageRow`; macOS projects a thin bubble row.
// One query shape, one place to change columns.
//
// `latest()` fetches the LATEST `limit` rows (message_seq desc) then flips to
// chronological — `ascending: true` + limit would pin to the OLDEST rows and
// hide recent messages once a conversation passes the cap.
// ─────────────────────────────────────────────────────────────────────

/// Decoded shape of a `messages.attachments` jsonb column. Worker writes
/// `{ ids: [uuid, ...] }` on insert.
struct AttachmentRef: Decodable, Hashable {
    let ids: [String]?
}

/// One row from `pendingbot.messages` (superset). iOS reads every field via its
/// dispatch; macOS uses id / role / content / message_seq / attachments.
struct MessageRow: Decodable {
    let id: String
    let client_message_id: String?
    let conversation_id: String
    let user_id: String?
    let sender_bot_id: String?
    let role: String
    let log_kind: String?
    /// Raw jsonb — different log_kinds use different shapes (recall →
    /// RecallPayload; permission_request → PermissionRequestPayload).
    /// Re-decoded lazily per row instead of forcing one column-level schema.
    let log_payload: AnyJSON?
    /// `{ ids: [uuid, ...] }` — see apps/edge/src/routes/messages.ts upsert.
    let attachments: AttachmentRef?
    let content: String?
    let status: String?
    let created_at: String
    let message_seq: Int?
    let citations: [MessageCitation]?
    let metadata: AnyJSON?
    // Arena: link a bot answer to its prompt + identify the answer + record its
    // model, for the inline blind A/B compare.
    let parent_message_id: String?
    let bubble_group_id: String?
    let model_slug: String?
}

enum MessagesFetch {
    private static let columns =
        "id, client_message_id, conversation_id, user_id, sender_bot_id, role, log_kind, log_payload, attachments, content, status, created_at, message_seq, citations, metadata, parent_message_id, bubble_group_id, model_slug"

    /// Latest `limit` messages for a conversation, returned chronological
    /// (oldest→newest). RLS gates participation.
    static func latest(conversationId: String, limit: Int = 200) async throws -> [MessageRow] {
        // ── Edge-first (T2.1 read-offload) ──────────────────────────────
        // Try the CF conv-projection tail (GET /v1/messages/tail). The DO
        // already returns rows oldest→newest (it `.reverse()`s its DESC page),
        // so `mapMessageRows` yields the same chronological order this function
        // contracts. On ANY error — or a suspicious-empty full fetch — fall
        // through to the canonical Supabase query (worst case = today's read).
        do {
            let edge = try await APIClient().fetchMessageTailFromEdge(conversationId: conversationId, limit: limit)
            let mapped = EdgeReadSource.mapMessageRows(edge.rows, conversationId: conversationId)
            if !mapped.isEmpty {
                return mapped
            }
            // An empty tail is possible for a brand-new empty conversation, but
            // it's also what a cold/partial projection returns — fall back to
            // Supabase to disambiguate rather than render a blank thread.
        } catch {
            // Best-effort log; the Supabase path below is the safety net.
        }

        // ── Supabase fallback (canonical, unchanged) ────────────────────
        let rowsDesc: [MessageRow] = try await SupabaseStack.shared
            .from("messages")
            .select(columns)
            .eq("conversation_id", value: conversationId)
            .order("message_seq", ascending: false)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return Array(rowsDesc.reversed())
    }

    /// Resolve attachment ids → `Attachment` metadata (mime + filename) from the
    /// `attachments` table. RLS is uploader-only: a peer's file in a user_user
    /// conv won't resolve and is simply omitted. `url` is the auth-gated
    /// `/v1/uploads/<id>` path `ServerImage` fetches.
    static func attachmentMeta(ids: [String]) async throws -> [String: Attachment] {
        guard !ids.isEmpty else { return [:] }
        struct MetaRow: Decodable {
            let id: String
            let mime_type: String
            let filename: String?
            let byte_size: Int?
        }
        let rows: [MetaRow] = try await SupabaseStack.shared
            .from("attachments")
            .select("id, mime_type, filename, byte_size")
            .in("id", values: ids)
            .execute()
            .value
        var meta: [String: Attachment] = [:]
        for r in rows {
            let isImage = r.mime_type.lowercased().hasPrefix("image/")
            meta[r.id] = Attachment(
                id: r.id, kind: isImage ? "image" : "file",
                mime: r.mime_type, size: r.byte_size,
                width: nil, height: nil,
                url: "/v1/uploads/\(r.id)", filename: r.filename
            )
        }
        return meta
    }
}
