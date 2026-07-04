import Foundation
import Supabase

// ─────────────────────────────────────────────────────────────────────
// MARK: - Cross-platform chat data source
//
// A minimal, gate-free read/send surface for the conversation list + 1:1 text
// chat. The same `MessageTabView` / `ConversationView` are shared across all
// three platforms (iOS / iPad / macOS), and this data source is the cache +
// query layer those shared views call into.
//
// It mirrors the Supabase queries, reuses the verified `ChatStream` SSE for
// sending, and is cache-first on top of `LocalDatabase`: `cachedConversations`
// / `cachedMessages` paint last-known state instantly, and `listConversations`
// / `loadMessages` write the authoritative set back into the shared GRDB cache
// (single cache, no per-platform table).
//
// 时间戳规避: the queries intentionally DON'T `select` any timestamptz column
// (updated_at / created_at). `order(...)` still sorts on them server-side; the
// client just renders in returned order. This sidesteps the Decodable
// String-vs-Int-vs-Date ambiguity that would otherwise fail the whole decode.
// ─────────────────────────────────────────────────────────────────────

/// One group participant resolved for the macOS group-chat sender header
/// (name + avatar above each non-self bubble). Cross-platform mirror of
/// iOS's `GroupBubbleSender` (BubbleView.swift, iOS-only), keyed in the
/// `ChatDataSource.loadGroupSenders` map by `"\(kind):\(id)"`.
struct ChatGroupSender: Equatable, Hashable {
    /// `"bot"` or `"user"` — matches the `senderType` on `ChatMessageRow`.
    let kind: String
    let id: String
    let displayName: String
    /// Uploaded avatar path (`/v1/uploads/<id>`) when the user set one; nil for
    /// bots and avatar-less users → fall back to the deterministic emoji avatar.
    let avatarPath: String?
    /// Deterministic-avatar seed (user's avatar_seed, else id).
    let avatarSeed: String
}

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
    /// Auth-gated `ServerImage` paths (`/v1/uploads/<id>`) for image attachments
    /// on this message. Empty for text-only rows.
    var imagePaths: [String] = []
    /// Non-image attachments (PDF / file …) rendered as icon+name chips.
    var fileAttachments: [Attachment] = []
    /// `bot` / `user` — who sent this row, for group sender-header resolution.
    /// Derived from which of `sender_bot_id` / `user_id` is populated (matches
    /// iOS's `groupSenderFor` switch on `sender_type`). Empty for system rows.
    var senderType: String = ""
    /// The bot id (for `bot` rows) or user id (for `user` rows) — the lookup
    /// key into `ChatDataSource.loadGroupSenders`'s `"\(type):\(id)"` map.
    var senderId: String = ""

    /// Right-aligned (mine) only for human-sent rows.
    var isMine: Bool { role == "user" }
    /// Left-aligned bot reply.
    var isBot: Bool { role == "assistant" || role == "bot" }
    /// Tool-trace / control rows that aren't conversational bubbles — hidden.
    var isHidden: Bool { role == "log" }
}

enum ChatDataSource {
    // MARK: conversation list

