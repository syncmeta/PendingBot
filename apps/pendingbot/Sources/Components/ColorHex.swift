import SwiftUI

extension Color {
    /// Build a Color from a 24-bit sRGB hex literal. Example: `Color(hex: 0x044735)`.
    ///
    /// Cross-platform brand-color helper — moved out of the iOS-only `Theme.swift`
    /// so macOS views (`Sources/Mac/*`) can reuse the same brand palette hex values
    /// and stay visually aligned with iOS.
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
