#if os(macOS)
import Foundation

/// A single, **runner-agnostic** transcript event, parsed out of the JSONL
/// stdout stream a coding-agent CLI emits.
///
/// Both runners stream JSONL (`claude --output-format=stream-json` /
/// `codex exec --json`) but with **different schemas**. `RunnerEventParser`
/// flattens each schema into this shared model so `CrewSessionWindowView`
/// renders one transcript grammar regardless of which CLI produced it.
///
/// Design notes:
/// - One stdout line can carry **multiple** events (a Claude `assistant`
///   message may hold a text block *and* a tool_use block), so the parser
///   returns `[RunnerEvent]`, not a single optional.
/// - Lines we recognize as **noise** (hook chatter, rate-limit pings,
///   codex `turn.started`, `item.started`/`item.updated`) parse to `[]` —
///   deliberately dropped.
/// - Lines we **can't** classify (non-JSON, or JSON with an unknown `type`)
///   surface as `.unknown(raw)` so nothing silently disappears — the UI can
///   still show them in a "raw" affordance for debugging.
public enum RunnerEvent: Equatable, Sendable {
    /// Session/thread bootstrapped. `model` is nil when the CLI doesn't
    /// announce it up front (codex reports it later, not at thread start).
    case started(model: String?, sessionId: String?)
    /// Agent reasoning / thinking. UI typically renders this collapsed.
    case reasoning(String)
    /// Assistant's user-facing message text.
    case assistant(String)
    /// The agent invoked a tool / ran a command. `title` = short label
    /// (tool name / "shell" / "edit"); `detail` = the command line, file
    /// path, or a compact arg summary when available.
    case toolCall(title: String, detail: String?)
    /// Result of a prior tool call. `isError` flags a failed tool.
    case toolResult(text: String, isError: Bool)
    /// The turn/session finished. `summary` = final assistant message when
    /// the CLI echoes one; `costUSD` when reported (Claude only).
    case finished(summary: String?, isError: Bool, costUSD: Double?)
    /// Hard error surfaced by the CLI (auth failure, turn.failed, etc.).
    case failed(String)
    /// Recognized-as-JSON-or-text but not classifiable. Kept for debugging.
    case unknown(String)
}

public enum RunnerEventParser {

