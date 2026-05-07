import Foundation

/// Pure logic for splitting a bot's token stream into bubbles per the
/// product rule (Worker emits `\n---\n` as the canonical bubble delimiter):
///
///   1. Buffer tokens until we see `\n---\n` → emit complete bubble
///   2. If buffer length crosses OVERFLOW_CHARS without a delimiter:
///      → start streaming the *current* buffer as the head of a new bubble
///      → keep appending tokens to that bubble until the next delimiter
///        (or stream end), at which point we close it
///
/// Threshold rationale: short replies (≤ this many chars before the first
/// delimiter or end-of-turn) feel best when they pop in whole — streaming
/// a 10-char "好的，明白了" looks fussy. Anything longer, the user has been
/// staring at a typing indicator long enough that streaming is reassuring.
/// 15 chars ≈ a short Chinese clause.
let BUBBLE_OVERFLOW_CHARS = 15
let BUBBLE_DELIMITER = "\n---\n"

enum BubbleEmission: Sendable, Equatable {
    /// New bubble starts. Mode = .complete means the content is final and
    /// arrives whole (a fast short bubble); .streaming means subsequent
    /// `.append` events carry tokens to add to its tail.
    case begin(id: UUID, mode: BubbleMode, content: String)
    case append(id: UUID, delta: String)
    case end(id: UUID)
    case turnDone(totalContent: String)
    case turnInterrupted(totalContent: String)
    case error(message: String)
}

enum BubbleMode: Sendable, Equatable { case complete, streaming }

/// Stateful splitter. Feed tokens via `accept(_:)`, optionally announce
/// turn end via `flush()`, and consume emissions from `output`.
final class BubbleSplitter: @unchecked Sendable {
    private var buffer = ""
    private var liveBubbleId: UUID?
    private var emissions: [BubbleEmission] = []

    /// Pull all emissions accumulated since the last call. Caller drains
    /// after each `accept()` or `flush()`.
    func drain() -> [BubbleEmission] {
        let out = emissions
        emissions.removeAll(keepingCapacity: true)
        return out
    }

    /// Feed a token delta from the SSE stream.
    func accept(token delta: String) {
        if let live = liveBubbleId {
            // Already streaming the current bubble. Look for delimiter
            // straddling old buffer + new delta (delimiter can span chunks).
            buffer += delta
            // We may emit the part *before* delimiter as an append, then
            // close the bubble, then keep the remainder for the next.
            if let range = buffer.range(of: BUBBLE_DELIMITER) {
                let head = String(buffer[..<range.lowerBound])
                if !head.isEmpty {
                    emissions.append(.append(id: live, delta: head))
                }
                emissions.append(.end(id: live))
                liveBubbleId = nil
                buffer = String(buffer[range.upperBound...])
                // Buffer holds whatever came after the delimiter; treat it
                // as fresh "pending" content (drop into the no-live path).
                drainPending()
            } else {
                // No delimiter yet — append the whole new delta to the live
                // bubble. We don't keep streaming buffer in `buffer` after
                // the head was already emitted, so reset and stash only
                // what we couldn't be sure didn't end mid-delimiter.
                let safeAppend = String(delta)
                emissions.append(.append(id: live, delta: safeAppend))
                buffer = ""
            }
            return
        }

        // No live bubble — accumulate into pending and watch for either a
        // delimiter (emit a complete bubble) or overflow (promote to
        // streaming).
        buffer += delta
        drainPending()
    }

    /// Drain everything still in buffer; called when token stream ends
    /// naturally OR the turn finished. Followed by a turnDone/turnInterrupted
    /// announcement from the caller.
    func flushTail() {
        if let live = liveBubbleId {
            // Whatever's in buffer is a continuation of the live bubble.
            if !buffer.isEmpty {
                emissions.append(.append(id: live, delta: buffer))
            }
            emissions.append(.end(id: live))
            liveBubbleId = nil
            buffer = ""
            return
        }
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let id = UUID()
            emissions.append(.begin(id: id, mode: .complete, content: trimmed))
            emissions.append(.end(id: id))
        }
        buffer = ""
    }

    /// Signal that the whole turn finished cleanly. Caller invokes after
    /// flushTail().
    func turnDone(totalContent: String) {
        emissions.append(.turnDone(totalContent: totalContent))
    }

    /// Signal that the turn was interrupted (server-side or by the user
    /// closing the SSE).
    func turnInterrupted(totalContent: String) {
        emissions.append(.turnInterrupted(totalContent: totalContent))
    }

    func reportError(_ message: String) {
        emissions.append(.error(message: message))
    }

    // MARK: - Private

    /// Try to drain `buffer` while no bubble is live: emit any complete
    /// bubbles delimited by `\n---\n`, then if remainder crosses overflow,
    /// promote to streaming.
    private func drainPending() {
        while let range = buffer.range(of: BUBBLE_DELIMITER) {
            let head = String(buffer[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[range.upperBound...])
            if !head.isEmpty {
                let id = UUID()
                emissions.append(.begin(id: id, mode: .complete, content: head))
                emissions.append(.end(id: id))
            }
        }
        if buffer.count >= BUBBLE_OVERFLOW_CHARS && liveBubbleId == nil {
            // Promote: emit the current buffer as the head of a streaming
            // bubble, then start appending future deltas to it.
            let id = UUID()
            liveBubbleId = id
            emissions.append(.begin(id: id, mode: .streaming, content: buffer))
            buffer = ""
        }
    }
}
