import Foundation
import Supabase

// ─────────────────────────────────────────────────────────────────────
// MARK: - Shared envelope (来信) fetch (iOS + macOS one implementation)
//
// The canonical `envelope_runs` query + row model live here so iOS
// (`EnvelopeTabView`, full feed + thinking-trace + compose) and macOS
// (`EnvelopeDataSource`, a thin read-only feed) decode the SAME superset row
// instead of two hand-copied selects. macOS ignores the extra columns
// (progress / turns / timestamps); iOS uses them for the thinking-process panel.
//
// Reads pull from Supabase directly (RLS scopes `envelope_runs` to the signed-in
// user); REST writes still go through APIClient (POST /v1/envelope/...).
// ─────────────────────────────────────────────────────────────────────

/// One row from `pendingbot.envelope_runs`. Covers every status — UI uses
/// `status` to decide between shimmer / article / hide. `body_md` is only present
/// once status flips to "done"; `summary` may be set earlier but the runner
/// won't write it until the article is final.
struct EnvelopeRun: Codable, Identifiable, Hashable {
    let id: String
    /// Set when kind == "bot". Null on human-authored letters.
    let bot_id: String?
    /// Set when kind == "human" — the user_id of the person who wrote the
    /// letter. Null on bot-authored envelopes.
    let author_user_id: String?
    /// "bot" (runner-written article) or "human" (peer-to-peer letter).
    let kind: String
    /// What kicked the run off. `"example"` marks the preset 「读我」letter every
    /// new user is seeded — attributed to the app itself rather than the
    /// per-user self-bot.
    let trigger: String?
    let conversation_id: String
    let status: String
    let title: String?
    let summary: String?
    let body_md: String?
    let progress: AnyJSON?
    /// Per-turn trace appended by the runner — assistant text, reasoning, tool
    /// calls/results, collaborator replies. Drives the thinking-process panel on
    /// the iOS Envelope detail page. Optional (older rows lack it); always empty
    /// for human letters.
    let turns: AnyJSON?
    let created_at: String
    let started_at: String?
    let finished_at: String?

    var isDone: Bool { status == "done" && body_md != nil }
    var isRunning: Bool { status == "running" }
    var isHuman: Bool { kind == "human" }
    /// The preset 「读我」letter — shown as authored by the app itself.
    var isPreset: Bool { trigger == "example" }

    /// Byline name for the preset letter's app-authored attribution.
    static let presetSenderName = "Untitled"
}

enum EnvelopeFetch {
    /// Canonical column list — change here and both platforms move together.
    private static let columns =
        "id, kind, trigger, bot_id, author_user_id, conversation_id, status, title, summary, body_md, progress, turns, created_at, started_at, finished_at"

    /// The 来信 feed, most-recent first. RLS scopes `envelope_runs` to the user.
    static func list(limit: Int = 50) async throws -> [EnvelopeRun] {
        try await SupabaseStack.shared
            .from("envelope_runs")
            .select(columns)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    /// One envelope by id (detail pane re-fetch so the body is fresh).
    static func get(id: String) async throws -> EnvelopeRun? {
        let rows: [EnvelopeRun] = try await SupabaseStack.shared
            .from("envelope_runs")
            .select(columns)
            .eq("id", value: id)
            .limit(1)
            .execute()
            .value
        return rows.first
    }
}
