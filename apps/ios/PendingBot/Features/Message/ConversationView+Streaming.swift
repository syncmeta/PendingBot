import Foundation
import OSLog
import SwiftUI

private let streamingLog = Logger.category("ConversationView.Streaming")

// Streaming reveal smoother + bubble emission router.
//
// Two surfaces:
//   • applyBubbleEmissions / applyDirect — translate the SSE event
//     stream (begin / append / end / turn-done / error) into local
//     ChatMessage mutations.
//   • startRevealTaskIfNeeded / flushRevealImmediately — paced
//     typewriter that drains the head-buffer at ~60 fps so a fast
//     LLM stream doesn't render as a single jump.
//
// Reveal-task tuning lives here too (revealCharsPerSec /
// revealMaxBehindSec) as ConversationView-scoped statics — kept on
// the type so the timing parameters stay co-located with the loop
// that uses them.

extension ConversationView {

    /// Tuning: nominal reveal rate. ~60 tokens/sec × ~3 chars/token =
    /// 180 chars/sec across mixed CJK / ASCII content. Anything slower
    /// than the live stream means the typewriter falls behind and the
    /// visible reveal jumps to the canonical row when Realtime lands.
    /// The adaptive drain in startRevealTaskIfNeeded still catches up
    /// when the provider bursts faster than this, so the floor here is
    /// "no slower than".
    static let revealCharsPerSec: Double = 180

    /// Cap on how far the visible reveal is allowed to lag behind the
    /// live stream. Anything queued beyond this many seconds of
    /// base-rate output is drained on the current frame.
    static let revealMaxBehindSec: Double = 0.1

    /// Translate a batch of SSE-derived bubble events into local
    /// ChatMessage mutations.
    ///
    /// Streaming bubbles get routed through the reveal smoother:
    /// `.begin` appends an empty bubble and stashes the head buffer
    /// for paced reveal; subsequent `.append` events feed that
    /// buffer; events that belong to *other* bubbles get queued
    /// behind so the next bubble doesn't appear before the typewriter
    /// is done.
    func applyBubbleEmissions(_ events: [BubbleEmission]) {
        for evt in events {
            if let target = revealTargetId {
                switch evt {
                case .append(let id, let delta) where "live-\(id.uuidString)" == target:
                    revealBuffer += delta
                    continue
                case .end(let id) where "live-\(id.uuidString)" == target:
                    revealEnded = true
                    continue
                default:
                    pendingEmissions.append(evt)
                    continue
                }
            }
            applyDirect(evt)
        }
    }

