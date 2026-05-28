import SwiftUI
import UIKit

/// One place to change the look. Mirrors the design language used across
/// the PendingBot reference + the web `tokens.css`: deep-jade accent on
/// warm-ink neutrals, editorial serif for titles, rounded sans for chrome.
///
/// Light-only theme — the brand is two anchor colors (#044735 + #fdfcfa)
/// and we intentionally don't ship a dark variant for v1.
enum Theme {

    // ── Palette ─────────────────────────────────────────────────────────────

    enum Palette {
        /// Brand accent — #044735 (deep forest green).
        static let accent      = Color(hex: 0x044735)
        /// Hover/pressed — slightly lighter so it reads as "lit up".
        static let accentHover = Color(hex: 0x0A6049)
        /// Soft accent fill — used for the user bubble + selected pills.
        /// Tinted from #044735, washed toward the cream surface.
        static let accentBg    = Color(hex: 0xE3EEEA)

        /// Warm amber — public-bot tag fg. Sits in the same brightness
        /// register as the deep accent green so the two pills feel paired.
        static let amber       = Color(hex: 0x6F5A0B)
        /// Pale buttery yellow — public-bot tag bg, washed from `amber`.
        static let amberBg     = Color(hex: 0xFAEDC2)

        /// Plum — private-bot tag fg. Same brightness register as the
        /// accent green and amber so all three tag pills feel paired.
        static let plum        = Color(hex: 0x5B3D8A)
        /// Pale lavender — private-bot tag bg, washed from `plum`.
        static let plumBg      = Color(hex: 0xECE3F7)

        /// Page canvas — #fdfcfa (warm off-white).
        static let canvas        = Color(hex: 0xFDFCFA)
        /// Cards / sheets — pure white sits a hair above canvas.
        static let surface       = Color(hex: 0xFFFFFF)
        /// Subtler than surface — chips / pills / muted bg fills.
        static let surfaceMuted  = Color(hex: 0xEFEEE9)

        /// Primary ink — keep close to true black but warm.
        static let ink       = Color(hex: 0x1B1A14)
        /// Secondary — used for labels, timestamps, descriptions.
        static let inkMuted  = Color(hex: 0x6E6A5C)
        /// Hairline borders — barely-there separators.
        static let hairline  = Color(hex: 0xE2E0D7)

        /// User-message bubble — same as accentBg, named for clarity.
        static let userBubble = accentBg
        /// Optimistic user bubble while the send request is in flight (no
        /// HTTP response yet). Washed further toward canvas so the bubble
        /// reads as "not yet acknowledged"; flips to `userBubble` the
        /// moment the server returns 200.
        static let userBubbleSending = Color(hex: 0xF1F6F3)
    }

    // ── Typography ──────────────────────────────────────────────────────────

    enum Fonts {
        /// Per-platform multiplier (1.0 on iOS, ~0.88 on Mac Catalyst).
        /// Applied to every size below so the desktop UI doesn't read as
        /// the iOS layout zoomed in.
        private static let scale: CGFloat = Platform.isMac ? Platform.macFontScale : 1.0
        private static func sized(_ pt: CGFloat) -> CGFloat { pt * scale }

        /// Exposed for callers that need a raw scaled point size — e.g.
        /// MarkdownUI's `FontSize(...)` which takes a CGFloat, so the
        /// bot's markdown body can match the user bubble's
        /// `Theme.Fonts.body` size on Mac Catalyst (otherwise the bot
        /// reads at 16pt while the user reads at ~14pt and the two
        /// sides look mismatched).
        static func scaled(_ pt: CGFloat) -> CGFloat { sized(pt) }

        static func system(
            size: CGFloat,
            weight: Font.Weight = .regular,
            design: Font.Design = .default
        ) -> Font {
            .system(size: sized(size), weight: weight, design: design)
        }

        static func monospaced(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            system(size: size, weight: weight, design: .monospaced)
        }

        /// Unscaled font-sized glyphs: SF Symbols, emoji avatars, and icon-like
        /// marks whose size is tied to a fixed visual container rather than text.
        static func glyph(
            size: CGFloat,
            weight: Font.Weight = .regular,
            design: Font.Design = .default
        ) -> Font {
            .system(size: size, weight: weight, design: design)
        }

        static func uiSystem(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
            .systemFont(ofSize: sized(size), weight: weight)
        }

        static func uiMonospaced(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
            .monospacedSystemFont(ofSize: sized(size), weight: weight)
        }

        /// UIKit font from an already-resolved point size. Use when the
        /// caller receives a size from another scaled renderer, such as math.
        static func uiResolvedMonospaced(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
            .monospacedSystemFont(ofSize: size, weight: weight)
        }

        /// Serif display (system New York). Used for titles, header marks,
        /// avatar initials. Feels editorial vs the regular SF Pro UI.
        static func serif(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
            system(size: size, weight: weight, design: .serif)
        }

        /// Rounded sans — softer than SF Pro, used for buttons, chip labels,
        /// nav, counters. Matches the warm palette.
        static func rounded(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            system(size: size, weight: weight, design: .rounded)
        }

        static let body            = system(size: 16)
        static let bodyEmphasized  = system(size: 16, weight: .medium)
        static let subheadline     = system(size: 15)
        static let headline        = system(size: 17, weight: .semibold)
        static let footnote        = system(size: 13)
        static let caption         = system(size: 12)
        static let caption2        = system(size: 11)
        static let title           = serif(size: 28, weight: .semibold)
        static let title2          = system(size: 22)
        static let title3          = system(size: 20)
        static let sectionTitle    = serif(size: 20, weight: .semibold)
        static let monoSmall       = monospaced(size: 12)
    }

    // ── Spacing / radii ─────────────────────────────────────────────────────

    enum Metrics {
        static let gutter: CGFloat = 16
        static let rowVPad: CGFloat = 10
        static let bubbleRadius: CGFloat = 18
        static let cardRadius: CGFloat = 14
        static let pillRadius: CGFloat = 999

        /// Cap on a column of long-form content (chat bubbles, list rows).
        /// Above this width — iPad landscape, Mac Catalyst windows — letting
        /// the column stretch produces 1500pt-wide bubbles that read poorly.
        /// 760 keeps lines around 70–80 chars which matches reading research.
        static let readableColumn: CGFloat = 760
    }
}

// ── Wide-screen reading column ──────────────────────────────────────────────

extension View {
    /// Center the view inside a column capped at `Theme.Metrics.readableColumn`.
    /// On iPhone portrait this is a no-op (the screen is narrower than the cap);
    /// on iPad landscape it keeps content from spreading across the window.
    ///
    /// **Mac:** the cap is dropped and the inner frame becomes leading-aligned.
    /// Catalyst windows are usually narrower than iPad landscape, and the
    /// vertical tab rail + NavigationSplitView already chop the content
    /// area into reasonable columns — leaving a centered 760pt island
    /// inside that produces big empty gutters on both sides which read as
    /// "this app doesn't know it's on Mac."
    func readableColumnWidth(
        _ maxWidth: CGFloat = Theme.Metrics.readableColumn
    ) -> some View {
        Group {
            if Platform.isMac {
                self.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                self.frame(maxWidth: maxWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

// ── Hex init helper ─────────────────────────────────────────────────────────

extension Color {
    /// Build a Color from a 24-bit sRGB hex literal.
    /// Example: `Color(hex: 0x044735)`.
    init(hex: UInt32, alpha: Double = 1) {
        self = Color(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: alpha
        )
    }
}
