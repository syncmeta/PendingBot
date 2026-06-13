/// PendingCrew-side extensions to the vendored Theme.
/// These shims add tokens/helpers that PendingCrew needs but that live
/// outside the vendored Theme.swift (which must not be hand-edited).
///
/// **Never edit** `apps/pendingcrew/Sources/Chat/Vendored/Theme.swift` —
/// put all PendingCrew-specific additions here instead.
import SwiftUI

// ── Metrics extras ──────────────────────────────────────────────────────────

extension Theme.Metrics {
    /// Standard crew avatar diameter (30 pt). Used by `CrewAvatar` as the
    /// default `size` parameter; matches the iOS equivalent (28–32 pt range).
    static let avatar: CGFloat = 30
}

// ── Font call-site shims ─────────────────────────────────────────────────────
//
// CrewTheme.Fonts used positional (unlabeled) size parameters, e.g.
//   CrewTheme.Fonts.system(14, weight: .medium)
// The vendored Theme.Fonts uses labeled `size:`:
//   Theme.Fonts.system(size: 14, weight: .medium)
//
// These free functions in the Theme.Fonts namespace let existing call sites
// migrate one-for-one without touching argument labels everywhere.

extension Theme.Fonts {
    /// Convenience overload: positional `size` so macOS call sites that used
    /// `CrewTheme.Fonts.system(N)` / `CrewTheme.Fonts.system(N, weight: .X)`
    /// map directly after rename. Delegates to the canonical `system(size:…)`.
    static func system(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        system(size: size, weight: weight)
    }

    /// Convenience overload: positional `size` for `rounded`. Maps
    /// `CrewTheme.Fonts.rounded(N, weight: .X)` → `Theme.Fonts.rounded(N, weight: .X)`.
    static func rounded(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        rounded(size: size, weight: weight)
    }

    /// `callout` alias (15 pt) — matches `CrewTheme.Fonts.callout`. Internally
    /// delegates to `subheadline` which is the same size in the vendored Theme.
    static let callout = subheadline
}
