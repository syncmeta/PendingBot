import SwiftUI
import MarkdownUI
import SwiftMath
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MarkdownUI has no LaTeX support — it renders `\(x^2\)` / `$$…$$` verbatim.
// The bridge here is: rewrite every math span into an `![](pendingbot-math://…)`
// image reference, then hand a math-aware image provider to the renderer that
// typesets the LaTeX (via SwiftMath) into a platform image. Inline math flows
// through MarkdownUI's `InlineImageProvider`; a formula alone in a paragraph
// (display math) flows through the block `ImageProvider`.
//
// Cross-platform: `MathMarkup` is pure Foundation. The image layer uses
// `UIImage` on iOS and `NSImage` on macOS — SwiftMath's `MTMathImage` is
// itself cross-platform (its `asImage()` returns `MTImage`, i.e. UIImage on
// iOS / NSImage on macOS), so both platforms share the exact same renderer.

// MARK: - Platform color shim

// `PlatformImage`(UIImage/NSImage)和 `Image(platformImage:)` 已在
// Components/PlatformImage.swift 提供,这里只补一个颜色别名。
#if canImport(UIKit)
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
private typealias PlatformColor = NSColor
#endif

private extension PlatformImage {
    var pixelWidthPoints: CGFloat { size.width }
}

// MARK: - Markup rewriting

/// Detects LaTeX math in message text and rewrites the delimiters into
/// markdown image references. Supported delimiters: `\(…\)` and `$…$`
/// inline, `\[…\]` and `$$…$$` display. Math inside fenced or inline code
/// is left untouched. Pure Foundation — cross-platform.
enum MathMarkup {
    static let scheme = "pendingbot-math"

    /// Cheap pre-check so messages with no math skip the regex work.
    static func containsMath(_ text: String) -> Bool {
        text.contains("\\(") || text.contains("\\[") || text.contains("$")
    }

    /// Rewrite every math span outside code regions into image markdown.
    static func rewrite(_ text: String) -> String {
        var out = ""
        for segment in segments(text) {
            switch segment {
            case .code(let s):
                out += s
            case .text(let s):
                out += rewriteMath(in: s)
            }
        }
        return out
    }

    // ── Code-aware segmentation ──────────────────────────────────────────

    private enum Segment {
        case code(String)
        case text(String)
    }

    /// Split `text` into code segments (fenced blocks + inline code spans)
    /// and plain-text segments. Only the plain-text segments get the math
    /// rewrite — a `$` inside a shell snippet must stay literal.
    private static func segments(_ text: String) -> [Segment] {
        let chars = Array(text)
        var result: [Segment] = []
        var buf = ""
        var i = 0

        func flushText() {
            if !buf.isEmpty { result.append(.text(buf)); buf = "" }
        }

        while i < chars.count {
            let atLineStart = (i == 0 || chars[i - 1] == "\n")

            // Fenced code block: a run of >= 3 backticks/tildes at line start.
            if atLineStart, chars[i] == "`" || chars[i] == "~" {
                let fence = chars[i]
                var n = 0
                while i + n < chars.count && chars[i + n] == fence { n += 1 }
                if n >= 3 {
                    var j = i + n
                    while j < chars.count && chars[j] != "\n" { j += 1 }   // rest of opening line
                    while j < chars.count {
                        j += 1                                             // step onto next line
                        let lineStart = j
                        var k = lineStart
                        while k < chars.count && (chars[k] == " " || chars[k] == "\t") { k += 1 }
                        var m = 0
                        while k + m < chars.count && chars[k + m] == fence { m += 1 }
                        if m >= n {                                        // closing fence
                            j = k + m
                            while j < chars.count && chars[j] != "\n" { j += 1 }
                            break
                        }
                        j = lineStart
                        while j < chars.count && chars[j] != "\n" { j += 1 }
                    }
                    flushText()
                    result.append(.code(String(chars[i..<j])))
                    i = j
                    continue
                }
            }

            // Inline code span: a run of N backticks closed by a run of N.
            if chars[i] == "`" {
                var n = 0
                while i + n < chars.count && chars[i + n] == "`" { n += 1 }
                var j = i + n
                var close = -1
                while j < chars.count {
                    if chars[j] == "`" {
                        var m = 0
                        while j + m < chars.count && chars[j + m] == "`" { m += 1 }
                        if m == n { close = j + m; break }
                        j += m
                    } else {
                        j += 1
                    }
                }
                if close >= 0 {
                    flushText()
                    result.append(.code(String(chars[i..<close])))
                    i = close
                    continue
                }
                // Unclosed backtick run — fall through, treat as plain text.
            }

            buf.append(chars[i])
            i += 1
        }
        flushText()
        return result
    }

