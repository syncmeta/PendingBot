import Foundation
import Supabase

// 来信/Envelope networking layer — REST writes go through APIClient
// (POST /v1/envelope/...), reads pull from Supabase directly the same way
// FriendsTab queries `bots`. Realtime is a feed-level channel filtered
// by user_id so the article list updates without polling.

// NOTE: the `EnvelopeRun` row model + the `envelope_runs` read queries moved to
// the shared `EnvelopeFetch` (Networking/EnvelopeFetch.swift) so iOS + macOS run
// one query shape. iOS reads `EnvelopeFetch.list()` / `.get(id:)` below; the
// realtime feed channel + compose writes stay iOS-side here.

extension APIClient {
    /// Kicks off a new envelope (envelope_runs) for the given conversation.
    /// The run uses the bot's own envelope defaults (bots.config.envelope).
    /// Returns the run id immediately; the runner streams progress via
    /// Realtime. Caller subscribes to the feed channel to watch it.
    func envelopeTrigger(conversationId: String) async throws -> String {
        struct Body: Encodable {
            let conversationId: String
        }
        struct Resp: Decodable { let envelopeRunId: String }
        let resp: Resp = try await post(
            "v1/envelope/trigger",
            body: Body(conversationId: conversationId)
        )
        return resp.envelopeRunId
    }

    /// Marks a running envelope as cancelled. The runner notices on its
    /// next turn and exits cleanly.
    func envelopeCancel(id: String) async throws {
        try await postVoid("v1/envelope/\(id)/cancel")
    }