    /// Parse one stdout line into zero or more `RunnerEvent`s.
    ///
    /// Never throws: malformed input degrades to `.unknown` rather than
    /// dropping data or crashing the stream observer.
    public static func parse(line rawLine: String, kind: LocalCodingAgentKind) -> [RunnerEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return [] }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Not JSON at all — CLIs occasionally interleave plain warnings.
            return [.unknown(rawLine)]
        }
        switch kind {
        case .claudeCode: return parseClaude(obj, raw: rawLine)
        case .codex: return parseCodex(obj, raw: rawLine)
        }
    }

    /// Convenience: parse a whole JSONL blob (e.g. a captured transcript).
    public static func parse(stream: String, kind: LocalCodingAgentKind) -> [RunnerEvent] {
        stream.split(separator: "\n", omittingEmptySubsequences: true)
            .flatMap { parse(line: String($0), kind: kind) }
    }

    // MARK: - Claude Code (`--output-format=stream-json`)

    private static func parseClaude(_ obj: [String: Any], raw: String) -> [RunnerEvent] {
        guard let type = obj["type"] as? String else { return [.unknown(raw)] }
        switch type {
        case "system":
            // Only `init` is interesting; hook_started/hook_response/
            // post_turn_summary are noise.
            guard (obj["subtype"] as? String) == "init" else { return [] }
            return [.started(model: obj["model"] as? String,
                             sessionId: obj["session_id"] as? String)]

        case "assistant":
            return claudeContentBlocks(obj).compactMap { block in
                guard let bt = block["type"] as? String else { return nil }
                switch bt {
                case "text":
                    let t = (block["text"] as? String) ?? ""
                    return t.isEmpty ? nil : .assistant(t)
                case "thinking":
                    let t = (block["thinking"] as? String) ?? ""
                    return t.isEmpty ? nil : .reasoning(t)
                case "tool_use":
                    let name = (block["name"] as? String) ?? "tool"
                    return .toolCall(title: name,
                                     detail: summarizeToolInput(block["input"]))
                default:
                    return nil
                }
            }

        case "user":
            // Tool results come back as a synthetic user turn.
            return claudeContentBlocks(obj).compactMap { block in
                guard (block["type"] as? String) == "tool_result" else { return nil }
                let isError = (block["is_error"] as? Bool) ?? false
                return .toolResult(text: stringifyToolResult(block["content"]),
                                   isError: isError)
            }

        case "result":
            let isError = (obj["is_error"] as? Bool) ?? false
            let summary = obj["result"] as? String
            let cost = obj["total_cost_usd"] as? Double
            return [.finished(summary: summary, isError: isError, costUSD: cost)]

        case "rate_limit_event", "stream_event":
            return []

        default:
            return [.unknown(raw)]
        }
    }

    private static func claudeContentBlocks(_ obj: [String: Any]) -> [[String: Any]] {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        return content
    }

    // MARK: - Codex (`codex exec --json`)

    private static func parseCodex(_ obj: [String: Any], raw: String) -> [RunnerEvent] {
        guard let type = obj["type"] as? String else { return [.unknown(raw)] }
        switch type {
        case "thread.started":
            return [.started(model: nil, sessionId: obj["thread_id"] as? String)]

        case "turn.started", "item.started", "item.updated":
            // Only emit on item.completed to avoid duplicates; turn.started
            // carries nothing renderable.
            return []

        case "item.completed":
            guard let item = obj["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return [.unknown(raw)] }
            switch itemType {
            case "agent_message":
                let t = (item["text"] as? String) ?? ""
                return t.isEmpty ? [] : [.assistant(t)]
            case "reasoning":
                let t = (item["text"] as? String) ?? ""
                return t.isEmpty ? [] : [.reasoning(t)]
            case "command_execution":
                let cmd = (item["command"] as? String) ?? ""
                return [.toolCall(title: "shell", detail: cmd.isEmpty ? nil : cmd)]
            case "file_change":
                return [.toolCall(title: "edit", detail: summarizeCodexFileChange(item))]
            case "mcp_tool_call":
                let server = (item["server"] as? String) ?? "mcp"
                let tool = (item["tool"] as? String) ?? "tool"
                return [.toolCall(title: "\(server)/\(tool)", detail: nil)]
            case "web_search":
                return [.toolCall(title: "web_search", detail: item["query"] as? String)]
            case "error":
                return [.failed((item["message"] as? String) ?? "unknown error")]
            case "todo_list":
                return []
            default:
                return [.unknown(raw)]
            }

        case "turn.completed":
            return [.finished(summary: nil, isError: false, costUSD: nil)]

        case "turn.failed":
            let err = obj["error"] as? [String: Any]
            return [.failed((err?["message"] as? String) ?? "turn failed")]

        case "error":
            return [.failed((obj["message"] as? String) ?? "unknown error")]

        default:
            return [.unknown(raw)]
        }
    }

    // MARK: - shared helpers

    /// Compact one-line summary of a Claude tool_use `input` object. Prefers
    /// the most human-meaningful field (`command` / `file_path` / `path`),
    /// else a short compact-JSON of the whole thing.
    static func summarizeToolInput(_ input: Any?) -> String? {
        guard let dict = input as? [String: Any] else { return nil }
        for key in ["command", "file_path", "path", "pattern", "url", "query"] {
            if let v = dict[key] as? String, !v.isEmpty { return v }
        }
        // Fall back to a stable, compact key:value render (sorted for
        // determinism — JSONSerialization key order is otherwise undefined).
        let parts = dict.keys.sorted().compactMap { key -> String? in
            guard let v = dict[key] else { return nil }
            return "\(key)=\(compactScalar(v))"
        }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func compactScalar(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        default: return "…"
        }
    }

    /// Claude tool_result `content` is either a string or an array of
    /// `{type:text,text:...}` blocks — normalize both to a plain string.
    static func stringifyToolResult(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    private static func summarizeCodexFileChange(_ item: [String: Any]) -> String? {
        guard let changes = item["changes"] as? [[String: Any]] else { return nil }
        let paths = changes.compactMap { $0["path"] as? String }
        return paths.isEmpty ? nil : paths.joined(separator: ", ")
    }
}
#endif
