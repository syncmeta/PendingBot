import SwiftUI

/// Per-turn "thinking process" trace shown on the Envelope detail page.
/// Each turn collapses to a one-line summary; tap to expand and see the
/// model's text, any reasoning content, the tool calls + results, and the
/// collaborator's reply (if one is configured).
///
/// Live runs auto-expand the latest turn so the user can watch progress
/// as the runner appends to envelope_runs.turns over Realtime. Done runs
/// start collapsed under a section header so the article remains the
/// primary content.
struct EnvelopeThinkingTrace: View {
    let turns: [EnvelopeTurn]
    /// Live runs pass `collapsed: false` so the trace appears expanded
    /// beneath the running progress panel; finished runs default to a
    /// collapsed disclosure section so the article stays the focus.
    let collapsed: Bool

    @State private var sectionExpanded: Bool = false
    @State private var expandedTurns: Set<Int> = []

    private var liveLatest: Int? { turns.last?.i }

    var body: some View {
        if turns.isEmpty {
            EmptyView()
        } else if collapsed {
            DisclosureGroup(isExpanded: $sectionExpanded) {
                content
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(Theme.Fonts.glyph(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkMuted)
                    Text("思考过程（\(turns.count) 轮）")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
            .padding(.top, 16)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("思考过程")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                content
            }
            .padding(.top, 16)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(turns) { turn in
                turnRow(turn, isLatest: turn.i == liveLatest)
            }
        }
    }

    @ViewBuilder
    private func turnRow(_ turn: EnvelopeTurn, isLatest: Bool) -> some View {
        // Live latest turn defaults to expanded; the rest collapse.
        let expanded = expandedTurns.contains(turn.i)
            || (isLatest && !collapsed && expandedTurns.isEmpty)

        VStack(alignment: .leading, spacing: 8) {
            Button {
                if expandedTurns.contains(turn.i) {
                    expandedTurns.remove(turn.i)
                } else {
                    expandedTurns.insert(turn.i)
                }
                Haptics.tap()
            } label: {
                HStack(spacing: 8) {
                    Text("第 \(turn.i + 1) 轮")
                        .font(Theme.Fonts.rounded(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    Text(summary(turn))
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(Theme.Fonts.glyph(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                expandedTurnDetails(turn)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func expandedTurnDetails(_ turn: EnvelopeTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reasoning = turn.reasoning {
                traceBlock(label: "思考", text: reasoning, mono: false, accent: false)
            }
            if let assistant = turn.assistant {
                traceBlock(label: "主探索者", text: assistant, mono: false, accent: true)
            }
            ForEach(Array(turn.toolCalls.enumerated()), id: \.offset) { _, call in
                traceBlock(
                    label: "调用 \(call.name)",
                    text: call.argsJSON.isEmpty ? "—" : call.argsJSON,
                    mono: true,
                    accent: false
                )
            }
            ForEach(Array(turn.toolResults.enumerated()), id: \.offset) { _, result in
                traceBlock(label: "返回", text: result.content, mono: true, accent: false)
            }
            if let collaborator = turn.collaborator {
                traceBlock(label: "协作者", text: collaborator, mono: false, accent: true)
            }
        }
    }

    @ViewBuilder
    private func traceBlock(label: String, text: String, mono: Bool, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.Fonts.caption)
                .foregroundStyle(accent ? Theme.Palette.accent : Theme.Palette.inkMuted)
            Text(text)
                .font(mono ? Theme.Fonts.monoSmall : Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// One-line gist of a turn for the collapsed header. Picks the most
    /// informative thing the turn surfaced: assistant text → tool call
    /// args → tool result preview → collaborator reply.
    private func summary(_ turn: EnvelopeTurn) -> String {
        if let s = turn.assistant, !s.isEmpty { return condense(s) }
        if let first = turn.toolCalls.first {
            return "\(first.name) · \(condense(first.argsJSON))"
        }
        if let first = turn.toolResults.first { return condense(first.content) }
        if let s = turn.collaborator, !s.isEmpty { return condense(s) }
        return "—"
    }

    private func condense(_ s: String) -> String {
        let trimmed = s
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }
}
