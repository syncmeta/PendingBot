import SwiftUI
import UIKit

/// One place to change the look. Mirrors the design language used across
/// the PendingBot reference + the web `tokens.css`: deep-jade accent on
/// warm-ink neutrals, editorial serif for titles, rounded sans for chrome.
///
/// Each palette entry has matched light + dark variants so the app respects
/// the system trait. Dark variant is hand-tuned (not just inverted): keeps
/// the warm-cream feeling on light, and a warm-charcoal feeling on dark.
enum Theme {

    // ── Palette ─────────────────────────────────────────────────────────────

    enum Palette {
        /// Brand accent — light: #044735 (deep forest); dark: #7DC9A9 (lifted
        /// for contrast on charcoal). Both read as "PendingBot green".
        static let accent      = adaptive(light: 0x044735, dark: 0x7DC9A9)
        static let accentHover = adaptive(light: 0x0A6049, dark: 0x95DABB)
        /// Soft accent fill — user bubble + selected pills.
        static let accentBg    = adaptive(light: 0xE3EEEA, dark: 0x1F2C26)

        /// Page canvas — light: warm off-white; dark: warm charcoal.
        static let canvas        = adaptive(light: 0xFDFCFA, dark: 0x121110)
        /// Cards / sheets — sits a hair above canvas.
        static let surface       = adaptive(light: 0xFFFFFF, dark: 0x1A1917)
        /// Chips / pills / muted bg fills.
        static let surfaceMuted  = adaptive(light: 0xEFEEE9, dark: 0x24221E)

        /// Primary ink — warm near-black on light, warm near-white on dark.
        static let ink       = adaptive(light: 0x1B1A14, dark: 0xF1EFE7)
        /// Secondary — labels, timestamps, descriptions.
        static let inkMuted  = adaptive(light: 0x6E6A5C, dark: 0xA29D8E)
        /// Hairline borders — barely-there separators.
        static let hairline  = adaptive(light: 0xE2E0D7, dark: 0x2D2B25)

        /// User-message bubble — same as accentBg, named for clarity.
        static let userBubble = accentBg
    }

    // ── Typography ──────────────────────────────────────────────────────────

    enum Fonts {
        /// Serif display (system New York). Used for titles, header marks,
        /// avatar initials. Feels editorial vs the regular SF Pro UI.
        static func serif(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
            .system(size: size, weight: weight, design: .serif)
        }

        /// Rounded sans — softer than SF Pro, used for buttons, chip labels,
        /// nav, counters. Matches the warm palette.
        static func rounded(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }

        static let body            = Font.system(size: 16, weight: .regular)
        static let bodyEmphasized  = Font.system(size: 16, weight: .medium)
        static let footnote        = Font.system(size: 13, weight: .regular)
        static let caption         = Font.system(size: 12, weight: .regular)
        static let title           = serif(size: 28, weight: .semibold)
        static let sectionTitle    = serif(size: 20, weight: .semibold)
        static let monoSmall       = Font.system(size: 12, design: .monospaced)
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
    /// on iPad landscape and Mac Catalyst windows it keeps content from
    /// spreading across the full window width.
    func readableColumnWidth(
        _ maxWidth: CGFloat = Theme.Metrics.readableColumn
    ) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
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

// ── Adaptive light/dark color ───────────────────────────────────────────────

/// Build a Color that resolves to one hex on light, another on dark — using
/// UIColor's dynamicProvider under the hood so the system trait drives it.
private func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(uiColor: UIColor { trait in
        let hex = trait.userInterfaceStyle == .dark ? dark : light
        return UIColor(
            red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >>  8) & 0xFF) / 255,
            blue:  CGFloat( hex        & 0xFF) / 255,
            alpha: 1
        )
    })
}
