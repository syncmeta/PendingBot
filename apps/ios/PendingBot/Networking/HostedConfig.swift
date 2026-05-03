import Foundation

/// Build-time constants for the hosted PendingBot service.
///
/// Two environments — `staging` and `prod` — selectable at runtime. Debug
/// builds default to staging; Release defaults to production. Manual override
/// goes through `HostedConfig.environment = .staging` (e.g. from a debug menu)
/// before the first network call lands.
enum HostedConfig {
    enum Environment {
        case staging
        case production

        /// Worker base — REST writes (POST /v1/messages, /v1/upload, etc).
        /// Single Worker for now (no staging deployment); staging falls
        /// through to production until a real staging Worker is provisioned.
        var workerURL: URL {
            URL(string: "https://api.pendingname.com")!
        }

        /// Supabase project URL — direct reads (RLS守门) + Realtime + Auth.
        var supabaseURL: URL {
            URL(string: "https://sslzhblojwkxfdyisity.supabase.co")!
        }

        /// Public anon key for supabase-swift client. RLS守门, not a secret —
        /// embedded in the binary by design.
        var supabaseAnonKey: String {
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNzbHpoYmxvandreGZkeWlzaXR5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc2MTUwNzAsImV4cCI6MjA5MzE5MTA3MH0.GqN92fAn67SpeaaLNyrW5gFjlS0hhb41d5ziIwnfeHk"
        }
    }

    /// Active environment. There's only one backend right now; the enum
    /// stays so we can re-introduce staging without churning call sites.
    static var environment: Environment = .production

    /// Convenience aliases — old code reads `HostedConfig.serverURL`. Until B9's
    /// full Networking rewrite, route this to the active env's worker.
    static var serverURL: URL { environment.workerURL }
    static var supabaseURL: URL { environment.supabaseURL }
    static var supabaseAnonKey: String { environment.supabaseAnonKey }

    static let displayName = "大绿豆"
}
