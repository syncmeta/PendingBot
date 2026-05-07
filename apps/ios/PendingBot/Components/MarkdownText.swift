import SwiftUI
import MarkdownUI

// `Theme` is ambiguous at file scope (PendingBot has one, MarkdownUI has one).
// File-private aliases keep call sites readable without leaning on module
// qualifiers. The `chatTheme` static below is `internal`, so its type alias
// must be at least the same access level (fileprivate).
fileprivate typealias AppTheme = PendingBot.Theme
fileprivate typealias MDTheme = MarkdownUI.Theme

/// Renders chat / log content as full Markdown — headings, lists, tables,
/// blockquotes, fenced code (with a copy + ▶ 运行 toolbar). Bot messages
/// and 奏折 articles both use this, so the styling tracks `Theme.Palette`
/// / `Theme.Fonts` rather than MarkdownUI's stock palette.
struct MarkdownText: View {
    let text: String
    /// True for the chat surface — turns on the heavyweight code-block
    /// toolbar. False keeps it lightweight (used in 奏折 articles where
    /// "run" doesn't make sense).
    var allowCodeRun: Bool = false
    /// Web-search references for inline `[N]` markers. Empty disables the
    /// citation rewrite — the text renders verbatim, including any literal
    /// `[1]`-style brackets the bot might have meant as plain text.
    var citations: [MessageCitation] = []

    @State private var presentedCitation: PresentedCitation?

    var body: some View {
        Markdown(rewrittenText)
            .markdownTheme(MarkdownText.chatTheme)
            .markdownBlockStyle(\.codeBlock) { configuration in
                ChatCodeBlock(
                    content: configuration.content,
                    language: configuration.language,
                    allowRun: allowCodeRun
                )
            }
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                // Citation taps go through a fake `pendingbot-cite://N`
                // scheme so we can intercept them here and show the source
                // sheet instead of letting Safari try to open them.
                if url.scheme == CitationScheme.scheme,
                   let n = Int(url.host ?? ""),
                   n >= 1, n <= citations.count {
                    presentedCitation = PresentedCitation(n: n, citation: citations[n - 1])
                    Haptics.tap()
                    return .handled
                }
                return .systemAction
            })
            .sheet(item: $presentedCitation) { p in
                CitationSheet(index: p.n, citation: p.citation)
            }
    }

    private var rewrittenText: String {
        guard !citations.isEmpty else { return text }
        return CitationScheme.rewrite(text, count: citations.count)
    }

    // ── Theme ──────────────────────────────────────────────────────────────

    /// Chat-tuned theme: matches the warm-ink palette + serif heads. Tighter
    /// vertical rhythm than `.basic` so a short bot reply doesn't feel like
    /// a blog post.
    fileprivate static let chatTheme: MDTheme = MDTheme()
        .text {
            ForegroundColor(AppTheme.Palette.ink)
            FontSize(16)
        }
        .link {
            ForegroundColor(AppTheme.Palette.accent)
            UnderlineStyle(.single)
        }
        .strong { FontWeight(.semibold) }
        .emphasis { FontStyle(.italic) }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(AppTheme.Palette.surfaceMuted)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(22)
                }
                .markdownMargin(top: 6, bottom: 2)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(19)
                }
                .markdownMargin(top: 6, bottom: 2)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                }
                .markdownMargin(top: 4, bottom: 2)
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .padding(.vertical, 4)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(AppTheme.Palette.hairline)
                        .frame(width: 3)
                }
                .markdownTextStyle { ForegroundColor(AppTheme.Palette.inkMuted) }
        }
        .listItem { configuration in
            configuration.label.markdownMargin(top: 2, bottom: 2)
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 0, bottom: 6)
        }
}

private struct PresentedCitation: Identifiable {
    let n: Int
    let citation: MessageCitation
    var id: Int { n }
}

/// Stable mapping between inline `[N]` markers and the `pendingbot-cite://N`
/// pseudo-URL the markdown renderer trades for tappable links.
fileprivate enum CitationScheme {
    static let scheme = "pendingbot-cite"

    /// Replace every `[N]` (1-based) in `text` with a markdown link whose
    /// label is the literal `[N]` and whose href is `pendingbot-cite://N`.
    /// References outside `1...count` are left as plain text — better to
    /// show a stray `[7]` than to dead-link it. The `\[` / `\]` escapes
    /// keep CommonMark from re-parsing the inner brackets as link syntax.
    static func rewrite(_ text: String, count: Int) -> String {
        // Avoid re-parsing on every layout pass — short-circuit when the
        // text has no candidate.
        guard text.contains("[") else { return text }
        let pattern = try? NSRegularExpression(pattern: #"\[(\d+)\]"#)
        guard let pattern else { return text }
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            let full = match.range
            let nRange = match.range(at: 1)
            let n = Int(ns.substring(with: nRange)) ?? 0
            if full.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            if n >= 1 && n <= count {
                result += "[\\[\(n)\\]](\(scheme)://\(n))"
            } else {
                result += ns.substring(with: full)
            }
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }
}

/// Bottom sheet shown when the user taps an inline citation chip. Lets the
/// reader skim the title + snippet before deciding to open the source.
private struct CitationSheet: View {
    let index: Int
    let citation: MessageCitation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var hostLabel: String {
        URL(string: citation.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? citation.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("[\(index)]")
                    .font(AppTheme.Fonts.rounded(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.accent)
                Text(hostLabel)
                    .font(AppTheme.Fonts.footnote)
                    .foregroundStyle(AppTheme.Palette.inkMuted)
                Spacer(minLength: 0)
            }
            Text(citation.title)
                .font(AppTheme.Fonts.body)
                .foregroundStyle(AppTheme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let snippet = citation.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(AppTheme.Fonts.footnote)
                    .foregroundStyle(AppTheme.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if let u = URL(string: citation.url) {
                    openURL(u)
                    dismiss()
                }
            } label: {
                HStack {
                    Image(systemName: "safari")
                    Text("打开链接")
                }
                .font(AppTheme.Fonts.body)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.Palette.accent.opacity(0.12))
                )
                .foregroundStyle(AppTheme.Palette.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// ── Code block ──────────────────────────────────────────────────────────────

/// Fenced code with a hover-style toolbar (lang tag · 复制 · ▶ 运行).
/// Run is offered for `js` / `javascript` / `html` only — anything else
/// shows a static lang chip so users don't tap into a sandbox that can't
/// execute their language.
private struct ChatCodeBlock: View {
    let content: String
    let language: String?
    let allowRun: Bool

    @State private var copied = false
    @State private var runnerSheet = false

    private var canRun: Bool {
        guard allowRun, let lang = language?.lowercased() else { return false }
        return ChatCodeBlock.runnableLangs.contains(lang)
    }

    private static let runnableLangs: Set<String> = ["js", "javascript", "html"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(AppTheme.Palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .background(AppTheme.Palette.surfaceMuted.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppTheme.Palette.hairline, lineWidth: 0.5)
        )
        .padding(.vertical, 4)
        .sheet(isPresented: $runnerSheet) {
            CodeRunnerSheet(content: content, language: language ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if let lang = language, !lang.isEmpty {
                Text(lang.lowercased())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.Palette.inkMuted)
            }
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = content
                Haptics.tap()
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copied = false
                }
            } label: {
                Text(copied ? "已复制" : "复制")
                    .font(AppTheme.Fonts.rounded(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Palette.inkMuted)
            }
            .buttonStyle(.plain)
            if canRun {
                Button {
                    Haptics.tap()
                    runnerSheet = true
                } label: {
                    Text("▶ 运行")
                        .font(AppTheme.Fonts.rounded(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.Palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}