    func applyDirect(_ evt: BubbleEmission) {
        switch evt {
        case .begin(let id, let mode, let content):
            let key = "live-\(id.uuidString)"
            let initial = mode == .streaming ? "" : content
            messages.append(ChatMessage(
                id: key,
                conversation_id: conversation.id,
                sender_type: "bot",
                sender_id: conversation.bot_id,
                content: initial,
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
                revealBuffer = content
                revealEnded = false
                // Soft bump on the first streaming bubble so the user
                // feels the bot start "typing" — matches ChatGPT iOS.
                Haptics.receive()
                startRevealTaskIfNeeded()
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
        case .end, .turnDone, .turnInterrupted:
            break
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

    /// Spin up the 60-fps reveal pump if one isn't already running.
    /// Drains revealBuffer onto the target bubble at a paced rate, with
    /// an adaptive overflow drain so a fast LLM doesn't backpressure
    /// the visible reveal indefinitely. Exits when revealTargetId is
    /// cleared (turn ended or interrupted).
    func startRevealTaskIfNeeded() {
        guard revealTask == nil else { return }
        // Cursor goes solid the moment a stream takes over the bubble.
        // The blink only kicks in if we then sit idle waiting for tokens.
        streamPaused = false
        revealTask = Task { @MainActor in
            let frameNs: UInt64 = 16_000_000   // ~60 fps
            let perFrame = Self.revealCharsPerSec * Double(frameNs) / 1_000_000_000
            let maxBehindChars = Int(Self.revealCharsPerSec * Self.revealMaxBehindSec)
            var carry: Double = 0
            // Empty-buffer dwell time before flipping the cursor into
            // blink mode. Shorter than the blink period so the user sees
            // at least one blink cycle before tokens land again.
            let pauseDelay: TimeInterval = 0.35
            var idleSince: Date? = nil
            while !Task.isCancelled, revealTargetId != nil {
                try? await Task.sleep(nanoseconds: frameNs)
                carry += perFrame
                // Catch-up: if buffer holds more than maxBehindChars, drain
                // the overflow this frame so we don't lag behind a fast LLM.
                let baseAdvance = Int(carry)
                let overflow = max(0, revealBuffer.count - maxBehindChars)
                let advance = baseAdvance + overflow
                if advance > 0, !revealBuffer.isEmpty, let target = revealTargetId {
                    carry -= Double(baseAdvance)
                    let take = min(advance, revealBuffer.count)
                    let chunk = String(revealBuffer.prefix(take))
                    revealBuffer.removeFirst(take)
                    if let idx = messages.lastIndex(where: { $0.id == target }) {
                        let prev = messages[idx]
                        messages[idx] = ChatMessage(
                            id: prev.id, conversation_id: prev.conversation_id,
                            sender_type: prev.sender_type, sender_id: prev.sender_id,
                            content: prev.content + chunk,
                            created_at: prev.created_at,
                            attachments: prev.attachments
                        )
                    }
                    // Throttled inside Haptics — we can call every frame
                    // here without flooding the actuator.
                    Haptics.streamTick()
                    idleSince = nil
                    if streamPaused { streamPaused = false }
                } else if revealBuffer.isEmpty && !revealEnded {
                    // No tokens to drain and the producer hasn't signaled
                    // end-of-turn — we're between chunks. Flip to blink
                    // after a short dwell so a one-frame lull doesn't
                    // visibly toggle the cursor.
                    let now = Date()
                    if let since = idleSince {
                        if !streamPaused, now.timeIntervalSince(since) >= pauseDelay {
                            streamPaused = true
                        }
                    } else {
                        idleSince = now
                    }
                }
                if revealEnded && revealBuffer.isEmpty {
                    let queued = pendingEmissions
                    pendingEmissions.removeAll()
                    revealTargetId = nil
                    revealEnded = false
                    streamPaused = false
                    revealTask = nil
                    if !queued.isEmpty {
                        applyBubbleEmissions(queued)
                    }
                    return
                }
            }
            streamPaused = false
            revealTask = nil
        }
    }

    /// Skip the typewriter and apply everything pending immediately.
    /// Called when the user interrupts (Stop button), navigates away,
    /// or fires another send — they want the full content now, not the
    /// rest of the animation.
    func flushRevealImmediately() {
        revealTask?.cancel()
        revealTask = nil
        if let target = revealTargetId, !revealBuffer.isEmpty,
           let idx = messages.lastIndex(where: { $0.id == target }) {
            let prev = messages[idx]
            messages[idx] = ChatMessage(
                id: prev.id, conversation_id: prev.conversation_id,
                sender_type: prev.sender_type, sender_id: prev.sender_id,
                content: prev.content + revealBuffer,
                created_at: prev.created_at,
                attachments: prev.attachments
            )
        }
        revealBuffer = ""
        revealTargetId = nil
        revealEnded = false
        streamPaused = false
        let queued = pendingEmissions
        pendingEmissions.removeAll()
        // User wants everything visible now — force-flatten any queued
        // .begin(streaming) into complete bubbles so we don't kick off
        // another typewriter for the next bubble in the chain.
        for evt in queued {
            switch evt {
            case .begin(let id, _, let content):
                applyDirect(.begin(id: id, mode: .complete, content: content))
            default:
                applyDirect(evt)
            }
        }
    }
}
