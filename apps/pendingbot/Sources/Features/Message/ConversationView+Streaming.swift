import Foundation
import OSLog
import SwiftUI

private let streamingLog = Logger.category("ConversationView.Streaming")

// Bubble emission router.
//
// Tokens land on the bubble as fast as they arrive from the SSE stream
// — no paced typewriter. The BubbleSplitter (BubbleSplitter.swift) still
// decides whether a bubble streams or pops in whole: short replies
// (< BUBBLE_OVERFLOW_CHARS before delimiter / end-of-turn) emit as
// .begin(.complete, content); longer ones promote to .begin(.streaming,
// head-buffer) once enough text has accumulated, and subsequent .append
// events extend the live bubble's tail.
//
// The cursor's blink mode is driven by an idle debounce: actively
// flowing tokens → solid, ~350 ms with no new token → blink. The
// debounce Task lives in `revealTask`.

extension ConversationView {

    /// How long to wait with no .append before flipping the cursor into
    /// blink mode. Shorter than the blink period so the user sees at
    /// least one blink cycle before tokens land again.
    static let cursorBlinkAfterIdle: TimeInterval = 0.35

    /// Translate a batch of SSE-derived bubble events into local
    /// ChatMessage mutations. Events are applied in order, immediately;
    /// no queueing because the splitter ends one bubble before beginning
    /// the next.
    func applyBubbleEmissions(_ events: [BubbleEmission]) {
        for evt in events {
            applyDirect(evt)
        }
    }

    func applyDirect(_ evt: BubbleEmission) {
        switch evt {
        case .begin(let id, let mode, let content):
            let key = "live-\(id.uuidString)"
            messages.append(ChatMessage(
                id: key,
                conversation_id: conversation.id,
                sender_type: "bot",
                sender_id: conversation.bot_id,
                content: content,
                created_at: Int(Date().timeIntervalSince1970),
                attachments: nil
            ))
            // Record the bubble in turn order so the SSE `bubble` event
            // can rekey it to its server-canonical id (see rekeyBotBubble).
            turnBubbleIds.append(key)
            // Inherit the turn's accumulated citations so any [N] in the
            // bubble's content lands tappable from the first frame. The
            // canonical row's Realtime UPDATE later refreshes the same key
            // (after rekeying live-id → canonical id below).
            if !liveCitations.isEmpty {
                citationsByMsgId[key] = liveCitations
            }
            if mode == .streaming {
                revealTargetId = key
                streamPaused = false
                // Soft bump on the first streaming bubble so the user
                // feels the bot start "typing" — matches ChatGPT iOS.
                Haptics.receive()
                scheduleBlinkAfterIdle()
            }
        case .append(let id, let delta):
            let key = "live-\(id.uuidString)"
            if let idx = messages.lastIndex(where: { $0.id == key }) {
                let prev = messages[idx]
                messages[idx] = ChatMessage(
                    id: prev.id, conversation_id: prev.conversation_id,
                    sender_type: prev.sender_type, sender_id: prev.sender_id,
                    content: prev.content + delta,
                    created_at: prev.created_at,
                    attachments: prev.attachments
                )
            }
            if revealTargetId == key {
                if streamPaused { streamPaused = false }
                // Throttled inside Haptics — safe to call per-token.
                Haptics.streamTick()
                scheduleBlinkAfterIdle()
            }
        case .end(let id):
            let key = "live-\(id.uuidString)"
            if revealTargetId == key {
                revealTargetId = nil
                streamPaused = false
                revealTask?.cancel()
                revealTask = nil
            }
        case .turnDone, .turnInterrupted:
            revealTargetId = nil
            streamPaused = false
            revealTask?.cancel()
            revealTask = nil
        case .error(let m):
            // Worker sometimes emits an error event with an empty
            // `message` field (e.g. when the underlying error stringifies
            // to ""). Surface a placeholder so the user sees something
            // and we can grep the console log for the SSE event.
            let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
            self.error = trimmed.isEmpty
                ? "服务端错误（空）— 请重试或检查网络"
                : trimmed
            streamingLog.error("worker error event: \(m, privacy: .public)")
            if let key = liveTraceUserMsgId { markUserMessageFailed(key) }
        }
    }

