import SwiftUI

/// App-wide appearance override: follow the system, or pin light / dark.
///
/// Stored device-local via `@AppStorage(appearanceStorageKey)` — appearance is
/// a per-device preference, so (unlike notification mode) it is *not* synced to
/// the server. Both `@main` scenes (iOS `PendingBotApp`, macOS `PendingBotApp`)
/// read the same key and drive `.preferredColorScheme(_.colorScheme)`; the
/// settings picker writes it. `.system` resolves to `nil`, which hands control
/// back to the OS appearance.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// The `UserDefaults` / `@AppStorage` key shared by the scenes and the picker.
    static let storageKey = "appearance_mode"

    /// Default when nothing is stored: follow the system. (Held at `.light`
    /// during the dark-mode rollout; flipped after D3/D4 landed and the dark
    /// UI passed visual QA on 2026-06-12.)
    static let `default`: AppearanceMode = .system

    /// What `.preferredColorScheme(_:)` wants — `nil` = follow system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }
}
