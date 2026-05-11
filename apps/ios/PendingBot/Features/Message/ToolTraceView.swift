import SwiftUI

/// One tool invocation captured from the SSE turn — `tool_call` creates it,
/// the matching `tool_result` fills in the result. Multiple tools per turn
/// stack into the trace shown above the bot's reply.
struct ToolTraceEvent: Identifiable, Hashable {
    let id: UUID
    let name: String
    var input: String?
    var resultSummary: String?
    var resultError: String?
    var done: Bool

    init(name: String, input: String?) {
        self.id = UUID()
        self.name = name
        self.input = input
        self.resultSummary = nil
        self.resultError = nil
        self.done = false
    }

    /// Per-tool human label. Mirrors the Scroll runner phrasing so the two
    /// surfaces (chat trace + scroll progress) read consistently.
    var headline: String {
        switch name {
        case "search_web":        return "搜索"
        case "read_url":          return "翻网页"
        case "execute_code":      return "跑代码"
        case "create_skill":      return "新增技能"
        case "query_user_memory": return "查记忆"
        default:                  return name
        }
    }

    /// One-line preview shown next to the headline. For finished events we
    /// prefer the result; for in-flight ones we show the input.
    var preview: String? {
        if done {
            if let e = resultError { return "出错：\(e)" }
            if let s = resultSummary { return s }
        }
        return input
    }
}

/// Inline, non-bubble trace of the bot's tool calls for one turn. Reads as
/// a quiet sidebar in the conversation flow:
///
///   - Header row + the citation list (the *search summary*) are always
///     visible whenever the trace exists — they're the load-bearing payoff
///     and shouldn't get hidden behind a tap.
///   - The per-tool *process* detail (query strings, result snippets,
///     spinners) is what expand/collapse toggles. Auto-expanded while any
///     tool is in flight; auto-collapsed the moment the last pending tool
///     finishes — even if the bot is still typing its reply afterwards.
///     The citation list below stays visible so the payoff isn't hidden.
///
/// Colors are intentionally muted (no surface fill, no border) so the trace
/// recedes — the bot's actual reply remains the visual anchor.
struct ToolTraceView: View {
    let events: [ToolTraceEvent]
    /// True while the turn is still streaming (we don't yet know whether
    /// more tool calls will arrive). Drives the live spinner + "搜索中…"
    /// wording on the header. Expand/collapse is driven by `anyPending`
    /// (the search itself), not the full turn — see body docs.
    let isLive: Bool
    /// Cumulative web-search hits surfaced during the turn — same list the
    /// bot's `[N]` markers resolve against. Rendered as tappable rows in
    /// the expanded body so the user sees real results, not just a count.
    var citations: [MessageCitation] = []

    @State private var expanded: Bool = false
    @Environment(\.openURL) private var openURL

    /// Any tool still in flight → drives the typing-dots indicator on the
    /// header. Decoupled from `expanded` (see `isLive`) so a fast search
    /// finishing doesn't slam the panel shut mid-turn.
    private var anyPending: Bool { !events.allSatisfy(\.done) }

    var body: some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                header
                // Process detail (per-tool query + status) — only this part
                // toggles. The citation list below stays visible even when
                // the user collapses the events.
                if expanded {
                    eventList
                }
                // Search summary — always visible whenever we have hits.
                // The whole point of the trace from the user's POV.
                if !citations.isEmpty {
                    citationList
                }
            }
            .padding(.leading, Theme.Metrics.gutter + 30 + 8) // align under bot avatar gutter
            .padding(.trailing, Theme.Metrics.gutter)
            .padding(.vertical, 2)
            .onAppear {
                // Mid-stream mount → reflect pending state immediately so
                // an in-flight search unfolds without the user tapping.
                expanded = anyPending
            }
            .onChange(of: anyPending) { _, nowPending in
                // Tool kicked off → expand. Last pending tool just
                // finished → collapse to a quiet summary row, even if the
                // bot is still typing its reply. User taps still override
                // either direction; the next pending transition re-syncs.
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded = nowPending
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            Haptics.tap()
        } label: {
            HStack(spacing: 6) {
                if isLive && !events.allSatisfy(\.done) {
                    TypingDots()
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                Text(summary)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Header summary string — collapses by tool kind so 3 search_web + 2
    /// read_url come through as "搜索 3 · 翻网页 2", not a flat count.
    private var summary: String {
        var counts: [(String, Int, Bool)] = [] // (label, count, anyPending)
        for ev in events {
            let label = ev.headline
            if let idx = counts.firstIndex(where: { $0.0 == label }) {
                counts[idx].1 += 1
                if !ev.done { counts[idx].2 = true }
            } else {
                counts.append((label, 1, !ev.done))
            }
        }
        let parts = counts.map { (label, n, _) in
            n > 1 ? "\(label) \(n)" : label
        }
        let joined = parts.joined(separator: " · ")
        if isLive && !events.allSatisfy(\.done) {
            return joined + "中…"
        }
        // Once finished, append the citation count if any — gives the
        // collapsed row a useful "搜索 · 5 条结果" tail instead of a bare
        // verb the user can't act on.
        if !citations.isEmpty {
            return joined + " · \(citations.count) 条结果"
        }
        return joined
    }

    /// Per-tool process rows — query string, spinner, result snippet.
    /// Toggled by the expand/collapse chevron; hidden once the turn ends.
    private var eventList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(events) { ev in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("·")
                        .foregroundStyle(Theme.Palette.inkMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(ev.headline)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Palette.inkMuted)
                            if !ev.done {
                                TypingDots()
                            }
                        }
                        if let preview = ev.preview, !preview.isEmpty {
                            Text(preview)
                                .font(Theme.Fonts.footnote)
                                .foregroundStyle(Theme.Palette.ink)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(.leading, 2)
    }

    /// Search summary — the citations the bot's `[N]` markers resolve to.
    /// Always rendered (when non-empty), regardless of expand state, so a
    /// user who collapses the trace still sees what was found.
    private var citationList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(citations.enumerated()), id: \.element.id) { idx, c in
                citationRow(index: idx + 1, citation: c)
            }
        }
        .padding(.leading, 2)
    }

    /// One hit row in the live-results list. Tap opens the source page.
    /// Compact two-line layout (title · domain) so the trace reads quickly
    /// even with 5–8 results.
    private func citationRow(index: Int, citation: MessageCitation) -> some View {
        Button {
            if let u = URL(string: citation.url) {
                openURL(u)
                Haptics.tap()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("[\(index)]")
                    .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(citation.title)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    Text(host(citation.url))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func host(_ url: String) -> String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
    }
}
