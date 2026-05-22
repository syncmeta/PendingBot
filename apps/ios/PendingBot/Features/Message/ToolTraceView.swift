import SwiftUI

/// One tool invocation captured from the SSE turn — `tool_call` creates it,
/// the matching `tool_result` fills in the result. Multiple tools per turn
/// stack into the trace shown above the bot's reply.
struct ToolTraceEvent: Identifiable, Hashable, Decodable {
    let id: UUID
    let name: String
    var input: String?
    var resultSummary: String?
    var resultError: String?
    var resultDetail: String?
    var done: Bool

    init(name: String, input: String?) {
        self.id = UUID()
        self.name = name
        self.input = input
        self.resultSummary = nil
        self.resultError = nil
        self.resultDetail = nil
        self.done = false
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case input
        case resultSummary = "result_summary"
        case resultError = "result_error"
        case resultDetail = "result_detail"
        case done
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.input = try c.decodeIfPresent(String.self, forKey: .input)
        self.resultSummary = try c.decodeIfPresent(String.self, forKey: .resultSummary)
        self.resultError = try c.decodeIfPresent(String.self, forKey: .resultError)
        self.resultDetail = try c.decodeIfPresent(String.self, forKey: .resultDetail)
        self.done = (try? c.decode(Bool.self, forKey: .done)) ?? false
    }

    /// Per-tool human label. Mirrors the Envelope runner phrasing so the two
    /// surfaces (chat trace + envelope progress) read consistently.
    var headline: String {
        switch name {
        // search_web is the envelope-runner name; web_search the unified
        // server-side-search name; web_search_exa the Exa MCP name.
        case "search_web", "web_search", "web_search_exa": return "搜索"
        case "search_chat_history": return "搜会话"
        case "read_url", "web_fetch_exa": return "翻网页"
        case "execute_code":      return "跑代码"
        case "request_execute_code": return "请求跑代码"
        case "create_skill":      return "新增技能"
        case "query_user_memory": return "查记忆"
        case "read_attachment":   return "读附件"
        case "set_my_group_nickname": return "改群昵称"
        case "set_bot_group_description": return "改群简介"
        case "delegate_to_specialist": return "委托专家"
        default:                  return name
        }
    }

    var iconName: String {
        switch name {
        case "search_web", "web_search", "web_search_exa", "search_chat_history": return "magnifyingglass"
        case "read_url", "web_fetch_exa": return "safari"
        case "execute_code", "request_execute_code": return "terminal"
        case "create_skill": return "sparkles"
        case "query_user_memory": return "brain.head.profile"
        case "read_attachment": return "paperclip"
        case "delegate_to_specialist": return "person.2.wave.2"
        default: return "hammer"
        }
    }

    var inputLabel: String {
        switch name {
        case "search_web", "web_search", "web_search_exa": return "搜索词"
        case "search_chat_history": return "会话搜索词"
        case "read_url", "web_fetch_exa": return "网址"
        case "execute_code", "request_execute_code": return "代码"
        case "query_user_memory": return "记忆查询"
        case "create_skill": return "技能名"
        case "delegate_to_specialist": return "目标专家"
        default: return "输入"
        }
    }

    /// Sub-conversation id surfaced by `delegate_to_specialist` — extracted
    /// from `resultDetail` (which stashes it as "sub_conversation:<uuid>").
    /// Used by the trace row to deep-link into the child thread when a
    /// dedicated sub-conv view ships; nil for every other tool.
    var subConversationId: String? {
        guard name == "delegate_to_specialist",
              let detail = resultDetail,
              detail.hasPrefix("sub_conversation:") else { return nil }
        return String(detail.dropFirst("sub_conversation:".count))
    }

    var isCodeLike: Bool {
        name == "execute_code" || name == "request_execute_code"
    }

