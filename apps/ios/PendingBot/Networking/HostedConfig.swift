import Foundation

/// Build-time constants for the hosted PendingBot service.
///
/// Two environments:
///   - `.dev`         — `wrangler dev` worker on localhost:8787 +
///                      `supabase start` Postgres on localhost:54321.
///                      Pre-launch loop: edit migration / RPC / handler
///                      → both run locally → iOS Debug build switches via
///                      `HostedConfig.environment = .dev` to verify
///                      end-to-end without touching prod.
///   - `.production`  — Cloudflare Worker at api.pendingname.com +
///                      Supabase project sslzhblojwkxfdyisity. The only
///                      deployed env until there are real users.
///
/// Default is `.production`; flip to `.dev` from a debug entry point when
/// running the local stack.
enum HostedConfig {
    enum Environment {
        case dev
        case production

        /// Worker base — REST writes (POST /v1/messages, /v1/upload, etc).
        var workerURL: URL {
            switch self {
            case .dev:        return URL(string: "http://localhost:8787")!
            case .production: return URL(string: "https://api.pendingname.com")!
            }
        }

        /// Supabase project URL — direct reads (RLS守门) + Realtime + Auth.
        var supabaseURL: URL {
            switch self {
            case .dev:        return URL(string: "http://localhost:54321")!
            case .production: return URL(string: "https://sslzhblojwkxfdyisity.supabase.co")!
            }
        }

        /// Public anon key for supabase-swift client. RLS守门, not a secret —
        /// embedded in the binary by design. The `.dev` value is the canonical
        /// `supabase start` anon key; if you've customised JWT_SECRET locally,
        /// swap in your own from `supabase status`.
        var supabaseAnonKey: String {
            switch self {
            case .dev:
                return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
            case .production:
                return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNzbHpoYmxvandreGZkeWlzaXR5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc2MTUwNzAsImV4cCI6MjA5MzE5MTA3MH0.GqN92fAn67SpeaaLNyrW5gFjlS0hhb41d5ziIwnfeHk"
            }
        }
    }

    /// Active environment. Default = production; flip to `.dev` when running
    /// the local `wrangler dev` + `supabase start` stack.
    static var environment: Environment = .production

    /// Convenience aliases — old code reads `HostedConfig.serverURL`. Until B9's
    /// full Networking rewrite, route this to the active env's worker.
    static var serverURL: URL { environment.workerURL }
    static var supabaseURL: URL { environment.supabaseURL }
    static var supabaseAnonKey: String { environment.supabaseAnonKey }

    static let displayName = "大绿豆"
}
