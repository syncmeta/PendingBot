#if os(macOS)
import SwiftUI

/// Structured transcript for a codex app-server session.
/// Renders one row per `CodexThreadItem` arm, auto-scrolls to newest item,
/// and respects dark mode via `Theme.Palette` tokens.
/// UX modeled on the codex desktop client: compact command cards,
/// disclosure for reasoning, role labels flush-left.
struct CodexTranscriptView: View {
    @ObservedObject var transcript: CodexTranscript

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(transcript.items) { item in
                        row(item).id(item.id)
                    }
                    if transcript.turnActive {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("运行中…")
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Palette.inkMuted)
                        }
                        .padding(.vertical, 4)
                        .id("__spinner__")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .onChange(of: transcript.items.count) { _, _ in
                let anchor: UnitPoint = .bottom
                if transcript.turnActive {
                    withAnimation { proxy.scrollTo("__spinner__", anchor: anchor) }
                } else if let last = transcript.items.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: anchor) }
                }
            }
        }
    }

    // MARK: - Row dispatch

    @ViewBuilder
    private func row(_ item: CodexThreadItem) -> some View {
        switch item.kind {
        case let .userMessage(text):
            messageRow(role: "你", text: text, isUser: true)

        case let .agentMessage(text, phase):
            messageRow(role: phase.map { "Codex · \($0)" } ?? "Codex",
                       text: text, isUser: false)

        case let .reasoning(summary, content):
            reasoningRow(summary: summary, content: content)

        case let .plan(text):
            labeled(icon: "list.bullet.clipboard", label: "计划", body: text)

        case let .commandExecution(c):
            commandCard(c)

        case let .fileChange(f):
            labeled(icon: "doc.badge.gearshape",
                    label: "文件改动",
                    body: f.summary ?? f.status ?? "")

        case let .toolCall(name, status):
            labeled(icon: "function",
                    label: "工具",
                    body: name + (status.map { " · \($0)" } ?? ""))

        case let .webSearch(query):
            labeled(icon: "magnifyingglass",
                    label: "搜索",
                    body: query ?? "")

        case let .unknown(type):
            labeled(icon: "questionmark.circle",
                    label: "(\(type))",
                    body: "")
        }
    }

    // MARK: - Message row (user / agent)

    @ViewBuilder
    private func messageRow(role: String, text: String, isUser: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(role)
                .font(Theme.Fonts.caption.weight(.semibold))
                .foregroundStyle(isUser ? Theme.Palette.accent : Theme.Palette.inkMuted)
            Text(text)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isUser ? Theme.Palette.accentBg : Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
        )
    }

    // MARK: - Reasoning disclosure

    @ViewBuilder
    private func reasoningRow(summary: String?, content: String?) -> some View {
        let hasSummary = summary?.isEmpty == false
        let hasContent = content?.isEmpty == false
        // 思考正文:优先 content(原始推理);ChatGPT 鉴权下 content 空、可读推理在
        // summary(由 summaryTextDelta 累积),回退到它。
        let bodyText = hasContent ? (content ?? "") : (summary ?? "")
        // 标题:summary 与 content 同时存在时 summary 作短标题;否则固定「思考过程」
        // (避免把整段 summary 塞进单行标题)。
        let labelText = (hasSummary && hasContent) ? (summary ?? "思考过程") : "思考过程"
        DisclosureGroup {
            Text(bodyText)
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                Text(labelText)
                    .font(Theme.Fonts.caption.weight(.medium))
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.surfaceMuted)
        )
    }

    // MARK: - Generic labeled row (plan / fileChange / toolCall / webSearch / unknown)

    @ViewBuilder
    private func labeled(icon: String, label: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.inkMuted)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Theme.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.inkMuted)
                if !body.isEmpty {
                    Text(body)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.surfaceMuted)
        )
    }

    // MARK: - Command card

    @ViewBuilder
    private func commandCard(_ c: CodexThreadItem.CommandExec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: icon + "$ command" + optional cwd + exit badge
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "terminal")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.command)
                        .font(Theme.Fonts.monoSmall.weight(.medium))
                        .foregroundStyle(Theme.Palette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let cwd = c.cwd, !cwd.isEmpty {
                        Text(cwd)
                            .font(Theme.Fonts.monoSmall)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                exitBadge(c.exitCode, status: c.status)
            }

            // Output block
            if let output = c.aggregatedOutput, !output.isEmpty {
                Divider()
                    .background(Theme.Palette.hairline)
                ScrollView(.vertical, showsIndicators: false) {
                    Text(output)
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)   // ~12 lines at monoSmall
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
    private func exitBadge(_ code: Int?, status: String?) -> some View {
        if let code {
            let isSuccess = code == 0
            let label = isSuccess ? "exit 0" : "exit \(code)"
            let fg: Color = isSuccess ? Theme.Palette.success : Theme.Palette.danger
            let bg: Color = isSuccess
                ? Theme.Palette.success.opacity(0.12)
                : Theme.Palette.dangerBg
            Text(label)
                .font(Theme.Fonts.caption2.weight(.semibold))
                .foregroundStyle(fg)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(bg, in: Capsule())
        } else if let status, !status.isEmpty {
            Text(status)
                .font(Theme.Fonts.caption2)
                .foregroundStyle(Theme.Palette.inkMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.Palette.surfaceMuted, in: Capsule())
        }
    }
}
#endif
