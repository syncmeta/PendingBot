import Foundation
import Supabase
import OSLog

private let log = Logger.category("edge-read")

// ─────────────────────────────────────────────────────────────────────
// MARK: - Edge read layer (T2.1 — conversation list + message tail via投影)
//
// The read-offload seam: mirrors the CF edge projection endpoints
//   GET /v1/conversations            → UserListResult
//   GET /v1/messages/tail?conv=…      → ConvTailResult
// (shapes defined in apps/edge/src/durable-objects/{user,conv}-projection.ts)
// and maps their rows back into the EXACT same `ConvListRow` / `MessageRow`
// types the canonical Supabase fetches (`ConversationFetch.list` /
// `MessagesFetch.latest`) return — so every caller (the cmid-aware /
// !inner-filtered / diff / prefetch views) stays byte-for-byte unchanged.
//
// This file is read-only plumbing: it does NOT touch ConversationFetch /
// MessagesFetch / ChatDataSource / the views. Y2 wires the cutover (try edge,
// fall back to Supabase on any error or suspicious-empty full fetch).
//
// ── Why mapping, not new view types (iron rule) ──────────────────────
// The edge list row carries only **scalar** conversation columns — no bot /
// peer embed (avatar / name). The edge维护 doc is explicit: de-normalizing the
// bot/peer embed into every conv row would force a fan-out on bot rename. So
// `mapConversationRows` re-hydrates the embed from the local GRDB cache
// (CacheRepository.cachedBots / cachedContacts). A cache miss leaves the embed
// empty — identical to the iron-rule "命中不到就留空,下次刷新补".
// ─────────────────────────────────────────────────────────────────────

// MARK: - Edge wire mirrors

/// Swift mirror of UserListResult (user-projection.ts). `epoch` is a string,
/// `rev` an Int (the DO's monotonic cursor); `full=true` ⇒ caller should treat
/// `rows` as a wholesale replacement (cursor invalid / cold rebuild).
struct UserListResult: Decodable {
    let epoch: String
    let rev: Int
    let rows: [UserConversationRow]
    let full: Bool
}

/// Swift mirror of UserConversationRow (user-projection.ts). Scalar conv
/// columns only — **no** bot/peer embed; that's hydrated locally.
struct UserConversationRow: Decodable {
    let conv_id: String
    let type: String
    let bot_id: String?
    let user_id: String?
    let feature: String?
    let round_count: Int?
    let title: String?
    let last_msg_preview: String?
    let updated_at: String
    let unread: Int
    let rev: Int
}

/// Swift mirror of ConvTailResult (conv-projection.ts). `tombstones` are ids of
/// deleted messages (delta callers prune them); on a full fetch it's empty.
struct ConvTailResult: Decodable {
    let epoch: String
    let rev: Int
    let rows: [ConvMessageRow]
    let tombstones: [String]
    let full: Bool
}

/// Swift mirror of ConvMessageRow (conv-projection.ts). The four rich JSON
/// columns (`attachments` / `citations` / `metadata` / `log_payload`) decode as
/// `AnyJSON?` — the same raw-JSON carrier `MessageRow` already uses — so the
/// `{ "__truncated": true }` 护栏 marker survives decode and is detected during
/// mapping (→ treated as nil/empty per the spec).
struct ConvMessageRow: Decodable {
    let id: String
    let client_message_id: String?
    let created_at: String
    let message_seq: Int?
    let role: String
    let status: String
    let content: String
    let log_kind: String?
    let log_payload: AnyJSON?
    let bubble_group_id: String?
    let parent_message_id: String?
    let model_slug: String?
    let sender_user_id: String?
    let sender_bot_id: String?
    let attachments: AnyJSON?
    let citations: AnyJSON?
    let metadata: AnyJSON?
    let rev: Int
}

// MARK: - APIClient edge-read methods

extension APIClient {
    /// GET /v1/conversations — the caller's own USER_PROJECTION list + unread.
    /// Y1 always full-fetches (`since=0`); delta cursor is a later phase.
    func fetchConversationsFromEdge() async throws -> UserListResult {
        try await get("/v1/conversations", query: [
            URLQueryItem(name: "since", value: "0"),
        ])
    }

