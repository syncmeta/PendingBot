import Foundation
import Supabase
import SwiftUI

// Realtime + voice-call surfaces of ConversationView. Two cohesive
// blocks that all live off the realtime-hub subscription bound to
// this conv's row stream:
//
//   • Subscription wiring — subscribeRealtime opens a channel via the
//     shared RealtimeManager and routes onMessage / onLookback /
//     onContinueRequest / onParticipants into the four typed appliers
//     below. applyRealtimeEvent does the heavy lifting: dedupe live-id
//     bubbles against canonical inserts, rekey trace/citation/sidecar
//     dicts when ids swap, drop recalled rows + scrub URLCache.
//
//   • Voice-call entry — canStartVoiceCall gates the header phone
//     button (1v1 bot conv with voice_call_enabled flipped on);
//     startVoiceCall hands a fresh CallSession to CallCenter, which is
//     where the .fullScreenCover and floating pill live (so the call
//     survives leaving this conversation).
//
// All the lookback-note bookkeeping lives here too because the
// onLookback push and its 30s auto-fire timer share state with the
// Realtime path (chatTurnTask, activeLookbacks).

extension ConversationView {

    /// Open a Realtime channel on the current conv and wire the four
    /// stream types into their dedicated appliers. No-op for pending
    /// (id == "") convs — those subscribe after first-send materializes
    /// the row.
    func subscribeRealtime() async {
        let convId = conversation.id
        guard !convId.isEmpty else { return }
        realtimeToken = await RealtimeManager.shared.startConvChannel(
            conversationId: convId,
            onMessage: { event in
                Task { @MainActor in
                    applyRealtimeEvent(event)
                }
            },
            onLookback: { event in
                Task { @MainActor in
                    applyLookbackEvent(event)
                }
            },
            onContinueRequest: { event in
                Task { @MainActor in
                    applyContinueEvent(event)
                }
            },
            onParticipants: { _ in
                Task { @MainActor in
                    // Senders map is small and the event fires only on
                    // joins / role changes / leaves — re-running the
                    // load-once function is fine. Cheap enough that
                    // we don't bother diffing.
                    await loadGroupSendersIfNeeded()
                }
            },
            onVoiceCall: { frame in
                Task { @MainActor in
                    // ActiveVoiceCallStore is part of the iOS-only Call slice.
                    #if os(iOS)
                    ActiveVoiceCallStore.shared.apply(frame)
                    #else
                    _ = frame
                    #endif
                }
            }
        )
    }

    /// Apply a Realtime event from group_continue_requests to the
    /// composer banner. New row pending → show banner with its bot ids;
    /// existing row flipped to allowed/denied/expired → clear banner.
    func applyContinueEvent(_ event: ContinueRequestEvent) {
        let r = event.record
        guard let id = r["id"]?.stringValue else { return }
        let status = r["status"]?.stringValue ?? "pending"
        if status != "pending" {
            // Decided / expired — clear our banner if it was for this row.
            if pendingContinue?.id == id { pendingContinue = nil }
            return
        }
        // pending_bot_ids comes through as a JSON array; AnyJSON →
        // [String] requires a tiny manual decode.
        var botIds: [String] = []
        if let arr = r["pending_bot_ids"]?.arrayValue {
            botIds = arr.compactMap { $0.stringValue }
        }
        pendingContinue = PendingContinue(id: id, pendingBotIds: botIds)
    }

    func applyLookbackEvent(_ event: LookbackEvent) {
        let r = event.record
        guard let id = r["id"]?.stringValue else { return }
        let body = r["body_md"]?.stringValue ?? ""
        let active = (r["active"]?.boolValue) ?? true
        if active {
            // INSERT (new note) or UPDATE that brought it back. Replace by id.
            if let idx = activeLookbacks.firstIndex(where: { $0.id == id }) {
                activeLookbacks[idx] = LookbackNote(id: id, body_md: body, active: true)
            } else {
                activeLookbacks.append(LookbackNote(id: id, body_md: body, active: true))
                // New note arrived — schedule auto-fire after 30s of user silence
                // (skip if a turn is already in flight: the next user reply or
                // the in-flight reply will pick the lookback up via prompt).
                if chatTurnTask == nil {
                    scheduleLookbackAutoFire()
                }
            }
        } else {
            // active=false → bot retired this note (via [DROP_LOOKBACK]).
            activeLookbacks.removeAll { $0.id == id }
        }
    }

