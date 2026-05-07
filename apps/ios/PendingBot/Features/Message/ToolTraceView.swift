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
///   - Collapsed (default): one row — spinner + "搜索 · 3" + chevron
///   - Expanded: each event listed with its input + result
///
/// Colors are intentionally muted (no surface fill, no border) so the trace
/// recedes — the bot's actual reply remains the visual anchor.
struct ToolTraceView: View {
    let events: [ToolTraceEvent]
    /// True while the turn is still streaming (we don't yet know whether
    /// more tool calls will arrive). Drives the live spinner + "搜索中…"
    /// wording on the header.
    let isLive: Bool

    @State private var expanded: Bool = false

    var body: some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: expanded ? 8 : 0) {
                header
                if expanded {
                    detail
                }
            }
            .padding(.leading, Theme.Metrics.gutter + 30 + 8) // align under bot avatar gutter
            .padding(.trailing, Theme.Metrics.gutter)
            .padding(.vertical, 2)
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
        return joined
    }

    private var detail: some View {
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
}
