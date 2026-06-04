import Foundation
import Supabase

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

    /// Messages for one conversation, oldest→newest, via the shared
    /// `MessagesFetch.latest()` (same query as iOS). Filters the rows iOS's
    /// dispatch also drops — soft-deleted, voice-call recaps, and `log`
    /// tool-trace/control rows (macOS doesn't render those yet) — and resolves
    /// image attachments into `ServerImage` paths.
    static func loadMessages(conversationId: String, limit: Int = 200) async throws -> [ChatMessageRow] {
        let rows = try await MessagesFetch.latest(conversationId: conversationId, limit: limit)

        // Resolve attachment metadata once for the whole page.
        let allIds = Array(Set(rows.flatMap { $0.attachments?.ids ?? [] }))
        let meta = (try? await MessagesFetch.attachmentMeta(ids: allIds)) ?? [:]

        return rows.compactMap { r -> ChatMessageRow? in
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
        try await SupabaseStack.shared
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