    /// Manual "检查" — user-fired lookback. Hits the worker which runs
    /// the same runLookback as the auto cadence (and resets the per
    /// (bot, user) counter so we don't double-fire on the next turn).
    /// New notes arrive via Realtime onLookback just like the auto path.
    func triggerManualLookback() async {
        guard let api else { return }
        do {
            try await api.postVoid("v1/messages/\(conversation.id)/lookback")
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func scheduleLookbackAutoFire() {
        lookbackAutoFireTask?.cancel()
        lookbackAutoFireTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            if Task.isCancelled { return }
            // Re-check: still no in-flight turn, still some active lookbacks?
            guard chatTurnTask == nil, !activeLookbacks.isEmpty else { return }
            sendViaSSE(text: "", attachmentIds: [], autoLookback: true)
        }
    }

    /// Realtime-hub change payload → ChatMessage in the local list.
    /// Dedupe by canonical row id so this device's own SSE-emitted bubbles
    /// (which carry "live-<uuid>" ids until reconciled) get either skipped
    /// or replaced cleanly. role='log' rows are filtered out (rendered via
    /// a different surface).
    func applyRealtimeEvent(_ event: MessageEvent) {
        let r = event.record
        guard let id = r["id"]?.stringValue,
              r["conversation_id"]?.stringValue == conversation.id else { return }
        // Voice-call recap rows are memory-only: the bot's closing summary
        // of a call (metadata.source='voice_call_summary'). They feed the
        // long-term memory pipeline server-side but never render in the
        // timeline, so drop them here before they reach the message list.
        if r["metadata"]?.objectValue?["source"]?.stringValue == "voice_call_summary" {
            return
        }
        let role = r["role"]?.stringValue ?? "user"
        let status = r["status"]?.stringValue ?? ""
        // Recall: when a message flips to status='deleted' (via the
        // server's POST /v1/messages/:id/recall), drop it from the
        // visible timeline. Works for both our own optimistic-already-
        // removed rows (no-op) and peer recalls (the bubble vanishes).
        // Also scrub URLCache for any attachment ids we cached for
        // this row — the worker's R2 object is already gone, but iOS's
        // HTTP cache hangs onto the bytes for up to a year.
        if status == "deleted" {
            messages.removeAll { $0.id == id }
            let attIds = attachmentIdsByMsgId[id] ?? []
            scrubAttachmentCache(attIds)
            attachmentIdsByMsgId.removeValue(forKey: id)
            return
        }
        // Recall tombstone — the log_kind='recall' insert that pairs
        // with the soft-delete above for user_user convs. Synthesise a
        // recall_log ChatMessage so the ForEach renderer drops a
        // centered "你/对方撤回了 X 的一条消息" pill at the right spot.
        if role == "log" {
            let logKind = r["log_kind"]?.stringValue ?? ""
            if logKind == "recall" {
                guard let payloadValue = r["log_payload"],
                      let payload = decodeRecallPayload(payloadValue)
                else { return }
                let createdRaw = r["created_at"]?.stringValue ?? ""
                let secs = ServerTimestamp.epochSeconds(createdRaw, default: Int(Date().timeIntervalSince1970))
                let recaller = payload.recaller_user_id ?? (r["user_id"]?.stringValue ?? "")
                let synth = ChatMessage(
                    id: id,
                    conversation_id: conversation.id,
                    sender_type: "recall_log",
                    sender_id: recaller,
                    content: String(payload.original_created_at_secs),
                    created_at: secs,
                    attachments: nil
                )
                if let existing = messages.firstIndex(where: { $0.id == id }) {
                    messages[existing] = synth
                } else {
                    messages.append(synth)
                    messages.sort(by: ChatMessage.timelinePrecedes)
                }
            }
            return
        }
        // Capture attachment ids into the sidecar dict so a later
        // recall (status='deleted' UPDATE) can scrub URLCache for the
        // right ids. Cheap; only fires when the row actually has any.
        if let attValue = r["attachments"], let aids = decodeAttachmentIds(attValue), !aids.isEmpty {
            attachmentIdsByMsgId[id] = aids
        }
        // Bubbles are persisted whole — the worker emits each finished
        // bubble as its own row, so `content` is always the authoritative
        // text for the row.
        let content = r["content"]?.stringValue ?? ""
        let createdRaw = r["created_at"]?.stringValue ?? ""
        // Default to "now" so live messages don't collapse to 1970 if the
        // timestamp format ever drifts.
        let secs = ServerTimestamp.epochSeconds(createdRaw, default: Int(Date().timeIntervalSince1970))
        let messageSeq = decodeIntValue(r["message_seq"])
        let senderType = role == "bot" ? "bot" : "user"
        let senderId = role == "bot"
            ? (r["sender_bot_id"]?.stringValue ?? "")
            : (r["user_id"]?.stringValue ?? "")
        let msg = ChatMessage(
            id: id,
            conversation_id: conversation.id,
            sender_type: senderType,
            sender_id: senderId,
            content: content,
            created_at: secs,
            message_seq: messageSeq,
            attachments: nil,
            parent_message_id: r["parent_message_id"]?.stringValue,
            bubble_group_id: r["bubble_group_id"]?.stringValue,
            model_slug: r["model_slug"]?.stringValue
        )
        let citations = parseCitations(from: r["citations"])
        if let existing = messages.firstIndex(where: { $0.id == id }) {
            messages[existing] = msg
            if let citations { citationsByMsgId[id] = citations }
        } else {
            // Drop our own optimistic local/live row if we can match it.
            //
            // Bot rows: the SSE `bubble` event normally rekeys our live-*
            // bubble to its canonical id before this INSERT arrives (the
            // webhook path is slower than SSE), so the INSERT resolves
            // above as an in-place upsert and never reaches here. This
            // branch only catches the rare reverse race — INSERT before
            // the `bubble` event: in a 1v1 bot conv the single bot means
            // any bot row arriving mid-turn is unambiguously ours, so
            // FIFO-replace the first unreconciled live-* bot bubble.
            //
            // User rows have no server-announced id (the user message is
            // materialized server-side without acking back), so match on
            // exact client_message_id, falling back to (prefix + role +
            // recency) for cross-device echoes.
            let isOurBotEcho = role == "bot"
                && conversation.conversation_type == "user_bot"
                && chatTurnTask != nil
                && messages.contains {
                    $0.id.hasPrefix("live-") && $0.sender_type == "bot"
                }
            let serverCmid = r["client_message_id"]?.stringValue
            let now = Int(Date().timeIntervalSince1970)
            let staleIndex: Int? = {
                if isOurBotEcho {
                    return messages.firstIndex { m in
                        m.id.hasPrefix("live-") && m.sender_type == "bot"
                    }
                }
                if role != "bot" {
                    // Prefer exact client_message_id match — survives any
                    // round-trip latency.
                    if let cmid = serverCmid,
                       let local = localMsgClientIds.first(where: { $0.value == cmid })?.key,
                       let idx = messages.firstIndex(where: { $0.id == local }) {
                        return idx
                    }
                    // Fallback for legacy / cross-device echoes that landed
                    // here without a tracked cmid (e.g. a peer device that
                    // just inserted a row in a user_user thread we have open).
                    // Gate on sender_id too — in a group thread several rows
                    // carry sender_type=="user", so a peer's echo must not
                    // claim our own pending optimistic bubble.
                    return messages.firstIndex { m in
                        m.id.hasPrefix("local-")
                            && m.sender_type == senderType
                            && m.sender_id == senderId
                            && abs(m.created_at - now) < 5
                    }
                }
                return nil
            }()
            if let stale = staleIndex {
                let oldId = messages[stale].id
                localMsgClientIds.removeValue(forKey: oldId)
                messages[stale] = msg
                // Re-key any tool trace bound to the optimistic local id so
                // it stays attached after the canonical row replaces it.
                if let trace = tracesByUserMsgId.removeValue(forKey: oldId) {
                    tracesByUserMsgId[id] = trace
                    if liveTraceUserMsgId == oldId {
                        liveTraceUserMsgId = id
                    }
                }
                if let traceCites = traceCitationsByUserMsgId.removeValue(forKey: oldId) {
                    traceCitationsByUserMsgId[id] = traceCites
                }
                // Same swap for the attachment-id sidecar — the recall
                // path keys by current msg id, so the canonical row
                // must carry the same scrub list forward.
                if let aids = attachmentIdsByMsgId.removeValue(forKey: oldId) {
                    attachmentIdsByMsgId[id] = aids
                }
                // Same rekey for citations — the live-id snapshot was set
                // from the SSE event; the canonical row may carry the same
                // (or fresher) list, so prefer the canonical when present.
                let priorCitations = citationsByMsgId.removeValue(forKey: oldId)
                citationsByMsgId[id] = citations ?? priorCitations
            } else {
                messages.append(msg)
                if let citations { citationsByMsgId[id] = citations }
            }
        }
        messages.sort(by: ChatMessage.timelinePrecedes)
        // Conversation is open and a new message just landed — clear the
        // server unread bump the INSERT trigger added. Without this the
        // count silently climbs while the user is reading and resurfaces
        // on the message list the moment they back out. clearServerCount
        // early-returns when serverCounts is already 0, so this is a cheap
        // no-op for our own outgoing rows (sender starts at 0 server-side).
        UnreadStore.shared.markRead(conversation.id, throughLastMessageId: id)
        // Mirror to local cache.
        ChatDataSource.mergeMessages([
            LocalDatabase.MessageRow(
                id: id,
                client_message_id: r["client_message_id"]?.stringValue,
                conversation_id: conversation.id,
                user_id: r["user_id"]?.stringValue,
                sender_bot_id: r["sender_bot_id"]?.stringValue,
                role: role,
                content: content,
                status: r["status"]?.stringValue,
                created_at: secs,
                message_seq: messageSeq,
                parent_message_id: r["parent_message_id"]?.stringValue,
                bubble_group_id: r["bubble_group_id"]?.stringValue,
                model_slug: r["model_slug"]?.stringValue
            ),
        ])
    }

    /// Phone-button visibility — only 1v1 bot chats with voice_call_enabled
    /// flipped by the bot owner. Pending convs need a materialized id for
    /// the /v1/realtime/session round-trip, so we gate on conv.id too.
    var canStartVoiceCall: Bool {
        guard !conversation.id.isEmpty else { return false }
        if conversation.conversation_type != "user_bot" { return false }
        return bot?.voice_call_enabled == true
    }

    /// Group-call button visibility — group convs with at least one bot
    /// participant. Pending convs need a materialized id for the
    /// `/v1/groups/:id/voice/*` round-trips, so we gate on conv.id too.
    /// The worker filters to voice-enabled bots and 403s an all-disabled
    /// group, which surfaces as a "通话失败" alert.
    var canStartGroupCall: Bool {
        guard !conversation.id.isEmpty else { return false }
        guard conversation.conversation_type == "group" else { return false }
        return groupSenders.values.contains { $0.kind == .bot }
    }

    // ── Voice-call entry — iOS-only Call slice ──────────────────────────────
    // CallCenter / GroupCallSession / CallSession / IncomingCallStore are all
    // part of the iOS-only Call slice. On macOS the conversation works fully
    // minus the voice-call entry, so these members don't exist there.
    #if os(iOS)

    /// Spin up a GroupCallSession and hand it to `CallCenter`. The
    /// app-level center owns the session past this view's lifetime, so
    /// the call survives the user navigating away (minimize → other
    /// tab → re-expand from the floating pill).
    ///
    /// If a call is already active, no-op — the existing one re-expands
    /// (via the pill the user is presumably looking at) rather than us
    /// minting a competing session.
    func startGroupCall() {
        guard let userId = AccountStore.shared.current?.id, !userId.isEmpty
        else { return }
        guard !callCenter.hasActiveCall else {
            callCenter.expand()
            return
        }
        let session = GroupCallSession(
            conversationId: conversation.id,
            currentUserId: userId,
            groupTitle: conversation.displayTitle,
            members: groupSenders,
            api: VoiceCallAPI(),
        )
        callCenter.startGroupCall(session)
    }

    /// If the IncomingCallStore is currently flagging this conv as
    /// "user already accepted via CallKit, please auto-open the call",
    /// consume the flag and spin up the group call. No-op otherwise.
    /// Called from both `.task` (after groupSenders loads) and
    /// `.onChange` (warm path where the user was already in this conv).
    func consumePendingAutoJoinIfMatches() {
        let store = IncomingCallStore.shared
        guard let target = store.pendingAutoJoinConversationId,
              target == conversation.id
        else { return }
        store.pendingAutoJoinConversationId = nil
        // Already in a call (rare race) — leave it; flipping sessions
        // mid-call would tear down the live one.
        if callCenter.hasActiveCall { return }
        startGroupCall()
    }

    /// Spin up a CallSession for the current bot and hand it to
    /// `CallCenter`. See `startGroupCall` for the ownership rationale.
    func startVoiceCall() {
        let botId: String = {
            if let bid = bot?.id, !bid.isEmpty { return bid }
            return conversation.bot_id
        }()
        guard !botId.isEmpty else { return }
        guard !callCenter.hasActiveCall else {
            callCenter.expand()
            return
        }
        let session = CallSession(
            conversationId: conversation.id,
            botId: botId,
            botDisplayName: bot?.display_name ?? "AI",
            api: VoiceCallAPI(),
        )
        callCenter.startVoiceCall(session)
    }
    #endif
}

private func decodeIntValue(_ any: AnyJSON?) -> Int? {
    guard let any,
          let data = try? JSONEncoder().encode(any) else { return nil }
    if let int = try? JSONDecoder().decode(Int.self, from: data) {
        return int
    }
    if let string = try? JSONDecoder().decode(String.self, from: data) {
        return Int(string)
    }
    return nil
}
