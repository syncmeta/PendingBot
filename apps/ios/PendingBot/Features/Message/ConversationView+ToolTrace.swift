import Foundation
import Supabase

// Tool-call trace accumulation. The SSE turn emits `tool_call` /
// `tool_result` events per round; we bucket them by user-message id so
// the inline ToolTraceView (rendered between the user bubble and the
// bot's reply) can show "搜索 X · 读 host.com" type breadcrumbs.
//
// Also lives here: `parseCitations`, which decodes the `citations`
// jsonb on a Realtime row into the typed array.

extension ConversationView {

    func appendToolCall(name: String, input: String?) {
        guard let key = liveTraceUserMsgId else { return }
        var bucket = tracesByUserMsgId[key] ?? []
        bucket.append(ToolTraceEvent(name: name, input: input))
        tracesByUserMsgId[key] = bucket
    }

    func completeToolCall(name: String, summary: String?, error: String?, detail: String?) {
        guard let key = liveTraceUserMsgId else { return }
        var bucket = tracesByUserMsgId[key] ?? []
        // Match the most recent unfinished event with the same tool name.
        // Bot can issue parallel tool calls; FIFO completion is wrong in
        // theory but right in practice for our current 2-tool surface.
        if let idx = bucket.lastIndex(where: { $0.name == name && !$0.done }) {
            bucket[idx].resultSummary = summary
            bucket[idx].resultError = error
            bucket[idx].resultDetail = detail
            bucket[idx].done = true
        } else {
            // Result without a matching call (shouldn't happen but stay
            // defensive — the worker's emitter could miss a tool_call).
            var ev = ToolTraceEvent(name: name, input: nil)
            ev.resultSummary = summary
            ev.resultError = error
            ev.resultDetail = detail
            ev.done = true
            bucket.append(ev)
        }
        tracesByUserMsgId[key] = bucket
    }

    /// AnyJSON → [MessageCitation]. Tolerates the literal `null`
    /// encoding (jsonb NULL serialises to "null") which the array
    /// decoder would otherwise throw on.
    func parseCitations(from any: AnyJSON?) -> [MessageCitation]? {
        guard let any else { return nil }
        do {
            let data = try JSONEncoder().encode(any)
            // AnyJSON.null encodes as the literal "null" — short-circuit
            // before the array decoder throws on the wrong shape.
            if data.count == 4, String(data: data, encoding: .utf8) == "null" {
                return nil
            }
            return try JSONDecoder().decode([MessageCitation].self, from: data)
        } catch {
            return nil
        }
    }

    func parsePersistedToolTrace(from any: AnyJSON?) -> ([ToolTraceEvent], [MessageCitation])? {
        guard let any else { return nil }
        do {
            let data = try JSONEncoder().encode(any)
            if data.count == 4, String(data: data, encoding: .utf8) == "null" {
                return nil
            }
            let metadata = try JSONDecoder().decode(ToolTraceMetadata.self, from: data)
            let events = metadata.tool_trace ?? []
            let citations = metadata.tool_citations ?? []
            if events.isEmpty && citations.isEmpty { return nil }
            return (events, citations)
        } catch {
            return nil
        }
    }
}

private struct ToolTraceMetadata: Decodable {
    let tool_trace: [ToolTraceEvent]?
    let tool_citations: [MessageCitation]?
}
