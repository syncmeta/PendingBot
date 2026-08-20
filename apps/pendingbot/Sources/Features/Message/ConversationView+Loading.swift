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
        let cached = CacheRepository.cachedGroupMembers(conversationId: conversation.id)
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
                    avatar_seed: avatarSeed
                ))
            }
            self.groupSenders = lookup
            CacheRepository.persistGroupMembers(
                conversationId: conversation.id, cacheRows)
        } catch {
            loadingLog.warning("group senders load failed: \(error.localizedDescription, privacy: .public)")
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

    /// Fetch the full `Bot` record when the caller didn't supply one but
    /// the conversation IS a bot conversation. The Mac 3-column shell
    /// renders the list and the detail as *separate* MessageTabView /
    /// FriendsTabView instances with disjoint `@State`, so the detail's
    /// `bot(for:)` reads an empty `@State bots` and hands us `bot: nil`.
    /// Without the record the header drops its `· <model>` suffix and the
    /// in-chat BotConfigView entry disappears (both read `effectiveBot`).
    /// Resolving it here makes the shared view robust regardless of how it
    /// was constructed.
    ///
    /// Gated on `bot == nil`, so on iOS — where the list always passes a
    /// real bot — this never fires and behaviour is byte-identical. Runs at
    /// most once (early-returns when `resolvedBot` is already set). For
    /// human-human convs there is no bot id to resolve and it no-ops.
    ///
    /// Same query shape as `MessageTabView.load()` / `BotManagement` — the
    /// `bots` columns that map 1:1 onto the `Bot` model — so there's one
    /// select to keep in sync, no new endpoint.
    func resolveBotIfNeeded() async {
        // `bot == nil` only — we deliberately no longer gate on
        // `resolvedBot == nil`. The init now seeds `resolvedBot` synchronously
        // from the local bots cache for an instant header paint; gating on nil
        // would then skip this refresh entirely and pin the header to a
        // possibly-stale cache. Run the refresh and assign only on a real
        // change (below) so staleness self-corrects without re-rendering when
        // the cache was already right.
        guard bot == nil else { return }
        // Resolve the bot id: a materialized bot conv carries it on
        // `conversation.bot_id`; a not-yet-materialized one carries it on
        // the pending peer (only when the peer is a bot, not a human).
        let botId: String? = {
            if !conversation.bot_id.isEmpty { return conversation.bot_id }
            if let p = pendingPeer, p.kind == "bot" { return p.peerId }
            return nil
        }()
        guard let botId else { return }
        struct BotRow: Decodable {
            let id: String
            let display_name: String
            let model_id: String?
            let visibility: String?
            let creator_id: String?
            let voice_call_enabled: Bool?
        }
        do {
            let row: BotRow = try await SupabaseStack.shared
                .from("bots")
                .select("id, display_name, model_id, visibility, creator_id, voice_call_enabled")
                .eq("id", value: botId)
                .single()
                .execute()
                .value
            let fetched = Bot(
                id: row.id, display_name: row.display_name,
                access_mode: nil, model: row.model_id,
                visibility: row.visibility, creator_id: row.creator_id,
                voice_call_enabled: row.voice_call_enabled
            )
            // Assign only on a real change so the cache-seeded header doesn't
            // re-render (flash) when the network just confirms the same bot.
            if fetched != resolvedBot { self.resolvedBot = fetched }
        } catch {
            // Decoration-only — the conversation works fully without it,
            // so a miss just leaves the header suffix / settings entry off.
            loadingLog.warning("bot self-resolve failed: \(error.localizedDescription, privacy: .public)")
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
                    message_seq: r.message_seq,
                    attachments: nil,
                    parent_message_id: r.parent_message_id,
                    bubble_group_id: r.bubble_group_id,
                    model_slug: r.model_slug
                )
            }
        }

        do {
            // Direct Supabase read — RLS gates participation. Excludes role='log'
            // (review step entries) which are rendered separately. The row type
            // (`MessageRow`) + query live in the shared `MessagesFetch`
            // (Networking/) so iOS + macOS run one query; the per-row dispatch
            // below is iOS-only. `latest()` returns chronological (oldest→newest)
            // — the latest 200, not the oldest.
            //
            // Most role='log' rows are server-only (review step entries)
            // and never render. The one exception is log_kind='recall':
            // it's the WeChat-style tombstone the recall flow inserts
            // for user_user convs. We synthesise a ChatMessage with
            // sender_type="recall_log" and stash the original message's
            // created_at in `content` so the row renderer can format
            // "我撤回了 几分钟前 的一条消息" without further look-ups.
            let rows = try await MessagesFetch.latest(conversationId: conversation.id)
            var viewMessages: [ChatMessage] = []
            var cacheRows: [LocalDatabase.MessageRow] = []
            viewMessages.reserveCapacity(rows.count)
            cacheRows.reserveCapacity(rows.count)
            var citationsLoaded: [String: [MessageCitation]] = [:]
            var tracesLoaded: [String: [ToolTraceEvent]] = [:]
            var traceCitationsLoaded: [String: [MessageCitation]] = [:]
            var attachmentIdsLoaded: [String: [String]] = [:]
            var permissionRequestsLoaded: [String: PermissionRequestPayload] = [:]
            var guessPromptsLoaded: Set<String> = []
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
                    // log_kind dispatch — each kind synthesises (or
                    // doesn't) a render-only ChatMessage. Other kinds
                    // (e.g. review steps, continue_request) stay
                    // server-only and don't surface here.
                    if r.log_kind == "recall", let any = r.log_payload,
                       let payload = decodeLogPayload(any, as: RecallPayload.self) {
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
                            message_seq: r.message_seq,
                            attachments: nil
                        ))
                    } else if r.log_kind == "permission_request", let any = r.log_payload,
                              let payload = decodeLogPayload(any, as: PermissionRequestPayload.self) {
                        // permission_request — agent's request_permission
                        // tool dropped a card here (spec v2 §10).
                        // Synthesise a host ChatMessage + stash the typed
                        // payload in the sibling dict for the renderer.
                        permissionRequestsLoaded[r.id] = payload
                        viewMessages.append(ChatMessage(
                            id: r.id,
                            conversation_id: r.conversation_id,
                            sender_type: "permission_request_log",
                            sender_id: r.sender_bot_id ?? "",
                            content: "",
                            created_at: secs,
                            message_seq: r.message_seq,
                            attachments: nil
                        ))
                    } else if r.log_kind == "guess_prompt" {
                        // guess_prompt (Model Blind Box, T9.1) — the
                        // `prompt_model_guess` tool dropped a 「猜一猜」
                        // card here. There's no per-row payload to decode;
                        // the card reads the conv-level `convModelState`
                        // (revealed / current model) instead. We just need
                        // a host ChatMessage so the timeline can place the
                        // card, and the id collected for the render branch.
                        guessPromptsLoaded.insert(r.id)
                        viewMessages.append(ChatMessage(
                            id: r.id,
                            conversation_id: r.conversation_id,
                            sender_type: "guess_prompt_log",
                            sender_id: r.sender_bot_id ?? "",
                            content: "",
                            created_at: secs,
                            message_seq: r.message_seq,
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
                    message_seq: r.message_seq,
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
                    created_at: secs,
                    message_seq: r.message_seq,
                    parent_message_id: r.parent_message_id,
                    bubble_group_id: r.bubble_group_id,
                    model_slug: r.model_slug
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
            // permission_request payloads — server is the only source of
            // truth on status, so a fresh load overwrites any locally
            // cached `pending` card that has been decided elsewhere.
            self.permissionRequestsByMsgId.merge(permissionRequestsLoaded) { _, new in new }
            // guess_prompt ids — history is the source of truth for which
            // log rows are 「猜一猜」cards, so union in the freshly-loaded
            // set (a realtime-arrived id from this session stays put; the
            // history pass just confirms it).
            self.guessPromptMsgIds.formUnion(guessPromptsLoaded)

            // Per-id attachment metadata (mime + filename) so the bubble
            // grid can render non-image files as icon+name chips, not
            // broken image thumbnails. RLS on `attachments` is
            // uploader-only — in a 1:1 bot chat every attachment is the
            // caller's own, so they all resolve; a peer's file in a
            // user_user conv won't, and falls back to the image guess.
            let metaIds = Array(Set(attachmentIdsLoaded.values.flatMap { $0 }))
            // Resolution lives in the shared `MessagesFetch.attachmentMeta`
            // (Networking/) so iOS + macOS build the same `Attachment` from the
            // `attachments` table.
            if let meta = try? await MessagesFetch.attachmentMeta(ids: metaIds), !meta.isEmpty {
                self.attachmentMetaById.merge(meta) { _, new in new }
            }
            // Reconcile the local cache against the server's authoritative
            // view in one atomic transaction: the cache for this conv
            // becomes exactly the fetched set — no leftover recall
            // tombstones / RLS-hidden recaps, no duplicates, and no window
            // where the cache is empty or partial. Replaces the old
            // prune-then-upsert split (two transactions, conflict-resolved
            // on `id` rather than the cmid dedup key).
            ChatDataSource.persistMessages(
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

/// Decode a typed shape out of a Supabase AnyJSON jsonb cell. We
/// re-encode the AnyJSON value back to JSON bytes and then JSONDecode
/// the requested struct from those bytes. Returns nil on any failure
/// (missing field, literal `null`, wrong shape) so callers can safely
/// fall back to ignoring the row.
func decodeLogPayload<T: Decodable>(_ any: AnyJSON, as type: T.Type) -> T? {
    do {
        let data = try JSONEncoder().encode(any)
        if data.count == 4, String(data: data, encoding: .utf8) == "null" {
            return nil
        }
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        return nil
    }
}
