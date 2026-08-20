import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Cross-platform 来信(Envelope)data source (T0.1 macOS 来信 tab)
//
// Minimal read surface for the 来信 tab — a feed of "奏折/letters" each bot has
// written for the user (`envelope_runs`, RLS-scoped to the signed-in user).
// iOS's `EnvelopeTabView` has the full version (realtime feed channel + thinking
// trace + letter compose); this is a fresh minimal service: list the feed +
// load one article's body. Realtime is the shared self-built RealtimeHub WS
// (`RealtimeSocket`, same channel iOS `EnvelopeFeedChannel` uses) — not a poll,
// not Supabase Realtime. thinking-trace/compose 留 follow-up.
//
// Column names copied from iOS's verified `envelope_runs` select.
// ─────────────────────────────────────────────────────────────────────

struct EnvelopeRow: Identifiable, Equatable, Hashable {
    let id: String
    /// "bot"(bot 主动写的奏折)| "human"(人写的信)。
    let kind: String?
    /// What kicked the run off. `"example"` marks the preset 「读我」letter —
    /// attributed to the app itself rather than the per-user self-bot
    /// (drives `isPreset`, mirrors iOS).
    let trigger: String?
    let status: String?
    let title: String
    let summary: String
    let bodyMd: String
    let botId: String?
    let authorUserId: String?
    /// Raw server timestamp for the byline date (parsed lazily by the UI via
    /// `ServerTimestamp`). Empty when the row lacks one.
    let createdAt: String

    /// Stable avatar seed — the bot for bot-letters, the author for human ones.
    var senderSeed: String { botId ?? authorUserId ?? id }

    /// Mirrors iOS `EnvelopeRun` helpers so the Mac feed row / detail branch
    /// on the same states.
    var isHuman: Bool { kind == "human" }
    var isRunning: Bool { status == "running" }
    var isDone: Bool { status == "done" && !bodyMd.isEmpty }
    /// The preset 「读我」letter — shown as authored by the app itself.
    var isPreset: Bool { trigger == "example" }
}

enum EnvelopeDataSource {
    /// Project the shared `EnvelopeRun` (superset row) down to the thin macOS feed
    /// row. macOS ignores the iOS-only columns (progress / turns / timestamps).
    private static func map(_ r: EnvelopeRun) -> EnvelopeRow {
        EnvelopeRow(
            id: r.id,
            kind: r.kind,
            trigger: r.trigger,
            status: r.status,
            // Keep the raw title (may be empty) — the UI applies iOS's exact
            // fallback copy ("正在写来信…" / "未命名来信") based on status so
            // the Mac feed row reads identically.
            title: r.title ?? "",
            // Feed summary stays single-line (collapse newlines) for the card;
            // the detail pane re-fetches and renders the full body.
            summary: (r.summary ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces),
            bodyMd: r.body_md ?? "",
            botId: r.bot_id,
            authorUserId: r.author_user_id,
            createdAt: r.created_at
        )
    }

    /// The 来信 feed (most-recent first) via the shared `EnvelopeFetch.list()` —
    /// same query as iOS's `EnvelopeTabView`. RLS scopes `envelope_runs` to user.
    static func listEnvelopes(limit: Int = 100) async throws -> [EnvelopeRow] {
        try await EnvelopeFetch.list(limit: limit).map(map)
    }

    /// One article by id (detail pane re-fetch) via the shared `EnvelopeFetch`.
    static func loadEnvelope(id: String) async throws -> EnvelopeRow? {
        try await EnvelopeFetch.get(id: id).map(map)
    }
}
