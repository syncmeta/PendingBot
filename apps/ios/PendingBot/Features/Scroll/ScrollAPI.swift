import Foundation
import Supabase
import Realtime

// 奏折/Scroll networking layer — REST writes go through APIClient
// (POST /v1/scroll/...), reads pull from Supabase directly the same way
// FriendsTab queries `bots`. Realtime is a feed-level channel filtered
// by user_id so the article list updates without polling.

/// One row from `pendingbot.scroll_runs`. Covers every status — UI uses
/// `status` to decide between shimmer / article / hide. `body_md` is
/// only present once status flips to "done"; `summary` may be set
/// earlier but the runner won't write it until the article is final.
struct ScrollRun: Codable, Identifiable, Hashable {
    let id: String
    let bot_id: String
    let conversation_id: String
    let status: String
    let title: String?
    let summary: String?
    let body_md: String?
    let progress: AnyJSON?
    /// Per-turn trace appended by the runner — assistant text, reasoning
    /// content, tool calls/results, collaborator replies. Drives the
    /// thinking-process panel on the Envelope detail page. Optional because
    /// older rows pre-migration won't have it.
    let turns: AnyJSON?
    let created_at: String
    let started_at: String?
    let finished_at: String?

    var isDone: Bool { status == "done" && body_md != nil }
    var isRunning: Bool { status == "running" }
}

extension APIClient {
    /// Kicks off a new envelope (scroll_runs) for the given conversation.
    /// `settings` lets the caller override the conversation's saved
    /// envelope_settings — the worker persists whatever the caller sent
    /// back onto the conversation row so the next trigger inherits.
    /// Returns the run id immediately; the runner streams progress via
    /// Realtime. Caller subscribes to the feed channel to watch it.
    func scrollTrigger(conversationId: String, settings: EnvelopeSettings? = nil) async throws -> String {
        struct Body: Encodable {
            let conversationId: String
            let settings: EnvelopeSettings?
        }
        struct Resp: Decodable { let scrollRunId: String }
        let resp: Resp = try await post(
            "v1/scroll/trigger",
            body: Body(conversationId: conversationId, settings: settings)
        )
        return resp.scrollRunId
    }

    /// Marks a running envelope as cancelled. The runner notices on its
    /// next turn and exits cleanly.
    func scrollCancel(id: String) async throws {
        try await postVoid("v1/scroll/\(id)/cancel")
    }
}

// ── Envelope settings (per-conversation) ─────────────────────────────────
//
// Mirrors the shape of EnvelopeSettings on the edge runner — explorer
// model, optional collaborator model, search/scrape provider, turn cap.
// Stored on `conversations.envelope_settings` (JSONB); the worker reads
// it as the trigger's defaults. Sent in the trigger body so a one-off
// override doesn't have to round-trip through a separate save call.

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
    var explorerModel: String
    /// nil = no collaborator (single-explorer mode); empty string is
    /// treated the same on the wire to keep JSON shape stable.
    var collaboratorModel: String?
    var searchProvider: EnvelopeSearchProvider
    var scrapeProvider: EnvelopeScrapeProvider
    var turnCap: Int

    static let defaults = EnvelopeSettings(
        explorerModel: "~google/gemini-flash-latest",
        collaboratorModel: "~google/gemini-flash-latest",
        searchProvider: .brave,
        scrapeProvider: .firecrawl,
        turnCap: 15
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
        return s
    }
}

// ── Realtime feed channel ────────────────────────────────────────────────
//
// One channel per signed-in user, opened when the Scroll tab appears,
// closed when it disappears. The channel watches scroll_runs filtered
// by user_id; iOS callers receive INSERT / UPDATE / DELETE events as
// raw records and decode them locally.

/// Token returned by `startScrollFeedChannel`; pass it back to
/// `stopScrollFeedChannel` to detach.
struct ScrollFeedToken: Hashable, Sendable {
    let id: UUID
    let userId: String
}

@MainActor
final class ScrollFeedChannel {
    static let shared = ScrollFeedChannel()
    private init() {}