    var stateText: String {
        if !done { return "进行中" }
        return resultError == nil ? "完成" : "出错"
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
///   - Header row is always visible whenever the trace exists.
///   - The process detail (query strings, result snippets, spinners) and
///     search result list expand/collapse together. Auto-expanded while any
///     tool is in flight; auto-collapsed the moment the last pending tool
///     finishes — even if the bot is still typing its reply afterwards.
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
    /// When non-nil, present SubConversationView for this child conv id.
    /// Set by tapping the "子对话已生成" chip on a delegate trace row.
    @State private var openedSubConv: SubConvLink?

    /// Identifiable wrapper for .sheet(item:) — carries the child conv id
    /// AND the specialist target so the sheet header can render the right
    /// label without re-querying the worker.
    private struct SubConvLink: Identifiable, Hashable {
        let id: String   // sub-conversation id
        let target: String?
    }

    /// Any tool still in flight → drives the typing-dots indicator on the
    /// header. Decoupled from `expanded` (see `isLive`) so a fast search
    /// finishing doesn't slam the panel shut mid-turn.
    private var anyPending: Bool { !events.allSatisfy(\.done) }

    var body: some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                header
                // Process detail and search results collapse together, so
                // the closed state is just the quiet summary row.
                if expanded {
                    eventList
                    if !citations.isEmpty {
                        citationList
                    }
                }
            }
            .padding(.leading, Theme.Metrics.gutter + 30 + 8) // align under bot avatar gutter
            .padding(.trailing, Theme.Metrics.gutter)
            .padding(.vertical, 4)
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
            .sheet(item: $openedSubConv) { link in
                SubConversationView(
                    subConversationId: link.id,
                    target: link.target
                )
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            Haptics.tap()
        } label: {
            HStack(spacing: 8) {
                if isLive && !events.allSatisfy(\.done) {
                    TypingDots()
                } else {
                    Image(systemName: headerIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 22, height: 22)
                        .background(Theme.Palette.accentBg, in: Circle())
                }
                Text(summary)
                    .font(Theme.Fonts.rounded(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
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

    private var headerIcon: String {
        if events.contains(where: { $0.isCodeLike }) { return "terminal" }
        if events.contains(where: { $0.name == "read_url" || $0.name == "web_fetch_exa" }) { return "safari" }
        if events.contains(where: { $0.name == "query_user_memory" }) { return "brain.head.profile" }
        if events.contains(where: { $0.name == "delegate_to_specialist" }) { return "person.2.wave.2" }
        return "magnifyingglass"
    }

    /// Header summary string — collapses by tool kind so 3 search_web + 2
    /// read_url come through as "搜索 3 · 翻网页 2", not a flat count.
    private var summary: String {
        if events.count == 1, let ev = events.first {
            var base = ev.headline
            if ["search_web", "web_search", "web_search_exa", "search_chat_history"].contains(ev.name),
               let input = ev.input,
               !input.isEmpty {
                base += "：\(input)"
            }
            if isLive && !ev.done { return base + "中…" }
            if !citations.isEmpty { return base + " · \(citations.count) 条结果" }
            if ev.done, let result = ev.resultSummary, !result.isEmpty { return base + " · \(result)" }
            return base
        }
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(events) { ev in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: ev.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ev.resultError == nil ? Theme.Palette.accent : Color(hex: 0xB14B3C))
                        .frame(width: 24, height: 24)
                        .background(
                            (ev.resultError == nil ? Theme.Palette.accentBg : Color(hex: 0xF4DDD6)),
                            in: Circle()
                        )
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(ev.headline)
                                .font(Theme.Fonts.rounded(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.Palette.ink)
                            Text(ev.stateText)
                                .font(Theme.Fonts.rounded(size: 10, weight: .semibold))
                                .foregroundStyle(ev.resultError == nil ? Theme.Palette.inkMuted : Color(hex: 0xB14B3C))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.Palette.surfaceMuted.opacity(0.8), in: Capsule())
                            if !ev.done {
                                TypingDots()
                            }
                            Spacer(minLength: 0)
                        }
                        if let input = ev.input, !input.isEmpty {
                            labelledBlock(label: ev.inputLabel, text: input, mono: ev.isCodeLike)
                        }
                        if ev.done {
                            if let error = ev.resultError, !error.isEmpty {
                                labelledBlock(label: "结果", text: error, mono: false, isError: true)
                            } else if let summary = ev.resultSummary, !summary.isEmpty {
                                labelledBlock(label: "结果", text: summary, mono: ev.isCodeLike)
                            }
                        }
                        // delegate_to_specialist uses resultDetail as a
                        // deep-link carrier ("sub_conversation:<uuid>"), not
                        // human-facing text — surface the child id as a
                        // tappable chip that opens the full sub-conversation
                        // in a sheet.
                        if let subId = ev.subConversationId {
                            Button {
                                openedSubConv = SubConvLink(id: subId, target: ev.input)
                                Haptics.tap()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "bubble.left.and.bubble.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.accent)
                                    Text("看子对话")
                                        .font(Theme.Fonts.rounded(size: 11, weight: .medium))
                                        .foregroundStyle(Theme.Palette.accent)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Theme.Palette.accent.opacity(0.7))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Theme.Palette.accentBg.opacity(0.7), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        } else if let detail = ev.resultDetail, !detail.isEmpty {
                            labelledBlock(label: "详情", text: softWrapped(detail), mono: true, isMuted: true)
                        }
                    }
                }
                .padding(10)
                .background(Theme.Palette.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.Palette.hairline, lineWidth: 1)
                )
            }
        }
    }

    private func labelledBlock(
        label: String,
        text: String,
        mono: Bool,
        isError: Bool = false,
        isMuted: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.Fonts.rounded(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.inkMuted)
            Text(softWrapped(text))
                .font(mono ? Theme.Fonts.monoSmall : Theme.Fonts.footnote)
                .foregroundStyle(isError ? Color(hex: 0xB14B3C) : (isMuted ? Theme.Palette.inkMuted : Theme.Palette.ink))
                .lineLimit(mono ? 4 : 3)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Search results — the citations the bot's `[N]` markers resolve to.
    /// Rendered inside the expanded trace body.
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

    private func softWrapped(_ text: String) -> String {
        var out = ""
        var run = 0
        for ch in text {
            out.append(ch)
            if ch.isWhitespace || "/._-:".contains(ch) {
                run = 0
            } else {
                run += 1
                if run >= 48 {
                    out.append("\u{200B}")
                    run = 0
                }
            }
        }
        return out
    }
}
