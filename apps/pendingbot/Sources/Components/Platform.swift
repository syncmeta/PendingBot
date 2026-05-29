#if os(iOS)
import SwiftUI
import UIKit

/// Mac Catalyst detection. Compile-time `targetEnvironment(macCatalyst)`
/// is the only reliable signal — `UIDevice.current.userInterfaceIdiom`
/// returns `.pad` on Catalyst when the binary ships without "Optimize
/// Interface for Mac", which silently dropped MacTabRoot back into the
/// iOS `TabView` branch and the bottom-bar-rendered-at-the-top
/// regression that follows.
enum Platform {
    #if targetEnvironment(macCatalyst)
    static let isMac: Bool = true
    #else
    static let isMac: Bool = false
    #endif

    /// Multiplier applied to all `Theme.Fonts.*` sizes on Mac so the UI
    /// reads at desktop density (Mac users sit further from the screen
    /// than phone users; iOS-default 17pt body looks ballooned on a
    /// 27" monitor). Applied centrally in Theme so individual call
    /// sites don't have to know they're on Mac.
    static let macFontScale: CGFloat = 0.88
}
#endif