    private var channel: RealtimeChannelV2?
    private var subs: [RealtimeSubscription] = []
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
    ) async -> ScrollFeedToken {
        let token = ScrollFeedToken(id: UUID(), userId: userId)
        observers[token.id] = ObserverFns(upsert: onUpsert, delete: onDelete)

        // Already subscribed for this user — just hook in the new observers.
        if channel != nil, currentUserId == userId {
            return token
        }
        // Different user (sign-out + sign-in flow) — drop the old socket.
        if channel != nil { await tearDown() }

        currentUserId = userId
        let ch = SupabaseStack.shared.realtimeV2.channel("scroll-feed:\(userId)")
        let observersRef: () -> [UUID: ObserverFns] = { [weak self] in
            self?.observers ?? [:]
        }
        subs.append(ch.onPostgresChange(
            InsertAction.self,
            schema: "pendingbot",
            table: "scroll_runs",
            filter: "user_id=eq.\(userId)"
        ) { action in
            for (_, obs) in observersRef() { obs.upsert(action.record) }
        })
        subs.append(ch.onPostgresChange(
            UpdateAction.self,
            schema: "pendingbot",
            table: "scroll_runs",
            filter: "user_id=eq.\(userId)"
        ) { action in
            for (_, obs) in observersRef() { obs.upsert(action.record) }
        })
        subs.append(ch.onPostgresChange(
            DeleteAction.self,
            schema: "pendingbot",
            table: "scroll_runs",
            filter: "user_id=eq.\(userId)"
        ) { action in
            // DELETE only carries the primary key by default; that's fine
            // for the UI — the row id is what feed state keys off.
            for (_, obs) in observersRef() { obs.delete(action.oldRecord) }
        })
        do {
            try await ch.subscribeWithError()
        } catch {
            // If the websocket can't come up we still hand back the token —
            // observers fall back to manual refresh; keeping start() non-
            // throwing avoids a churn of `try await` at every UI call site.
        }
        channel = ch
        return token
    }

    func stop(_ token: ScrollFeedToken) async {
        observers.removeValue(forKey: token.id)
        if observers.isEmpty {
            await tearDown()
        }
    }

    private func tearDown() async {
        subs.forEach { $0.cancel() }
        subs.removeAll()
        if let ch = channel {
            await ch.unsubscribe()
            channel = nil
        }
        currentUserId = nil
    }
}

// ── Progress ─────────────────────────────────────────────────────────────

/// Typed view of the JSONB `progress` blob the runner writes (see
/// `apps/edge/src/lib/scroll-runner.ts` — `ProgressState`). Every field
/// is optional so older rows / drift in shape still render something.
struct ScrollProgress {
    let phase: String?
    let notes: [Note]
    let visitedURLs: [String]

    struct Note: Hashable {
        let text: String
        let source: String?
    }

    static let empty = ScrollProgress(phase: nil, notes: [], visitedURLs: [])

    static func from(_ json: AnyJSON?) -> ScrollProgress {
        guard let json, case let .object(dict) = json else { return .empty }

        var phase: String?
        if case let .string(s)? = dict["phase"] { phase = s }

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

        return ScrollProgress(phase: phase, notes: notes, visitedURLs: urls)
    }
}

/// Human label for a runner phase (`"research"` → `"上网查证"`). Falls
/// back to the raw value when the phase is unknown, and to a generic
/// "拟稿中" when nothing has been written yet.
enum ScrollPhaseLabel {
    static func text(_ phase: String?) -> String {
        switch phase {
        case "queued":   return "排队中"
        case "gather":   return "翻最近的对话"
        case "plan":     return "整理思路"
        case "research": return "上网查证"
        case "compose":  return "落笔"
        case "done":     return "收尾"
        case "error":    return "拟稿失败"
        case .some(let p) where !p.isEmpty: return p
        default:         return "拟稿中"
        }
    }
}

// ── Envelope thinking trace ──────────────────────────────────────────────
//
// Mirrors the wire shape the runner appends to scroll_runs.turns
// (apps/edge/src/lib/scroll-runner.ts: TurnTraceEntry). The detail page
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

enum ScrollRunDecoder {
    /// Decode a Realtime record (`[String: AnyJSON]`) into a ScrollRun.
    /// Returns nil if the row is missing required fields — defensive in
    /// case the publication shape changes upstream.
    static func decode(_ record: [String: AnyJSON]) -> ScrollRun? {
        guard
            let id = record["id"]?.stringValue,
            let bot = record["bot_id"]?.stringValue,
            let conv = record["conversation_id"]?.stringValue,
            let status = record["status"]?.stringValue,
            let createdAt = record["created_at"]?.stringValue
        else {
            return nil
        }
        return ScrollRun(
            id: id,
            bot_id: bot,
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

