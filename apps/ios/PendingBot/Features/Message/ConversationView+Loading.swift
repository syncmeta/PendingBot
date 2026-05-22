import Foundation
import OSLog
import Supabase

// Pure data-fetch helpers used by ConversationView's .task / .onAppear
// callbacks. Each populates one @State slice (messages, skills, lookbacks,
// peer profile, group senders, freeze gate, pending-continue). Failures
// log via the shared category but never throw at SwiftUI — the view is
// expected to keep its prior state on a network blip.

private let loadingLog = Logger.category("ConversationView.Loading")

extension ConversationView {

    func loadActiveLookbacks() async {
        struct Row: Decodable {
            let id: String
            let body_md: String
            let active: Bool
        }
        do {
            let rows: [Row] = try await SupabaseStack.shared
                .from("bot_lookbacks")
                .select("id, body_md, active")
                .eq("conversation_id", value: conversation.id)
                .eq("active", value: true)
                .order("created_at", ascending: true)
                .execute()
                .value
            self.activeLookbacks = rows.map { LookbackNote(id: $0.id, body_md: $0.body_md, active: true) }
        } catch {
            // Lookbacks are an enhancement — silent fail.
            loadingLog.warning("lookback load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadSkills() async {
        // Skills load left disabled until /v1/skills lands. The chip stays
        // empty; chat is unaffected.
        self.skills = []
    }

    /// Resolve the user_user peer's display name + avatar path so the
    /// header and incoming bubbles read as that person, not "未命名" + a
    /// generic glyph. Skips when we already have a `pendingPeer` (the
    /// friends-tab tap path supplies it eagerly) or when the conv is not
    /// user_user. RLS on `pendingbot.users` is self-only, so we go through
    /// the worker which uses service-role to read the peer row.
    func loadPeerProfileIfNeeded() async {
        guard conversation.conversation_type == "user_user" else { return }
        guard !conversation.id.isEmpty else { return }
        if pendingPeer?.kind == "user" { return }
        if resolvedPeer != nil { return }
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/contacts/conv-peer/\(conversation.id)")
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return }
            struct Payload: Decodable {
                let userId: String
                let displayName: String
                let avatarPath: String?
                let avatarSeed: String?
                let alias: String?
            }
            let p = try JSONDecoder().decode(Payload.self, from: data)
            // Prefer the caller's local alias when set, otherwise the
            // peer's own display name. The avatar uses the server-supplied
            // seed (users.custom_fields.avatar_seed) so it matches what
            // every other viewer of this person renders.
            let name = (p.alias?.isEmpty == false ? p.alias! : p.displayName)
            self.resolvedPeer = ResolvedPeer(
                userId: p.userId,
                displayName: name.isEmpty ? String(p.userId.prefix(8)) : name,
                avatarPath: p.avatarPath,
                avatarSeed: p.avatarSeed ?? p.userId
            )
        } catch {
            // Non-fatal: header just keeps showing the existing fallback
            // until next reopen. Log via the conversation logger so it's
            // not silent in dev.
            loadingLog.warning("conv-peer load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Bulk profile lookup for group members through the worker — same
    /// shape as GroupSettingsView.fetchMemberProfiles. Direct supabase
    /// queries against pendingbot.users hit the self-only RLS policy and
    /// silently return empty for everyone except the caller; the worker
    /// uses service-role and gates on conversation membership.
    func fetchGroupMemberProfiles(
        userIds: [String]
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
                "conversationId": conversation.id,
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

    /// Group-only — build the per-message sender lookup so each bubble
    /// can show its own avatar + nickname above the content. Pulls
    /// participants once on conv open; new senders that join mid-stream
    /// fall back to the avatar-only render until next conv reopen
    /// (Realtime delta sync for membership is M9 polish).
    /// Paint group avatars + nicknames from the local cache synchronously,
    /// before any network round-trip. Called at the very top of the view's
    /// `.task` (ahead of `loadHistory()`) so the senders land on the first
    /// frame instead of a second later — otherwise this cache read would sit
    /// behind loadHistory's await and the bubbles flash id-prefix labels +
    /// generic glyphs until it returns. Idempotent: skips when `groupSenders`
    /// is already populated, so the network refresh below never re-runs it.
    func hydrateGroupSendersFromCache() {
        guard conversation.conversation_type == "group" else { return }
        guard !conversation.id.isEmpty, groupSenders.isEmpty else { return }
        let cached = LocalDatabase.shared.loadGroupMembers(conversationId: conversation.id)
        guard !cached.isEmpty else { return }
        var lookup: [String: GroupBubbleSender] = [:]
        for r in cached {
            let key = "\(r.participant_type):\(r.participant_id)"
            let nick = r.nickname?.trimmingCharacters(in: .whitespaces)
            let display = (nick?.isEmpty == false ? nick! : r.display_name)
            lookup[key] = GroupBubbleSender(
                kind: r.participant_type == "bot" ? .bot : .user,
                id: r.participant_id,
                displayName: display.isEmpty ? String(r.participant_id.prefix(8)) : display,
                avatarPath: r.avatar_path,
                avatarSeed: r.avatar_seed ?? r.participant_id,
            )
        }
        self.groupSenders = lookup
    }

    func loadGroupSendersIfNeeded() async {
        guard conversation.conversation_type == "group" else { return }
        guard !conversation.id.isEmpty else { return }
        // Cache-first paint (also runs synchronously from `.task` before
        // loadHistory so the first frame is correct); this call covers the
        // path where senders weren't pre-hydrated. The network refresh below
        // then overwrites with the authoritative roster.
        hydrateGroupSendersFromCache()
        let cached = LocalDatabase.shared.loadGroupMembers(conversationId: conversation.id)
        do {
            struct PartRow: Decodable {
                let participant_type: String
                let participant_id: String
                let nickname: String?
                let role: String?
            }
            let parts: [PartRow] = try await SupabaseStack.shared
                .from("conversation_participants")
                .select("participant_type, participant_id, nickname, role")
                .eq("conversation_id", value: conversation.id)
                .execute()
                .value

            let botIds = parts.filter { $0.participant_type == "bot" }
                .map(\.participant_id)
            let userIds = parts.filter { $0.participant_type == "user" }
                .map(\.participant_id)

            struct BotRow: Decodable { let id: String; let display_name: String }

            async let botResp: [BotRow] = botIds.isEmpty ? [] : SupabaseStack.shared
                .from("bots").select("id, display_name").in("id", values: botIds)
                .execute().value
            // pendingbot.users RLS is self-only — a direct query here
            // returns ONLY the caller's row, so every other member's
            // display_name comes back empty and the bubble label falls
            // back to id-prefix. Route through the worker (service-role)
            // so display_name + avatar_path + avatar_seed land for the
            // whole group.
            async let userInfoMap: [String: (String, String?, String)] =
                userIds.isEmpty
                    ? [:]
                    : fetchGroupMemberProfiles(userIds: userIds)

            let botMap = Dictionary(uniqueKeysWithValues:
                (try await botResp).map { ($0.id, $0.display_name) })
            let userMap = await userInfoMap

            // Preserve any frozen flags the settings page previously
            // wrote — chat-side load doesn't query group_member_billing,
            // so without this we'd clobber that bit back to false and
            // the frozen badge would flash off on the next settings
            // open until the next billing-fetch round-trip.
            let priorFrozen: [String: Bool] = Dictionary(uniqueKeysWithValues:
                cached.map { ("\($0.participant_type):\($0.participant_id)", $0.frozen) })
            var lookup: [String: GroupBubbleSender] = [:]
            var cacheRows: [LocalDatabase.GroupMemberRow] = []
            for p in parts {
                let key = "\(p.participant_type):\(p.participant_id)"
                let isBot = p.participant_type == "bot"
                let resolvedName: String = {
                    if isBot {
                        return botMap[p.participant_id] ?? "未知机器人"
                    }
                    let name = userMap[p.participant_id]?.0 ?? ""
                    return name.isEmpty ? String(p.participant_id.prefix(8)) : name
                }()
                let nick = p.nickname?.trimmingCharacters(in: .whitespaces)
                let display = (nick?.isEmpty == false ? nick! : resolvedName)
                let info = isBot ? nil : userMap[p.participant_id]
                let avatarSeed = info?.2 ?? p.participant_id
                lookup[key] = GroupBubbleSender(
                    kind: isBot ? .bot : .user,
                    id: p.participant_id,
                    displayName: display,
                    avatarPath: info?.1,
                    avatarSeed: avatarSeed,
                )
                cacheRows.append(LocalDatabase.GroupMemberRow(
                    conversation_id: conversation.id,
                    participant_type: p.participant_type,
                    participant_id: p.participant_id,
                    nickname: p.nickname,
                    role: p.role,
                    display_name: resolvedName,
                    avatar_path: info?.1,
                    avatar_seed: avatarSeed,
                    frozen: priorFrozen[key] ?? false
                ))
            }
            self.groupSenders = lookup
            LocalDatabase.shared.replaceGroupMembers(
                conversationId: conversation.id, cacheRows)
        } catch {
            loadingLog.warning("group senders load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Group conv only — read the caller's group_member_billing row to
    /// learn whether they've crossed their per-group cap or run out of
    /// wallet balance (migration 0066 unifies both into `overdrawn`).
    /// When true, `frozen_at` carries the wall-clock moment of the flip
    /// — used by `displayedMessages` to hide post-freeze rows and by
    /// `iAmFrozen` to lock the composer + show the banner.
    func loadGroupFreezeIfNeeded() async {
        guard conversation.conversation_type == "group" else { return }
        guard !conversation.id.isEmpty else { return }
        guard let me = AccountStore.shared.current?.id else { return }
        do {
            struct Row: Decodable {
                let overdrawn: Bool
                let frozen_at: String?
            }
            let rows: [Row] = try await SupabaseStack.shared
                .from("group_member_billing")
                .select("overdrawn, frozen_at")
                .eq("conversation_id", value: conversation.id)
                .eq("user_id", value: me)
                .limit(1)
                .execute()
                .value
            if let row = rows.first, row.overdrawn,
               let raw = row.frozen_at, let parsed = ServerTimestamp.parse(raw) {
                self.groupFreezeAt = parsed
            } else {
                self.groupFreezeAt = nil
            }
        } catch {
            loadingLog.warning("group freeze load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Group conv only — pull the most recent pending continue-request
    /// row, if any. Realtime subscription would be nicer but lookback
    /// notes also poll-on-open today, so we follow the same pattern;
    /// continue prompts are infrequent enough that a refresh on open +
    /// after-send is sufficient.
    func loadPendingContinueIfNeeded() async {
        guard conversation.conversation_type == "group" else { return }
        guard !conversation.id.isEmpty else { return }
        do {
            struct Row: Decodable {
                let id: String
                let pending_bot_ids: [String]
            }
            let rows: [Row] = try await SupabaseStack.shared
                .from("group_continue_requests")
                .select("id, pending_bot_ids")
                .eq("conversation_id", value: conversation.id)
                .eq("status", value: "pending")
                .order("requested_at", ascending: false)
                .limit(1)
                .execute()
                .value
            self.pendingContinue = rows.first.map {
                PendingContinue(id: $0.id, pendingBotIds: $0.pending_bot_ids)
            }
        } catch {
            loadingLog.warning("pending continue load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Main history backfill. Hydrates from the local cache first so the
    /// conv opens with last-known content even offline, then overwrites
    /// from the server's authoritative view. Recall tombstones become
    /// synthetic ChatMessages with sender_type="recall_log" (see the
    /// in-line comment on the row mapper). Errors stay silent when the
    /// local cache has at least something to show.
    func loadHistory() async {
        // Hydrate from local cache instantly so the conv opens with last-known
        // content even if the user is offline / on a flaky network.
        let cached = LocalDatabase.shared.loadMessages(conversationId: conversation.id)
        if !cached.isEmpty {
            self.messages = cached.map { r in
                ChatMessage(
                    id: r.id,
                    conversation_id: r.conversation_id,
                    sender_type: r.role == "bot" ? "bot" : "user",
                    sender_id: r.role == "bot" ? (r.sender_bot_id ?? "") : (r.user_id ?? ""),
                    content: r.content ?? "",
                    created_at: r.created_at,
                    attachments: nil
                )
            }
        }

        do {
            // Direct Supabase read — RLS gates participation. Excludes role='log'
            // (review step entries) which are rendered separately.
            struct Row: Decodable {
                let id: String
                let client_message_id: String?
                let conversation_id: String
                let user_id: String?
                let sender_bot_id: String?
                let role: String
                let log_kind: String?
                let log_payload: RecallPayload?
                /// jsonb shape on `messages.attachments`: { ids: [uuid, ...] }
                /// (see apps/edge/src/routes/messages.ts upsert). Captured so
                /// recall can scrub URLCache for the right ids.
                let attachments: AttachmentRef?
                let content: String?
                let status: String?
                let created_at: String
                let citations: [MessageCitation]?
                let metadata: AnyJSON?
                // Arena: link a bot answer to its prompt + identify the answer
                // + record its model, for the inline blind A/B compare.
                let parent_message_id: String?
                let bubble_group_id: String?
                let model_slug: String?
            }
            // Most role='log' rows are server-only (review step entries)
            // and never render. The one exception is log_kind='recall':
            // it's the WeChat-style tombstone the recall flow inserts
            // for user_user convs. We synthesise a ChatMessage with
            // sender_type="recall_log" and stash the original message's
            // created_at in `content` so the row renderer can format
            // "我撤回了 几分钟前 的一条消息" without further look-ups.
            // Fetch the LATEST 200 (descending) then flip to chronological
            // for the ascending timeline. `ascending: true` + limit would
            // pin us to the OLDEST 200 rows and hide recent messages the
            // moment a conversation passes 200 — the user would scroll to
            // "bottom" and land on an ancient message.
            let rowsDesc: [Row] = try await SupabaseStack.shared
                .from("messages")
                .select("id, client_message_id, conversation_id, user_id, sender_bot_id, role, log_kind, log_payload, attachments, content, status, created_at, citations, metadata, parent_message_id, bubble_group_id, model_slug")
                .eq("conversation_id", value: conversation.id)
                .order("created_at", ascending: false)
                .limit(200)
                .execute()
                .value
            let rows = Array(rowsDesc.reversed())
            var viewMessages: [ChatMessage] = []
            var cacheRows: [LocalDatabase.MessageRow] = []
            viewMessages.reserveCapacity(rows.count)
            cacheRows.reserveCapacity(rows.count)
            var citationsLoaded: [String: [MessageCitation]] = [:]
            var tracesLoaded: [String: [ToolTraceEvent]] = [:]
            var traceCitationsLoaded: [String: [MessageCitation]] = [:]
            var attachmentIdsLoaded: [String: [String]] = [:]
            for r in rows {
                let secs = ServerTimestamp.epochSeconds(r.created_at, default: 0)
                // Recalled message rows (status='deleted') shouldn't render —
                // their content has been blanked server-side and the
                // user-facing affordance is the tombstone log row instead.
                if r.status == "deleted" { continue }
                // Voice-call recap rows are memory-only: the bot's closing
                // summary of a call (metadata.source='voice_call_summary').
                // They feed the long-term memory pipeline server-side but
                // never render in the timeline. The realtime path drops
                // them too (ConversationView+Realtime); this is the
                // history-load counterpart.
                if r.metadata?.objectValue?["source"]?.stringValue == "voice_call_summary" {
                    continue
                }
                if r.role == "log" {
                    // Recall tombstone — synthesise into a render-only
                    // ChatMessage. Other log_kinds (review steps, etc.)
                    // stay server-only and don't render here.
                    if r.log_kind == "recall", let payload = r.log_payload {
                        let originalSecs = payload.original_created_at_secs
                        viewMessages.append(ChatMessage(
                            id: r.id,
                            conversation_id: r.conversation_id,
                            sender_type: "recall_log",
                            sender_id: payload.recaller_user_id ?? (r.user_id ?? ""),
                            // `content` carries the original message's
                            // epoch-seconds for the tombstone formatter.
                            content: String(originalSecs),
                            created_at: secs,
                            attachments: nil
                        ))
                    }
                    continue
                }
                if let (events, citations) = parsePersistedToolTrace(from: r.metadata) {
                    if !events.isEmpty { tracesLoaded[r.id] = events }
                    if !citations.isEmpty { traceCitationsLoaded[r.id] = citations }
                }
                let senderType: String = r.role == "bot" ? "bot" : "user"
                let senderId = r.role == "bot" ? (r.sender_bot_id ?? "") : (r.user_id ?? "")
                // Bubbles are persisted whole (status='done'); the worker
                // never writes partial rows, so `content` is authoritative.
                let renderContent = r.content ?? ""
                viewMessages.append(ChatMessage(
                    id: r.id,
                    conversation_id: r.conversation_id,
                    sender_type: senderType,
                    sender_id: senderId,
                    content: renderContent,
                    created_at: secs,
                    attachments: nil,
                    parent_message_id: r.parent_message_id,
                    bubble_group_id: r.bubble_group_id,
                    model_slug: r.model_slug
                ))
                if let cites = r.citations, !cites.isEmpty {
                    citationsLoaded[r.id] = cites
                }
                if let aids = r.attachments?.ids, !aids.isEmpty {
                    attachmentIdsLoaded[r.id] = aids
                }
                cacheRows.append(LocalDatabase.MessageRow(
                    id: r.id,
                    client_message_id: r.client_message_id,
                    conversation_id: r.conversation_id,
                    user_id: r.user_id,
                    sender_bot_id: r.sender_bot_id,
                    role: r.role,
                    content: renderContent,
                    status: r.status,
                    created_at: secs
                ))
            }
            // Only reassign when the authoritative set actually differs from
            // what's already on screen (the cache hydrate above, or a turn
            // that persisted into cache and got reloaded). A wholesale
            // reassign of an identical array still triggers a full SwiftUI
            // re-render — that's the visible "刷新一次" flash on every reopen.
            if self.messages != viewMessages {
                self.messages = viewMessages
            }
            // Merge — keep any in-flight live snapshots that the SSE turn
            // already populated; history's persisted values win on key collision.
            self.citationsByMsgId.merge(citationsLoaded) { _, new in new }
            self.tracesByUserMsgId.merge(tracesLoaded) { _, new in new }
            self.traceCitationsByUserMsgId.merge(traceCitationsLoaded) { _, new in new }
            self.attachmentIdsByMsgId.merge(attachmentIdsLoaded) { _, new in new }

            // Per-id attachment metadata (mime + filename) so the bubble
            // grid can render non-image files as icon+name chips, not
            // broken image thumbnails. RLS on `attachments` is
            // uploader-only — in a 1:1 bot chat every attachment is the
            // caller's own, so they all resolve; a peer's file in a
            // user_user conv won't, and falls back to the image guess.
            let metaIds = Array(Set(attachmentIdsLoaded.values.flatMap { $0 }))
            if !metaIds.isEmpty {
                struct AttachmentMetaRow: Decodable {
                    let id: String
                    let mime_type: String
                    let filename: String?
                    let byte_size: Int?
                }
                if let metaRows: [AttachmentMetaRow] = try? await SupabaseStack.shared
                    .from("attachments")
                    .select("id, mime_type, filename, byte_size")
                    .in("id", values: metaIds)
                    .execute()
                    .value {
                    var meta: [String: Attachment] = [:]
                    for r in metaRows {
                        let isImage = r.mime_type.lowercased().hasPrefix("image/")
                        meta[r.id] = Attachment(
                            id: r.id, kind: isImage ? "image" : "file",
                            mime: r.mime_type, size: r.byte_size,
                            width: nil, height: nil,
                            url: "/v1/uploads/\(r.id)", filename: r.filename
                        )
                    }
                    self.attachmentMetaById.merge(meta) { _, new in new }
                }
            }
            // Reconcile the local cache against the server's authoritative
            // view in one atomic transaction: the cache for this conv
            // becomes exactly the fetched set — no leftover recall
            // tombstones / RLS-hidden recaps, no duplicates, and no window
            // where the cache is empty or partial. Replaces the old
            // prune-then-upsert split (two transactions, conflict-resolved
            // on `id` rather than the cmid dedup key).
            LocalDatabase.shared.replaceMessages(
                conversationId: conversation.id, cacheRows)
        } catch {
            // Network down + we have a cache: stay quiet (cached msgs still
            // visible). Show the error only if we have nothing to display.
            if messages.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }
}