    /// GET /v1/messages/tail — latest `limit` messages for one conversation,
    /// returned newest→oldest by the DO (mapping flips to chronological to
    /// match `MessagesFetch.latest`). Full-fetch (`since=0`).
    func fetchMessageTailFromEdge(conversationId: String, limit: Int = 200) async throws -> ConvTailResult {
        try await get("/v1/messages/tail", query: [
            URLQueryItem(name: "conv", value: conversationId),
            URLQueryItem(name: "since", value: "0"),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }
}

// MARK: - Mapping: edge rows → canonical fetch row types

enum EdgeReadSource {
    /// `{ "__truncated": true }` 护栏 marker — a rich JSON column the 2MB row
    /// guard dropped. Returns the original value when NOT truncated, or nil so
    /// the caller treats the field as absent (per spec: lazy full-row re-fetch
    /// is a later phase, not Y1).
    private static func untruncated(_ any: AnyJSON?) -> AnyJSON? {
        guard let any else { return nil }
        if case let .object(obj) = any,
           obj.count == 1,
           obj["__truncated"]?.boolValue == true {
            return nil
        }
        return any
    }

    /// AnyJSON → [MessageCitation], mirroring the view-side `parseCitations`
    /// tolerance for the literal `null` jsonb encoding.
    private static func decodeCitations(_ any: AnyJSON?) -> [MessageCitation]? {
        guard let any else { return nil }
        do {
            let data = try JSONEncoder().encode(any)
            if data.count == 4, String(data: data, encoding: .utf8) == "null" {
                return nil
            }
            return try JSONDecoder().decode([MessageCitation].self, from: data)
        } catch {
            return nil
        }
    }

    /// AnyJSON → AttachmentRef (`{ ids: [...] }`), tolerating the literal
    /// `null` encoding the array/object decoder would otherwise reject.
    private static func decodeAttachments(_ any: AnyJSON?) -> AttachmentRef? {
        guard let any else { return nil }
        do {
            let data = try JSONEncoder().encode(any)
            if data.count == 4, String(data: data, encoding: .utf8) == "null" {
                return nil
            }
            return try JSONDecoder().decode(AttachmentRef.self, from: data)
        } catch {
            return nil
        }
    }

    /// Map edge conversation rows into the canonical `ConvListRow` shape.
    ///
    /// Scalar columns map straight across. The bot/peer embed is re-hydrated
    /// from the local GRDB cache:
    ///   - `bot_id` hit  → `bot` join filled from `CacheRepository.cachedBots()`.
    ///   - `user_user` peer → a single `participants` entry synthesised from the
    ///     conv's own `user_id`, so the view's existing peer-resolution
    ///     (`participants.first { type == user && id != myId }`) works unchanged.
    ///     The contact name itself is resolved view-side from `cachedContacts()`
    ///     keyed by that id, exactly as on the Supabase path.
    /// A miss on either side leaves the embed empty — the next refresh fills it
    /// (iron rule: 命中不到就留空).
    @MainActor
    static func mapConversationRows(_ edge: [UserConversationRow]) -> [ConvListRow] {
        let botsById = Dictionary(
            CacheRepository.cachedBots().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return edge.map { row in
            let botJoin: ConvListRow.BotJoin? = {
                guard let bid = row.bot_id, let b = botsById[bid] else { return nil }
                return ConvListRow.BotJoin(
                    display_name: b.display_name,
                    model_id: b.model_id,
                    visibility: b.visibility,
                    creator_id: b.creator_id
                )
            }()

            // Synthesise the participants embed the view reads for user_user
            // peer resolution. The edge row exposes only the conv's own
            // `user_id`; for a user_user conv that's one of the two members, so
            // one synthetic participant lets the downstream `!= myId` filter
            // pick the peer when `user_id` is the peer. When `user_id == myId`
            // the filter yields nil and the row paints peerless until the next
            // (Supabase-hydrated) refresh — the accepted hydration gap.
            let participants: [ConvListRow.ParticipantJoin]? = {
                guard row.type == "user_user", let uid = row.user_id, !uid.isEmpty else { return nil }
                return [ConvListRow.ParticipantJoin(participant_type: "user", participant_id: uid)]
            }()

            let unreadJoin = ConvListRow.UnreadJoin(
                last_message_id: nil,
                last_message_at: row.updated_at,
                last_message_preview: row.last_msg_preview,
                unread_count: row.unread
            )

            return ConvListRow(
                id: row.conv_id,
                bot_id: row.bot_id,
                user_id: row.user_id,
                title: row.title,
                conversation_type: row.type,
                feature: row.feature,
                round_count: row.round_count,
                updated_at: row.updated_at,
                bot: botJoin,
                unread: [unreadJoin],
                participants: participants
            )
        }
    }

    /// Map edge message rows into the canonical `MessageRow` shape (the full
    /// superset iOS / macOS render). The four rich JSON columns are de-truncated
    /// first (护栏 marker → nil), then decoded into MessageRow's typed carriers:
    /// `citations` → `[MessageCitation]?`, `attachments` → `AttachmentRef?`,
    /// `metadata` / `log_payload` → `AnyJSON?` (re-decoded lazily per row by the
    /// view dispatch). `conversation_id` is stamped from the caller (the edge row
    /// omits it — the tail is已 per-conv).
    static func mapMessageRows(_ edge: [ConvMessageRow], conversationId: String) -> [MessageRow] {
        edge.map { row in
            MessageRow(
                id: row.id,
                client_message_id: row.client_message_id,
                conversation_id: conversationId,
                user_id: row.sender_user_id,
                sender_bot_id: row.sender_bot_id,
                role: row.role,
                log_kind: row.log_kind,
                log_payload: untruncated(row.log_payload),
                attachments: decodeAttachments(untruncated(row.attachments)),
                content: row.content,
                status: row.status,
                created_at: row.created_at,
                message_seq: row.message_seq,
                citations: decodeCitations(untruncated(row.citations)),
                metadata: untruncated(row.metadata),
                parent_message_id: row.parent_message_id,
                bubble_group_id: row.bubble_group_id,
                model_slug: row.model_slug
            )
        }
    }
}
