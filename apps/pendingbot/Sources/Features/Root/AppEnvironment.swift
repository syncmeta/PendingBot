import SwiftUI

// ── EnvironmentValues ───────────────────────────────────────────────────────
// The TabRoot owns the active APIClient + Account; child views read them
// via @Environment so we don't have to thread bindings through every layer.
// Hoisted out of TabRoot's iOS fence so the keys exist on macOS too — ~15
// shared `Features/*` views read \.api / \.account and must compile on both.

struct AccountKey: EnvironmentKey { static let defaultValue: Account? = nil }
struct APIKey: EnvironmentKey { static let defaultValue: APIClient? = nil }

extension EnvironmentValues {
    var account: Account? {
        get { self[AccountKey.self] }
        set { self[AccountKey.self] = newValue }
    }
    var api: APIClient? {
        get { self[APIKey.self] }
        set { self[APIKey.self] = newValue }
    }
}
