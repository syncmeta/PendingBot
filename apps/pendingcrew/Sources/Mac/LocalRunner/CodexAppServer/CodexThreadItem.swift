#if os(macOS)
import Foundation

/// A codex `ThreadItem` reduced to what the transcript renders. `.unknown`
/// keeps forward-compat: a codex upgrade adding a new arm degrades to a raw
/// row instead of failing the decode.
///
/// Field names follow the documented shapes in
/// `docs/superpowers/specs/2026-06-05-codex-app-server-reference.md`.
/// Field-name reconciliation against a real `codex app-server` capture is a
/// real-machine tail item (out of scope for Task 2.1).
struct CodexThreadItem: Decodable, Identifiable, Equatable {
    let id: String
    let kind: Kind

    enum Kind: Equatable {
        case userMessage(text: String)
        case agentMessage(text: String, phase: String?)
        case reasoning(summary: String?, content: String?)
        case plan(text: String)
        case commandExecution(CommandExec)
        case fileChange(FileChange)
        case toolCall(name: String, status: String?)   // mcp/dynamic/collab folded
        case webSearch(query: String?)
        case unknown(type: String)
    }

    struct CommandExec: Equatable {
        let command: String
        let cwd: String?
        let status: String?
        let aggregatedOutput: String?
        let exitCode: Int?
    }

    struct FileChange: Equatable {
        let status: String?
        let summary: String?
    }

    private enum Keys: String, CodingKey {
        case id, type, text, phase, summary, content, command, cwd, status
        case aggregatedOutput, exitCode, name, query
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        let type = (try? c.decode(String.self, forKey: .type)) ?? "unknown"
        func s(_ k: Keys) -> String? { try? c.decode(String.self, forKey: k) }
        switch type {
        case "userMessage":
            kind = .userMessage(text: s(.text) ?? "")
        case "agentMessage":
            kind = .agentMessage(text: s(.text) ?? "", phase: s(.phase))
        case "reasoning":
            kind = .reasoning(summary: s(.summary), content: s(.content))
        case "plan":
            kind = .plan(text: s(.text) ?? "")
        case "commandExecution":
            kind = .commandExecution(.init(
                command: s(.command) ?? "",
                cwd: s(.cwd),
                status: s(.status),
                aggregatedOutput: s(.aggregatedOutput),
                exitCode: try? c.decode(Int.self, forKey: .exitCode)
            ))
        case "fileChange":
            kind = .fileChange(.init(status: s(.status), summary: s(.summary)))
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            kind = .toolCall(name: s(.name) ?? type, status: s(.status))
        case "webSearch":
            kind = .webSearch(query: s(.query))
        default:
            kind = .unknown(type: type)
        }
    }
}
#endif
