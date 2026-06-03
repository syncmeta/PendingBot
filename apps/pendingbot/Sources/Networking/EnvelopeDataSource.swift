import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Cross-platform 来信(Envelope)data source (T0.1 macOS 来信 tab)
//
// Minimal read surface for the 来信 tab — a feed of "奏折/letters" each bot has
// written for the user (`envelope_runs`, RLS-scoped to the signed-in user).
// iOS's `EnvelopeTabView` has the full version (realtime feed channel + thinking
// trace + letter compose); this is a fresh minimal service: list the feed +
// load one article's body. Realtime → 3s poll; thinking-trace/compose 留 follow-up.
//
// 时间戳规避: don't `select` created_at — `order(...)` sorts on it server-side.
// Column names copied from iOS's verified `envelope_runs` select.
// ─────────────────────────────────────────────────────────────────────

struct EnvelopeRow: Identifiable, Equatable, Hashable {
    let id: String
    /// "bot"(bot 主动写的奏折)| "human"(人写的信)。
    let kind: String?
    let status: String?
    let title: String
    let summary: String
    let bodyMd: String
    let botId: String?
    let authorUserId: String?

    /// Stable avatar seed — the bot for bot-letters, the author for human ones.
    var senderSeed: String { botId ?? authorUserId ?? id }
}

enum EnvelopeDataSource {
    /// Project the shared `EnvelopeRun` (superset row) down to the thin macOS feed
    /// row. macOS ignores the iOS-only columns (progress / turns / timestamps).
    private static func map(_ r: EnvelopeRun) -> EnvelopeRow {
        EnvelopeRow(
            id: r.id,
            kind: r.kind,
            status: r.status,
            title: (r.title?.isEmpty == false) ? r.title! : "(未命名)",
            summary: (r.summary ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces),
            bodyMd: r.body_md ?? "",
            botId: r.bot_id,
            authorUserId: r.author_user_id
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
