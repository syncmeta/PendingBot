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
        // ── Edge-first (T2.1 read-offload) ──────────────────────────────
        // Try the CF edge projection (GET /v1/conversations) and map its
        // scalar rows back into ConvListRow (bot/peer embed re-hydrated from
        // the local cache by EdgeReadSource.mapConversationRows). On ANY
        // error — or a suspicious-empty full fetch (rows == []) — fall through
        // to the canonical Supabase query below. Worst case = today's
        // behaviour; the app never regresses on an edge hiccup.
        do {
            let edge = try await APIClient().fetchConversationsFromEdge()
            // 占位行闸(fail-loud)。`type == "unknown"` 是投影自己的最小行标
            // 记:`conversation_participants` 的写穿在成员加入时先建一行只有
            // conv_id + 加入时间的空壳,标题 / bot_id / 预览全空,等
            // `conversations` 行的写穿随后补全(见 edge 的
            // lib/projection-writethrough.ts `projectParticipant`)。补全没到
            // 时这行会**永久**停在空壳态,而客户端若照单全收,就把一次投影
            // 缺口放大成永久错误显示 —— 列表读「新对话 / 还没有消息 / 名字
            // 胶囊 —」、会话头部读「未命名」,且刷新多少次都不会变
            // (2026-08-19 线上就是这个状态:`conversations` 的 webhook 触发器
            // 从未建过,`user_unread_counts` 的在 20260529043410 被删)。
            // 判据只认服务端自己写下的那个 `unknown` —— 不用「标题空就回落」
            // 这类启发式,那会误伤真·还没起名的会话。
            //
            // 闸是**按行**的:占位行走正典查询补齐,其余行照常吃投影。整张表
            // 回落会把读卸载白白关掉,而投影本身是对的设计,坏的只是喂养通道。
            let placeholderIds = edge.rows.filter { $0.type == "unknown" }.map(\.conv_id)
            let healthy = edge.rows.filter { $0.type != "unknown" }
            if !placeholderIds.isEmpty {
                log.warning("edge conversations projection returned \(placeholderIds.count, privacy: .public) placeholder row(s) of \(edge.rows.count, privacy: .public) — repairing those rows from Supabase")
                let mapped = await EdgeReadSource.mapConversationRows(healthy)
                // 补齐失败(网络/RLS/`!inner` 把无未读行的会话滤掉)时保留投影
                // 那份空壳,宁可画得难看也不让会话整条消失。
                let repaired = (try? await supabaseList(ids: placeholderIds)) ?? []
                let repairedIds = Set(repaired.map(\.id))
                let unrepaired = await EdgeReadSource.mapConversationRows(
                    edge.rows.filter { $0.type == "unknown" && !repairedIds.contains($0.conv_id) }
                )
                if repaired.count < placeholderIds.count {
                    log.warning("repaired only \(repaired.count, privacy: .public)/\(placeholderIds.count, privacy: .public) placeholder row(s); the rest keep the projection stub")
                }
                let merged = mapped + repaired + unrepaired
                if !merged.isEmpty {
                    // 投影按 updated_at desc / id asc 服务端排序,补齐的行是另一
                    // 次查询的结果,合并后重排回同一序(与正典查询的 order 一致)。
                    return merged.sorted { l, r in
                        let (a, b) = (l.asConversation, r.asConversation)
                        if a.last_activity_at != b.last_activity_at {
                            return a.last_activity_at > b.last_activity_at
                        }
                        return a.id < b.id
                    }
                }
            } else {
                let mapped = await EdgeReadSource.mapConversationRows(edge.rows)
                if !mapped.isEmpty {
                    return mapped
                }
                // Empty full fetch is suspicious (a logged-in user normally has
                // at least one conv); fall back to Supabase to confirm rather
                // than paint a blank list on a cold/partial projection.
            }
        } catch {
            log.warning("edge conversations fetch failed, falling back to Supabase: \(error.localizedDescription, privacy: .public)")
        }

        // ── Supabase fallback (canonical, unchanged) ────────────────────
        return try await supabaseList(ids: nil)
    }

    /// 正典 Supabase 查询。`ids == nil` = 整张列表(冷路径全量回落);给了
    /// ids 则只补那几条(占位行的按行修补),查询形状完全一致,只多一个
    /// `in("id", …)` —— 免得两处手抄同一份 select 再漂移。
    private static func supabaseList(ids: [String]?) async throws -> [ConvListRow] {
        var query = SupabaseStack.shared
            .from("conversations")
            .select("""
                id, bot_id, user_id, title, conversation_type, feature, round_count, updated_at,
                bot:bots!conversations_bot_id_fkey(display_name, model_id, visibility, creator_id),
                unread:user_unread_counts!inner(last_message_id, last_message_at, last_message_preview, unread_count),
                participants:conversation_participants(participant_type, participant_id)
            """)
            .neq("conversation_type", value: "subagent")
        if let ids, !ids.isEmpty {
            query = query.in("id", values: ids)
        }
        return try await query
            .order("updated_at", ascending: false)
            .order("id", ascending: true)
            .execute()
            .value
    }
}
