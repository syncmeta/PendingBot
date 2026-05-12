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