    /// Send a markdown letter to a mutual friend (kind='human' row in
    /// envelope_runs). The recipient sees it on their own 来信 tab via
    /// the same realtime feed channel that bot envelopes use. Server
    /// returns 403 / `not_mutual_friends` if the friendship requirement
    /// fails — APIClient surfaces that as an error the caller can show.
    func envelopeSendLetter(
        conversationId: String,
        recipientUserId: String,
        title: String?,
        bodyMd: String
    ) async throws -> String {
        struct Body: Encodable {
            let conversationId: String
            let recipientUserId: String
            let title: String?
            let bodyMd: String
        }
        struct Resp: Decodable { let envelopeRunId: String }
        let resp: Resp = try await post(
            "v1/envelope/letter",
            body: Body(
                conversationId: conversationId,
                recipientUserId: recipientUserId,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                bodyMd: bodyMd
            )
        )
        return resp.envelopeRunId
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// ── Envelope settings (bot-level) ────────────────────────────────────────
//
// Mirrors the shape of EnvelopeSettings on the edge runner — explorer
// model, optional collaborator model, search/scrape provider, turn cap.
// Edited in BotConfigView and stored on `bots.config.envelope` (JSONB);
// the worker reads it as the envelope run's defaults.

/// Search providers the runner knows. `brave` is the default.
enum EnvelopeSearchProvider: String, Codable, CaseIterable, Hashable {
    case brave, tavily, exa, serper
    var label: String {
        switch self {
        case .brave:  return "Brave"
        case .tavily: return "Tavily"
        case .exa:    return "Exa"
        case .serper: return "Serper"
        }
    }
}

/// Scrape providers the runner knows. `firecrawl` is the default.
enum EnvelopeScrapeProvider: String, Codable, CaseIterable, Hashable {
    case firecrawl, tavily, exa
    var label: String {
        switch self {
        case .firecrawl: return "Firecrawl"
        case .tavily:    return "Tavily"
        case .exa:       return "Exa"
        }
    }
}

struct EnvelopeSettings: Codable, Hashable {
    /// Empty string = "follow server": the worker resolves the board's
    /// `envelopeExplorer` model-role. A non-empty slug pins the explorer.
    var explorerModel: String
    /// nil = "follow server": the worker resolves the board's
    /// `envelopeCollaborator` model-role. A non-empty slug pins it. (The
    /// worker always runs a collaborator pass — there is no client-pinnable
    /// "no collaborator" mode — so nil means default, not none.)
    var collaboratorModel: String?
    var searchProvider: EnvelopeSearchProvider
    var scrapeProvider: EnvelopeScrapeProvider
    var turnCap: Int
    /// Percentage of the bot's main-model context window allotted to
    /// (chat history + framing prompts). The runner trims newest-first
    /// across every conversation between this user and this bot. 35%
    /// is a balanced default; higher = more recall, less room for the
    /// research loop.
    var historyTokenBudgetPct: Int

    // Model defaults are intentionally "follow server" (empty explorer /
    // nil collaborator) — the bootstrap default lives in the board's
    // model-roles, not hardcoded here. On save these go out as JSON null so
    // the worker resolves the role (envelope-runner.resolveEnvelopeSettings),
    // keeping the board the single source of truth.
    static let defaults = EnvelopeSettings(
        explorerModel: "",
        collaboratorModel: nil,
        searchProvider: .brave,
        scrapeProvider: .firecrawl,
        turnCap: 15,
        historyTokenBudgetPct: 35
    )

    /// Decode from a Supabase JSONB blob (`AnyJSON`). Tolerant: missing
    /// fields fall back to defaults so older rows still render.
    static func from(_ json: AnyJSON?) -> EnvelopeSettings {
        var s = EnvelopeSettings.defaults
        guard let json, case let .object(dict) = json else { return s }
        if case let .string(v)? = dict["explorerModel"], !v.isEmpty {
            s.explorerModel = v
        }
        if case let .string(v)? = dict["collaboratorModel"] {
            s.collaboratorModel = v.isEmpty ? nil : v
        } else if case .null = dict["collaboratorModel"] {
            s.collaboratorModel = nil
        }
        if case let .string(v)? = dict["searchProvider"],
           let p = EnvelopeSearchProvider(rawValue: v) {
            s.searchProvider = p
        }
        if case let .string(v)? = dict["scrapeProvider"],
           let p = EnvelopeScrapeProvider(rawValue: v) {
            s.scrapeProvider = p
        }
        if case let .integer(v)? = dict["turnCap"], v > 0 {
            s.turnCap = v
        } else if case let .double(v)? = dict["turnCap"], v > 0 {
            s.turnCap = Int(v)
        }
        if case let .integer(v)? = dict["historyTokenBudgetPct"], v > 0, v <= 100 {
            s.historyTokenBudgetPct = v
        } else if case let .double(v)? = dict["historyTokenBudgetPct"], v > 0, v <= 100 {
            s.historyTokenBudgetPct = Int(v.rounded())
        }
        return s
    }
}

// ── Realtime feed channel ────────────────────────────────────────────────
//
// One WebSocket per signed-in user to the user-level realtime hub
// (/v1/realtime-hub/user), opened when the Envelope tab appears, closed
// when it disappears. The user topic carries envelope_runs changes
// (alongside user_unread_counts, which RealtimeManager consumes on its
// own socket) — this channel keeps only the envelope_runs rows. iOS
// callers receive INSERT / UPDATE / DELETE as raw records and decode
// them locally.

/// Token returned by `start`; pass it back to `stop` to detach.
struct EnvelopeFeedToken: Hashable, Sendable {
    let id: UUID
    let userId: String
}

@MainActor
final class EnvelopeFeedChannel {
    static let shared = EnvelopeFeedChannel()
    private init() {}

    private var socket: RealtimeSocket?
    private var observers: [UUID: ObserverFns] = [:]
    private var currentUserId: String?

    typealias UpsertHandler = @Sendable ([String: AnyJSON]) -> Void
    typealias DeleteHandler = @Sendable ([String: AnyJSON]) -> Void
    private struct ObserverFns {
        let upsert: UpsertHandler
        let delete: DeleteHandler
    }

    func start(
        userId: String,
        onUpsert: @escaping UpsertHandler,
        onDelete: @escaping DeleteHandler
    ) async -> EnvelopeFeedToken {
        let token = EnvelopeFeedToken(id: UUID(), userId: userId)
        observers[token.id] = ObserverFns(upsert: onUpsert, delete: onDelete)

        // Already connected for this user — just hook in the new observers.
        if socket != nil, currentUserId == userId {
            return token
        }
        // Different user (sign-out + sign-in flow) — drop the old socket.
        if socket != nil { tearDown() }

        currentUserId = userId
        let sock = RealtimeSocket(path: "v1/realtime-hub/user") { [weak self] change in
            // The user topic also carries user_unread_counts; keep only
            // envelope feed rows.
            guard change.table == "envelope_runs", let self else { return }
            for (_, obs) in self.observers {
                // DELETE carries the row from the webhook's old_record —
                // the id is what feed state keys off.
                if change.op == .delete {
                    obs.delete(change.record)
                } else {
                    obs.upsert(change.record)
                }
            }
        }
        sock.start()
        socket = sock
        return token
    }

    func stop(_ token: EnvelopeFeedToken) async {
        observers.removeValue(forKey: token.id)
        if observers.isEmpty {
            tearDown()
        }
    }

    private func tearDown() {
        socket?.stop()
        socket = nil
        currentUserId = nil
    }
}

// ── Progress ─────────────────────────────────────────────────────────────

/// Typed view of the JSONB `progress` blob the runner writes (see
/// `apps/edge/src/lib/envelope-runner.ts` — `ProgressState`). Every field
/// is optional so older rows / drift in shape still render something.
struct EnvelopeProgress {
    let phase: String?
    /// Live "what's happening right now" line written by the runner
    /// between awaits (model call → tools → collaborator). When set,
    /// this is what the UI shows next to the typing dots so a slow
    /// turn doesn't look frozen. Cleared by the runner at end of turn.
    let currentActivity: String?
    let notes: [Note]
    let visitedURLs: [String]

    struct Note: Hashable {
        let text: String
        let source: String?
    }

    static let empty = EnvelopeProgress(phase: nil, currentActivity: nil, notes: [], visitedURLs: [])

    static func from(_ json: AnyJSON?) -> EnvelopeProgress {
        guard let json, case let .object(dict) = json else { return .empty }

        var phase: String?
        if case let .string(s)? = dict["phase"] { phase = s }

        var currentActivity: String?
        if case let .string(s)? = dict["current_activity"], !s.isEmpty {
            currentActivity = s
        }

        var notes: [Note] = []
        if case let .array(arr)? = dict["notes"] {
            for item in arr {
                guard case let .object(n) = item,
                      case let .string(text)? = n["text"],
                      !text.isEmpty
                else { continue }
                var source: String?
                if case let .string(s)? = n["source"], !s.isEmpty { source = s }
                notes.append(Note(text: text, source: source))
            }
        }

        var urls: [String] = []
        if case let .array(arr)? = dict["visited_urls"] {
            for item in arr {
                if case let .string(s) = item, !s.isEmpty { urls.append(s) }
            }
        }

        return EnvelopeProgress(phase: phase, currentActivity: currentActivity, notes: notes, visitedURLs: urls)
    }
}

/// Human label for a runner phase (`"research"` → `"上网查证"`). Falls
/// back to the raw value when the phase is unknown, and to a generic
/// "拟稿中" when nothing has been written yet.
enum EnvelopePhaseLabel {
    static func text(_ phase: String?) -> String {
        switch phase {
        case "queued":   return "排队中"
        case "gather":   return "翻最近的对话"
        case "plan":     return "整理思路"
        case "research": return "上网查证"
        case "compose":  return "落笔"
        case "done":     return "收尾"
        case "error":    return "写信失败"
        case .some(let p) where !p.isEmpty: return p
        default:         return "写信中"
        }
    }
}

// ── Envelope thinking trace ──────────────────────────────────────────────
//
// Mirrors the wire shape the runner appends to envelope_runs.turns
// (apps/edge/src/lib/envelope-runner.ts: TurnTraceEntry). The detail page
// renders these as the "thinking process" so users can see what the
// model thought + searched + scraped on the way to the final article.

struct EnvelopeToolCall: Hashable {
    let name: String
    let argsJSON: String
}

struct EnvelopeToolResult: Hashable {
    let content: String
}

struct EnvelopeTurn: Hashable, Identifiable {
    let i: Int
    let assistant: String?
    let reasoning: String?
    let toolCalls: [EnvelopeToolCall]
    let toolResults: [EnvelopeToolResult]
    let collaborator: String?

    var id: Int { i }

    static func parse(_ json: AnyJSON?) -> [EnvelopeTurn] {
        guard let json, case let .array(items) = json else { return [] }
        var out: [EnvelopeTurn] = []
        for item in items {
            guard case let .object(d) = item else { continue }
            let i: Int
            if case let .integer(v)? = d["i"] {
                i = v
            } else if case let .double(v)? = d["i"] {
                i = Int(v)
            } else {
                continue
            }
            var assistant: String?
            if case let .string(s)? = d["assistant"], !s.isEmpty { assistant = s }
            var reasoning: String?
            if case let .string(s)? = d["reasoning"], !s.isEmpty { reasoning = s }
            var collaborator: String?
            if case let .string(s)? = d["collaborator"], !s.isEmpty { collaborator = s }

            var toolCalls: [EnvelopeToolCall] = []
            if case let .array(arr)? = d["tool_calls"] {
                for tc in arr {
                    guard case let .object(t) = tc else { continue }
                    var name = ""
                    if case let .string(s)? = t["name"] { name = s }
                    var argsJSON = ""
                    if let argsAny = t["args"] {
                        argsJSON = anyJSONToCompactString(argsAny)
                    }
                    if !name.isEmpty {
                        toolCalls.append(EnvelopeToolCall(name: name, argsJSON: argsJSON))
                    }
                }
            }

            var toolResults: [EnvelopeToolResult] = []
            if case let .array(arr)? = d["tool_results"] {
                for tr in arr {
                    guard case let .object(t) = tr else { continue }
                    var content = ""
                    if case let .string(s)? = t["content"] { content = s }
                    if !content.isEmpty {
                        toolResults.append(EnvelopeToolResult(content: content))
                    }
                }
            }

            out.append(EnvelopeTurn(
                i: i,
                assistant: assistant,
                reasoning: reasoning,
                toolCalls: toolCalls,
                toolResults: toolResults,
                collaborator: collaborator
            ))
        }
        return out
    }
}

/// Best-effort one-line render of an AnyJSON tool-call args blob. Keeps
/// the trace compact — the user wants a sense of what the agent did,
/// not the full JSON dump.
private func anyJSONToCompactString(_ json: AnyJSON) -> String {
    switch json {
    case .null:                     return "null"
    case .bool(let b):              return b ? "true" : "false"
    case .integer(let i):           return String(i)
    case .double(let d):            return String(d)
    case .string(let s):            return s
    case .array(let arr):
        let inner = arr.map(anyJSONToCompactString).joined(separator: ", ")
        return "[\(inner)]"
    case .object(let obj):
        // Pull a few well-known top-level fields the loop tools use,
        // else fall through to a small key=value summary.
        if case let .string(s)? = obj["thoughts"] { return s }
        if case let .string(s)? = obj["query"]    { return s }
        if case let .string(s)? = obj["url"]      { return s }
        if case let .string(s)? = obj["text"]     { return s }
        if case let .string(s)? = obj["reason"]   { return s }
        let pairs = obj
            .map { (k: String, v: AnyJSON) in "\(k)=\(anyJSONToCompactString(v))" }
            .joined(separator: ", ")
        return pairs
    }
}

// ── Decoding helpers ─────────────────────────────────────────────────────

enum EnvelopeRunDecoder {
    /// Decode a Realtime record (`[String: AnyJSON]`) into a EnvelopeRun.
    /// Returns nil if the row is missing required fields — defensive in
    /// case the publication shape changes upstream.
    static func decode(_ record: [String: AnyJSON]) -> EnvelopeRun? {
        guard
            let id = record["id"]?.stringValue,
            let conv = record["conversation_id"]?.stringValue,
            let status = record["status"]?.stringValue,
            let createdAt = record["created_at"]?.stringValue
        else {
            return nil
        }
        // bot_id is now nullable (kind='human' rows have no bot). Default
        // kind to 'bot' so realtime rows from old workers / pre-migration
        // backfill still decode without surfacing a nil.
        return EnvelopeRun(
            id: id,
            bot_id: record["bot_id"]?.stringValue,
            author_user_id: record["author_user_id"]?.stringValue,
            kind: record["kind"]?.stringValue ?? "bot",
            trigger: record["trigger"]?.stringValue,
            conversation_id: conv,
            status: status,
            title: record["title"]?.stringValue,
            summary: record["summary"]?.stringValue,
            body_md: record["body_md"]?.stringValue,
            progress: record["progress"],
            turns: record["turns"],
            created_at: createdAt,
            started_at: record["started_at"]?.stringValue,
            finished_at: record["finished_at"]?.stringValue
        )
    }
}
