import SwiftUI
import UIKit

/// Mac Catalyst detection. Project ships with
/// `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`, so on macOS the binary
/// runs as native Catalyst and reports `userInterfaceIdiom == .mac`. On
/// iPhone / iPad it stays `.phone` / `.pad`. Cached because the value
/// can't change at runtime.
enum Platform {
    static let isMac: Bool = UIDevice.current.userInterfaceIdiom == .mac

    /// Multiplier applied to all `Theme.Fonts.*` sizes on Mac so the UI
    /// reads at desktop density (Mac users sit further from the screen
    /// than phone users; iOS-default 17pt body looks ballooned on a
    /// 27" monitor). Applied centrally in Theme so individual call
    /// sites don't have to know they're on Mac.
    static let macFontScale: CGFloat = 0.88
}
