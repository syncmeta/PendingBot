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
    func loadGroupSendersIfNeeded() async {
        guard conversation.conversation_type == "group" else { return }
        guard !conversation.id.isEmpty else { return }
        do {
            struct PartRow: Decodable {
                let participant_type: String
                let participant_id: String
                let nickname: String?
            }
            let parts: [PartRow] = try await SupabaseStack.shared
                .from("conversation_participants")
                .select("participant_type, participant_id, nickname")
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
            for p in parts {
                let key = "\(p.participant_type):\(p.participant_id)"
                let isBot = p.participant_type == "bot"
                let fallback: String = {
                    if isBot {
                        return botMap[p.participant_id] ?? "未知机器人"
                    }
                    let name = userMap[p.participant_id]?.0 ?? ""
                    return name.isEmpty ? String(p.participant_id.prefix(8)) : name
                }()
                let nick = p.nickname?.trimmingCharacters(in: .whitespaces)
                let display = (nick?.isEmpty == false ? nick! : fallback)
                let info = isBot ? nil : userMap[p.participant_id]
                lookup[key] = GroupBubbleSender(
                    kind: isBot ? .bot : .user,
                    id: p.participant_id,
                    displayName: display,
                    avatarPath: info?.1,
                    avatarSeed: info?.2 ?? p.participant_id,
                )
            }
            self.groupSenders = lookup
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
                let content_partial: String?
                let status: String?
                let created_at: String
                let citations: [MessageCitation]?
                let metadata: AnyJSON?
            }
            // Most role='log' rows are server-only (review step entries)
            // and never render. The one exception is log_kind='recall':
            // it's the WeChat-style tombstone the recall flow inserts
            // for user_user convs. We synthesise a ChatMessage with
            // sender_type="recall_log" and stash the original message's
            // created_at in `content` so the row renderer can format
            // "我撤回了 几分钟前 的一条消息" without further look-ups.
            let rows: [Row] = try await SupabaseStack.shared
                .from("messages")
                .select("id, client_message_id, conversation_id, user_id, sender_bot_id, role, log_kind, log_payload, attachments, content, content_partial, status, created_at, citations, metadata")
                .eq("conversation_id", value: conversation.id)
                .order("created_at", ascending: true)
                .limit(200)
                .execute()
                .value
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
                // Mid-stream bot rows have content=null and only content_partial set;
                // fall back so a re-enter shows the in-flight bubble at its current
                // length, not blank.
                let renderContent = (r.content?.isEmpty == false ? r.content : r.content_partial) ?? ""
                viewMessages.append(ChatMessage(
                    id: r.id,
                    conversation_id: r.conversation_id,
                    sender_type: senderType,
                    sender_id: senderId,
                    content: renderContent,
                    created_at: secs,
                    attachments: nil
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
            self.messages = viewMessages
            // Merge — keep any in-flight live snapshots that the SSE turn
            // already populated; history's persisted values win on key collision.
            self.citationsByMsgId.merge(citationsLoaded) { _, new in new }
            self.tracesByUserMsgId.merge(tracesLoaded) { _, new in new }
            self.traceCitationsByUserMsgId.merge(traceCitationsLoaded) { _, new in new }
            self.attachmentIdsByMsgId.merge(attachmentIdsLoaded) { _, new in new }
            LocalDatabase.shared.upsertMessages(cacheRows)
        } catch {
            // Network down + we have a cache: stay quiet (cached msgs still
            // visible). Show the error only if we have nothing to display.
            if messages.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }
}