    /// Rekey the optimistic `live-*` bot bubble at `turnBubbleIds[idx]` to
    /// its server-canonical `id`, announced by the SSE `bubble` event.
    /// After this the bubble carries the same id the realtime INSERT will
    /// carry, so `applyRealtimeEvent` resolves that INSERT as an in-place
    /// upsert rather than appending a duplicate. Idempotent; a no-op if the
    /// entry is already canonical or the row has since gone.
    ///
    /// Safe to run mid-turn: a bubble's `bubble` event trails all of its
    /// tokens, so no further `.append` targets the old `live-*` key.
    func rekeyBotBubble(at idx: Int, to id: String) {
        guard idx >= 0, idx < turnBubbleIds.count else { return }
        let oldId = turnBubbleIds[idx]
        guard oldId != id else { return }
        turnBubbleIds[idx] = id
        guard let mIdx = messages.firstIndex(where: { $0.id == oldId }) else { return }
        let m = messages[mIdx]
        messages[mIdx] = ChatMessage(
            id: id,
            conversation_id: m.conversation_id,
            sender_type: m.sender_type,
            sender_id: m.sender_id,
            content: m.content,
            created_at: m.created_at,
            attachments: m.attachments
        )
        // Carry id-keyed sidecars across the rekey.
        if let cites = citationsByMsgId.removeValue(forKey: oldId) {
            citationsByMsgId[id] = cites
        }
        if let aids = attachmentIdsByMsgId.removeValue(forKey: oldId) {
            attachmentIdsByMsgId[id] = aids
        }
        if revealTargetId == oldId { revealTargetId = id }
    }

    /// Persist this turn's canonical rows (the user message + each bot
    /// bubble) into the local cache at turn end.
    ///
    /// The live SSE path mutates only the in-memory `messages` array, and
    /// `applyRealtimeEvent` drops 1:1 bot text rows *before* its own cache
    /// write — so without this the cache is a full turn behind the moment
    /// the user leaves the conversation, and reopening paints stale content
    /// (missing the latest reply) until loadHistory's network round-trip
    /// lands. That's the "每次进去都是旧的，要刷新一次" symptom.
    ///
    /// Skips rows still carrying an optimistic id (`live-*` bot bubble not
    /// yet rekeyed by its SSE `bubble` event, or `local-*` user row not yet
    /// promoted by `.meta` / the realtime echo): no canonical id means we
    /// can't write a row loadHistory would recognise, and those paths fill
    /// the cache themselves. Idempotent — safe to call once per turn.
    func persistTurnToCache(userMsgId: String?) {
        guard !conversation.id.isEmpty else { return }
        var rows: [LocalDatabase.MessageRow] = []
        if let uid = userMsgId,
           !uid.hasPrefix("local-"), !uid.hasPrefix("live-"),
           let m = messages.first(where: { $0.id == uid }) {
            rows.append(LocalDatabase.MessageRow(
                id: m.id,
                client_message_id: localMsgClientIds[m.id],
                conversation_id: conversation.id,
                user_id: m.sender_id,
                sender_bot_id: nil,
                role: "user",
                content: m.content,
                status: "done",
                created_at: m.created_at
            ))
        }
        for bid in turnBubbleIds where !bid.hasPrefix("live-") {
            guard let m = messages.first(where: { $0.id == bid }) else { continue }
            rows.append(LocalDatabase.MessageRow(
                id: m.id,
                client_message_id: nil,
                conversation_id: conversation.id,
                user_id: nil,
                sender_bot_id: m.sender_id.isEmpty ? conversation.bot_id : m.sender_id,
                role: "bot",
                content: m.content,
                status: "done",
                created_at: m.created_at
            ))
        }
        guard !rows.isEmpty else { return }
        LocalDatabase.shared.upsertMessages(rows)
        // Keep the conv-list preview + ordering fresh from the same data so
        // the message list's first paint on next launch isn't a turn behind
        // either (the list has no realtime; it only refreshes on appear).
        if let last = rows.last {
            LocalDatabase.shared.touchConversationPreview(
                id: conversation.id,
                lastContent: last.content ?? "",
                lastSenderType: last.role == "bot" ? "bot" : "user",
                lastActivityAt: last.created_at
            )
        }
    }

    /// Restart the idle debounce — after `cursorBlinkAfterIdle` with no
    /// further .append on the live bubble, flip `streamPaused = true`
    /// so the cursor switches from solid to TTY-style blink.
    private func scheduleBlinkAfterIdle() {
        revealTask?.cancel()
        let delayNs = UInt64(Self.cursorBlinkAfterIdle * 1_000_000_000)
        revealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNs)
            if !Task.isCancelled, revealTargetId != nil {
                streamPaused = true
            }
        }
    }

    /// Tear down any in-flight streaming state — called when the user
    /// hits Stop, sends another message, or switches conv. With paced
    /// reveal gone there's no buffer to flush; this just drops the
    /// cursor + cancels the blink debounce.
    func flushRevealImmediately() {
        revealTask?.cancel()
        revealTask = nil
        revealTargetId = nil
        streamPaused = false
    }
}