    /// Cache-first conversation list — read the last-known rows out of the
    /// shared `LocalDatabase` GRDB cache (the SAME table iOS's `MessageTabView`
    /// hydrates from) so the macOS 消息 tab paints instantly on entry, before
    /// any network round-trip. Mirrors iOS's first-paint hydrate in
    /// `MessageTabView.load()`; the network `listConversations()` then
    /// overwrites with the authoritative set and refreshes the cache.
    @MainActor
    static func cachedConversations() -> [ChatConversationSummary] {
        LocalDatabase.shared.loadConversations().map { row in
            let title = [row.title, row.bot_name]
                .compactMap { $0 }
                .first { !$0.isEmpty } ?? "未命名"
            let preview = (row.last_message_content ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            // The cache row carries no unread count (that's owned by the
            // server-truth unread store on iOS, not the conversations table),
            // so a cached-only paint shows no badge until the network refresh
            // lands a beat later — same settle as the preview / order.
            return ChatConversationSummary(
                id: row.id,
                title: title,
                preview: preview,
                conversationType: row.conversation_type,
                unreadCount: 0
            )
        }
    }

    /// Raw cached conversation rows (bot_id / last_activity_at / type intact),
    /// for callers that need columns the thin `ChatConversationSummary` drops —
    /// e.g. the friends tab seeds its "按最近聊天" sort key from the cached
    /// bot_id → last_activity_at map. Keeps the single cache-read seam: the
    /// friends tab no longer reaches into `LocalDatabase` directly.
    @MainActor
    static func cachedConversationRows() -> [LocalDatabase.ConversationRow] {
        LocalDatabase.shared.loadConversations()
    }

    /// The conversation list (most-recent first), projected to a thin summary.
    /// Runs the SAME query as iOS's `MessageTabView.load()` via the shared
    /// `ConversationFetch.list()` — no hand-copied query here anymore — and just
    /// keeps the columns the macOS list renders (title / preview / unread).
    /// After a successful fetch, reconciles the shared `LocalDatabase` cache
    /// (same `upsertConversations` iOS uses) so the next entry paints from
    /// cache instantly.
    static func listConversations() async throws -> [ChatConversationSummary] {
        let rows = try await ConversationFetch.list()
        let summaries: [ChatConversationSummary] = rows.map { row in
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
        // Reconcile the cache with the authoritative list, mirroring iOS's
        // `LocalDatabase.shared.upsertConversations(...)` in `MessageTabView`.
        // `asConversation` collapses each row exactly as iOS does, so the
        // cached preview / activity time / bot name agree across platforms.
        let cacheRows: [LocalDatabase.ConversationRow] = rows.map { row in
            let c = row.asConversation
            return LocalDatabase.ConversationRow(
                id: c.id,
                bot_id: c.bot_id.isEmpty ? nil : c.bot_id,
                user_id: c.user_id.isEmpty ? nil : c.user_id,
                title: c.title,
                conversation_type: c.conversation_type,
                feature: c.feature_type,
                round_count: c.round_count,
                last_activity_at: c.last_activity_at,
                bot_name: c.bot_name,
                last_message_content: c.last_message_content,
                last_message_sender_type: c.last_message_sender_type
            )
        }
        await MainActor.run {
            LocalDatabase.shared.upsertConversations(cacheRows)
        }
        return summaries
    }

    // MARK: message history

    /// Cache-first message hydrate — read the conversation's last-known rows out
    /// of the shared `LocalDatabase` GRDB cache (the SAME table iOS's
    /// `ConversationView.loadHistory()` writes back to) so the chat opens with
    /// content on the first frame, even offline, before any network round-trip.
    /// Mirrors iOS's `loadHistory` cache hydrate. Attachments aren't cached
    /// (no columns for them), so cached rows are text-only until the network
    /// `loadMessages()` reload resolves attachment metadata — same as iOS, whose
    /// cache hydrate builds rows with `attachments: nil`.
    @MainActor
    static func cachedMessages(conversationId: String, limit: Int = 200) -> [ChatMessageRow] {
        LocalDatabase.shared.loadMessages(conversationId: conversationId, limit: limit)
            .map { r in
                // The cache stores `role` as `bot` / `user` and the populated
                // sender id — rebuild the same sender resolution the network
                // path produces so group bubble headers paint from cache too.
                let senderType: String
                let senderId: String
                if let botId = r.sender_bot_id, !botId.isEmpty {
                    senderType = "bot"; senderId = botId
                } else if let uid = r.user_id, !uid.isEmpty {
                    senderType = "user"; senderId = uid
                } else {
                    senderType = ""; senderId = ""
                }
                return ChatMessageRow(
                    id: r.id,
                    role: r.role,
                    content: r.content ?? "",
                    seq: r.message_seq,
                    senderType: senderType,
                    senderId: senderId
                )
            }
    }

    /// Messages for one conversation, oldest→newest, via the shared
    /// `MessagesFetch.latest()` (same query as iOS). Filters the rows iOS's
    /// dispatch also drops — soft-deleted, voice-call recaps, and `log`
    /// tool-trace/control rows (macOS doesn't render those yet) — and resolves
    /// image attachments into `ServerImage` paths. After a successful fetch,
    /// reconciles the shared `LocalDatabase` cache in one atomic transaction
    /// (same `replaceMessages` cmid-aware upsert iOS's `loadHistory` uses) so
    /// the next open hydrates from cache instantly.
    static func loadMessages(conversationId: String, limit: Int = 200) async throws -> [ChatMessageRow] {
        let rows = try await MessagesFetch.latest(conversationId: conversationId, limit: limit)

        // Resolve attachment metadata once for the whole page.
        let allIds = Array(Set(rows.flatMap { $0.attachments?.ids ?? [] }))
        let meta = (try? await MessagesFetch.attachmentMeta(ids: allIds)) ?? [:]

        var cacheRows: [LocalDatabase.MessageRow] = []
        cacheRows.reserveCapacity(rows.count)
        let viewRows = rows.compactMap { r -> ChatMessageRow? in
            if r.status == "deleted" { return nil }
            if r.metadata?.objectValue?["source"]?.stringValue == "voice_call_summary" { return nil }
            if r.role == "log" { return nil }
            let resolved = (r.attachments?.ids ?? []).compactMap { meta[$0] }
            let imagePaths = resolved.filter { $0.isImage }.map(\.url)
            let files = resolved.filter { !$0.isImage }
            // Sender resolution for group bubble headers. The `messages` row
            // populates `sender_bot_id` for bot rows and `user_id` for human
            // rows — mirror iOS's `groupSenderFor` switch via the populated id.
            let senderType: String
            let senderId: String
            if let botId = r.sender_bot_id, !botId.isEmpty {
                senderType = "bot"; senderId = botId
            } else if let uid = r.user_id, !uid.isEmpty {
                senderType = "user"; senderId = uid
            } else {
                senderType = ""; senderId = ""
            }
            // Mirror iOS loadHistory's cache policy: only the real bot/user
            // bubbles we render belong in the cache (log / deleted / voice
            // recaps are already filtered out above). Map to the same
            // `LocalDatabase.MessageRow` shape iOS persists.
            cacheRows.append(LocalDatabase.MessageRow(
                id: r.id,
                client_message_id: r.client_message_id,
                conversation_id: r.conversation_id,
                user_id: r.user_id,
                sender_bot_id: r.sender_bot_id,
                role: r.role,
                content: r.content ?? "",
                status: r.status,
                created_at: ServerTimestamp.epochSeconds(r.created_at, default: 0),
                message_seq: r.message_seq,
                parent_message_id: r.parent_message_id,
                bubble_group_id: r.bubble_group_id,
                model_slug: r.model_slug
            ))
            return ChatMessageRow(
                id: r.id,
                role: r.role,
                content: r.content ?? "",
                seq: r.message_seq,
                imagePaths: imagePaths,
                fileAttachments: files,
                senderType: senderType,
                senderId: senderId
            )
        }
        // Reconcile the cache atomically (delete-then-insert in one txn) so the
        // cache exactly mirrors the server view with no empty/partial window —
        // identical contract to iOS's `LocalDatabase.shared.replaceMessages`.
        await MainActor.run {
            LocalDatabase.shared.replaceMessages(conversationId: conversationId, cacheRows)
        }
        return viewRows
    }

    // MARK: - 共享写穿门面(T2 — 三端缓存写路径统一)
    //
    // 视图层的实时/流式/列表增量缓存写,原本各自直接 `LocalDatabase.shared.*`
    // (iOS Features/Message/ 5 处)。收口成这道共享缝,让 iOS/iPad 与 Mac 都经
    // 同一门面(对齐 `CacheRepository` 对 bots/contacts/group 的做法)。
    // **语义不变**:cmid-aware 单事务(#145)+ upsert(#146)逻辑都在
    // `LocalDatabase` 方法里,这里只是薄委托;调用方构造的正典 Row 一字不动。
    //   - persistMessages = 整会话原子替换(delete-then-insert in one txn)。
    //   - mergeMessages   = 增量 cmid-aware upsert(实时/流式回合)。
    //   - mergeConversations = 会话列表增量 upsert。

    @MainActor
    static func persistMessages(conversationId: String, _ rows: [LocalDatabase.MessageRow]) {
        LocalDatabase.shared.replaceMessages(conversationId: conversationId, rows)
    }

    @MainActor
    static func mergeMessages(_ rows: [LocalDatabase.MessageRow]) {
        LocalDatabase.shared.upsertMessages(rows)
    }

    @MainActor
    static func mergeConversations(_ rows: [LocalDatabase.ConversationRow]) {
        LocalDatabase.shared.upsertConversations(rows)
    }

    // MARK: conversation type

    /// Resolve a single conversation's `conversation_type` (`user_bot` / `self`
    /// / `user_user` / `group`). The chat view needs this to choose its send
    /// path — bot/self/group POST `/v1/messages`, user_user INSERTs directly —
    /// and whether to paint per-bubble sender headers. RLS gates participation.
    static func conversationType(conversationId: String) async throws -> String? {
        struct Row: Decodable { let conversation_type: String? }
        let rows: [Row] = try await SupabaseStack.shared
            .from("conversations")
            .select("conversation_type")
            .eq("id", value: conversationId)
            .limit(1)
            .execute()
            .value
        return rows.first?.conversation_type
    }

    // MARK: group senders

    /// Resolve the group's participants → name + avatar lookup, keyed
    /// `"\(kind):\(id)"` to match `ChatMessageRow.senderType`/`senderId`.
    /// Cross-platform mirror of iOS's `loadGroupSendersIfNeeded`: bots resolve
    /// from `bots`, users go through the worker (`/v1/contacts/profiles`)
    /// because `pendingbot.users` RLS is self-only — a direct query returns
    /// only the caller's row, so everyone else's name would fall back to an
    /// id prefix. Returns empty on any failure (bubbles fall back to seed avatars).
    static func loadGroupSenders(conversationId: String) async -> [String: ChatGroupSender] {
        struct PartRow: Decodable {
            let participant_type: String
            let participant_id: String
            let nickname: String?
        }
        do {
            let parts: [PartRow] = try await SupabaseStack.shared
                .from("conversation_participants")
                .select("participant_type, participant_id, nickname")
                .eq("conversation_id", value: conversationId)
                .execute()
                .value

            let botIds = parts.filter { $0.participant_type == "bot" }.map(\.participant_id)
            let userIds = parts.filter { $0.participant_type == "user" }.map(\.participant_id)

            struct BotRow: Decodable { let id: String; let display_name: String }
            let bots: [BotRow] = botIds.isEmpty ? [] : try await SupabaseStack.shared
                .from("bots").select("id, display_name").in("id", values: botIds)
                .execute().value
            let botMap = Dictionary(uniqueKeysWithValues: bots.map { ($0.id, $0.display_name) })

            let userMap = await fetchGroupMemberProfiles(
                conversationId: conversationId, userIds: userIds)

            var lookup: [String: ChatGroupSender] = [:]
            for p in parts {
                let key = "\(p.participant_type):\(p.participant_id)"
                let isBot = p.participant_type == "bot"
                let resolvedName: String = {
                    if isBot { return botMap[p.participant_id] ?? "未知机器人" }
                    let name = userMap[p.participant_id]?.0 ?? ""
                    return name.isEmpty ? String(p.participant_id.prefix(8)) : name
                }()
                let nick = p.nickname?.trimmingCharacters(in: .whitespaces)
                let display = (nick?.isEmpty == false ? nick! : resolvedName)
                let info = isBot ? nil : userMap[p.participant_id]
                lookup[key] = ChatGroupSender(
                    kind: p.participant_type,
                    id: p.participant_id,
                    displayName: display,
                    avatarPath: info?.1,
                    avatarSeed: info?.2 ?? p.participant_id
                )
            }
            return lookup
        } catch {
            return [:]
        }
    }

    /// Bulk profile lookup through the worker (service-role) — cross-platform
    /// mirror of iOS `fetchGroupMemberProfiles`. Returns id → (name, avatarPath, seed).
    private static func fetchGroupMemberProfiles(
        conversationId: String, userIds: [String]
    ) async -> [String: (String, String?, String)] {
        guard !userIds.isEmpty else { return [:] }
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/contacts/profiles")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "conversationId": conversationId,
                "userIds": userIds,
            ])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return [:]
            }
            struct Payload: Decodable {
                struct Row: Decodable {
                    let userId: String
                    let displayName: String
                    let avatarPath: String?
                    let avatarSeed: String?
                }
                let profiles: [Row]
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return Dictionary(uniqueKeysWithValues: payload.profiles.map {
                ($0.userId, ($0.displayName, $0.avatarPath, $0.avatarSeed ?? $0.userId))
            })
        } catch {
            return [:]
        }
    }

    // MARK: attachment upload

    /// Single-file upload cap — mirrors MAX_UPLOAD_BYTES on the edge worker and
    /// iOS's `maxUploadBytes`. Pre-checked client-side for a friendlier message
    /// than the server's 413.
    static let maxUploadBytes = 25 * 1024 * 1024

    /// Upload one local file to `/v1/upload` (reuses the cross-platform
    /// `APIClient.upload` multipart call iOS uses). Returns the canonical
    /// `Attachment` (id / mime / size / filename) the composer holds until send.
    /// `conversationId` rides along as iOS does so the worker scopes the blob.
    static func upload(
        conversationId: String, data: Data, filename: String, mime: String
    ) async throws -> Attachment {
        let response: UploadResponse = try await APIClient().upload(
            "v1/upload",
            fileData: data,
            fileName: filename,
            mime: mime,
            extraFields: ["conversationId": conversationId]
        )
        return Attachment(
            id: response.id,
            kind: response.mime.lowercased().hasPrefix("image/") ? "image" : "file",
            mime: response.mime,
            size: response.size,
            width: response.width,
            height: response.height,
            url: "/v1/uploads/\(response.id)",
            filename: response.filename ?? filename
        )
    }

    // MARK: send

    /// Send a user text message (+ optional attachment ids) and stream the bot
    /// reply. Reuses the verified `ChatStream` SSE wire format — used for
    /// `user_bot` / `self` / `group` convs (worker handles all three; group bot
    /// replies also arrive via Realtime). Caller iterates the events
    /// (connected / token / bubble / done / error) and updates its bubble list.
    static func sendMessage(
        conversationId: String, text: String, attachmentIds: [String] = []
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        var body: [String: Any] = [
            "clientMessageId": UUID().uuidString,
            "conversationId": conversationId,
        ]
        if !text.isEmpty { body["newMessage"] = text }
        if !attachmentIds.isEmpty { body["attachmentIds"] = attachmentIds }
        return ChatStream().send(body: body, path: "v1/messages")
    }

    /// Send a `user_user` (1:1 human) message. These INSERT straight into
    /// Supabase (no worker, no SSE) — mirror of iOS's `sendUserUserMessage`.
    /// The attachment ids must be written into the `attachments` jsonb here so
    /// the canonical Realtime row (which the peer and our own reload pick up)
    /// carries them. Throws on failure so the caller can surface the error.
    static func sendPeerMessage(
        conversationId: String, text: String, attachmentIds: [String] = []
    ) async throws {
        guard let userId = await AccountStore.shared.current?.id else {
            throw APIError.unauthorized
        }
        struct AttachmentIds: Encodable { let ids: [String] }
        struct Insert: Encodable {
            let client_message_id: String
            let conversation_id: String
            let user_id: String
            let role = "user"
            let status = "done"
            let content: String
            let attachments: AttachmentIds?
        }
        try await SupabaseStack.authedClient()
            .from("messages")
            .insert(Insert(
                client_message_id: UUID().uuidString,
                conversation_id: conversationId,
                user_id: userId,
                content: text,
                attachments: attachmentIds.isEmpty ? nil : AttachmentIds(ids: attachmentIds)
            ))
            .execute()
    }
}