    // ── Math span rewriting ──────────────────────────────────────────────

    private static func rewriteMath(in text: String) -> String {
        var s = text
        s = replace(s, Patterns.displayDollar, display: true)
        s = replace(s, Patterns.displayBracket, display: true)
        s = replace(s, Patterns.inlineParen, display: false)
        s = replace(s, Patterns.inlineDollar, display: false)
        return s
    }

    private enum Patterns {
        // Display: $$ … $$  and  \[ … \]  (may span lines).
        static let displayDollar = regex(#"\$\$([\s\S]+?)\$\$"#)
        static let displayBracket = regex(#"\\\[([\s\S]+?)\\\]"#)
        // Inline: \( … \)  (single line).
        static let inlineParen = regex(#"\\\(([^\n]+?)\\\)"#)
        // Inline: $ … $ — guarded so prose like "$5 and $10" is not eaten:
        // opener not preceded by \, $, or a digit and not followed by space
        // or $; content ends on a non-space; closer not followed by digit/$.
        static let inlineDollar = regex(#"(?<![\\$0-9])\$(?![ \t$])((?:\\.|[^$\n\\])*?\S)\$(?![0-9$])"#)

        private static func regex(_ p: String) -> NSRegularExpression {
            // Patterns are compile-time literals — a failure is a programmer
            // error, so an empty fallback (which matches nothing) is fine.
            (try? NSRegularExpression(pattern: p)) ?? NSRegularExpression()
        }
    }

    private static func replace(_ text: String, _ pattern: NSRegularExpression, display: Bool) -> String {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for m in matches {
            let full = m.range
            if full.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            let latex = ns.substring(with: m.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let encoded = encode(latex), !latex.isEmpty {
                let mode = display ? "b" : "i"
                result += "![](\(scheme)://\(mode)/\(encoded))"
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

    // ── base64url codec (carries the LaTeX through the image URL) ─────────

    static func encode(_ s: String) -> String? {
        guard let data = s.data(using: .utf8) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String) -> String? {
        var b64 = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Pull `(display, latex)` back out of a `pendingbot-math://…` URL.
    static func parse(_ url: URL) -> (display: Bool, latex: String)? {
        guard url.scheme == scheme else { return nil }
        let display = (url.host == "b")
        let payload = String(url.path.dropFirst())   // strip leading "/"
        guard let latex = decode(payload) else { return nil }
        return (display, latex)
    }
}

// MARK: - LaTeX → platform image

/// Typesets LaTeX into a platform image via SwiftMath and memoises the result.
/// Rendering is fast (sub-millisecond) but a chat scroll re-lays out
/// constantly, so the cache keeps it off the hot path.
@MainActor
final class MathImageRenderer {
    static let shared = MathImageRenderer()
    private var cache: [String: PlatformImage] = [:]

    func image(latex: String, display: Bool, color: Color, fontSize: CGFloat, scheme: ColorScheme) -> PlatformImage {
        // The palette colors are appearance-adaptive, so both the cache key and
        // the rasterised color must be pinned to an explicit scheme — keying on
        // `String(describing: color)` (identical for both variants of a dynamic
        // color) would serve light-ink bitmaps in dark mode.
        let platformColor = Self.resolve(color, for: scheme)
        let key = "\(display)|\(Int(fontSize * 2))|\(scheme == .dark ? "dark" : "light")|\(latex)"
        if let cached = cache[key] { return cached }
        let image = Self.render(latex: latex, display: display, color: platformColor, fontSize: fontSize)
        cache[key] = image
        return image
    }

    /// Resolve a (possibly dynamic) Color to the concrete variant for `scheme`,
    /// independent of whatever appearance is ambient on the calling thread.
    private static func resolve(_ color: Color, for scheme: ColorScheme) -> PlatformColor {
        #if canImport(UIKit)
        return PlatformColor(color).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        )
        #elseif canImport(AppKit)
        let dynamic = PlatformColor(color)
        guard let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) else {
            return dynamic
        }
        var resolved = dynamic
        appearance.performAsCurrentDrawingAppearance {
            // `.cgColor` resolves a dynamic NSColor against the appearance that
            // is current at access time.
            resolved = PlatformColor(cgColor: dynamic.cgColor) ?? dynamic
        }
        return resolved
        #endif
    }

    private static func render(latex: String, display: Bool, color: PlatformColor, fontSize: CGFloat) -> PlatformImage {
        let math = MTMathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: color,
            labelMode: display ? .display : .text
        )
        let (error, image) = math.asImage()
        if error == nil, let image { return image }
        // SwiftMath couldn't parse the LaTeX — show the raw source rather
        // than dropping the formula entirely.
        return textFallback(latex, color: color, fontSize: fontSize)
    }

    private static func textFallback(_ source: String, color: PlatformColor, fontSize: CGFloat) -> PlatformImage {
        #if canImport(UIKit)
        let font = UIFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular)
        #elseif canImport(AppKit)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular)
        #endif
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let string = NSAttributedString(string: source, attributes: attrs)
        let size = string.size()
        let pixelSize = CGSize(width: max(1, ceil(size.width)), height: max(1, ceil(size.height)))
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: pixelSize)
        return renderer.image { _ in string.draw(at: .zero) }
        #elseif canImport(AppKit)
        let image = NSImage(size: pixelSize)
        image.lockFocus()
        string.draw(at: .zero)
        image.unlockFocus()
        return image
        #endif
    }
}

// MARK: - MarkdownUI providers

/// Inline image provider — renders inline math, delegates everything else
/// (real `![]()` images) to MarkdownUI's default provider.
struct MathInlineImageProvider: InlineImageProvider {
    let textColor: Color
    let fontSize: CGFloat
    /// Pinned by the hosting view (MarkdownText reads `\.colorScheme`); the
    /// provider value changing on a mode flip is what re-triggers MarkdownUI
    /// to re-request inline images in the new ink color.
    let scheme: ColorScheme

    func image(with url: URL, label: String) async throws -> Image {
        if let math = MathMarkup.parse(url) {
            let platformImage = await MathImageRenderer.shared.image(
                latex: math.latex,
                display: math.display,
                color: textColor,
                fontSize: fontSize,
                scheme: scheme
            )
            return Image(platformImage: platformImage)
        }
        return try await DefaultInlineImageProvider.default.image(with: url, label: label)
    }
}

/// Block image provider — renders display math centered, delegates real
/// images to MarkdownUI's default provider.
struct MathBlockImageProvider: ImageProvider {
    let textColor: Color
    let fontSize: CGFloat

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let url, let math = MathMarkup.parse(url) {
            MathBlockImage(
                latex: math.latex,
                textColor: textColor,
                // Display math gets a touch more size than body text.
                fontSize: fontSize * 1.1
            )
        } else {
            DefaultImageProvider.default.makeImage(url: url)
        }
    }
}

private struct MathBlockImage: View {
    let latex: String
    let textColor: Color
    let fontSize: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.pixelWidthPoints)
            } else {
                Color.clear.frame(height: fontSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
        // Re-render on appearance change so the formula color tracks the
        // surrounding text.
        .task(id: colorScheme) {
            image = await MathImageRenderer.shared.image(
                latex: latex,
                display: true,
                color: textColor,
                fontSize: fontSize,
                scheme: colorScheme
            )
        }
    }
}
