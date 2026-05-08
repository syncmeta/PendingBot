import Foundation

/// Build-time constants for the hosted PendingBot service.
///
/// Pre-launch we run two environments:
///   - `.dev`     — `wrangler dev` worker on localhost:8787 + `supabase start`
///                  Postgres on localhost:54321. Edit migration / RPC / handler
///                  → both run locally → iOS Debug build flips
///                  `HostedConfig.environment = .dev` to verify end-to-end
///                  without touching the deployed stack.
///   - `.remote`  — the one deployed env: Cloudflare Worker at
///                  api.pendingname.com + Supabase project sslzhblojwkxfdyisity.
///                  Called `.remote` (not `.production`) on purpose: there are
///                  no real users yet, so labelling it "production" overstates
///                  what it is. After v1 ships we'll split this into
///                  `.staging` + `.production` (see CLAUDE.md).
///
/// Default is `.remote`; flip to `.dev` from a debug entry point when running
/// the local stack.
enum HostedConfig {
    enum Environment {
        case dev
        case remote

        /// Worker base — REST writes (POST /v1/messages, /v1/upload, etc).
        var workerURL: URL {
            switch self {
            case .dev:    return URL(string: "http://localhost:8787")!
            case .remote: return URL(string: "https://api.pendingname.com")!
            }
        }

        /// Supabase project URL — direct reads (RLS守门) + Realtime + Auth.
        var supabaseURL: URL {
            switch self {
            case .dev:    return URL(string: "http://localhost:54321")!
            case .remote: return URL(string: "https://sslzhblojwkxfdyisity.supabase.co")!
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
            case .remote:
                return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNzbHpoYmxvandreGZkeWlzaXR5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc2MTUwNzAsImV4cCI6MjA5MzE5MTA3MH0.GqN92fAn67SpeaaLNyrW5gFjlS0hhb41d5ziIwnfeHk"
            }
        }

        /// Cloudflare Turnstile public site key for the email-OTP signup
        /// gate. Public by design — the matching secret lives only on
        /// Supabase Auth (local: `supabase/config.toml`, remote:
        /// Dashboard → Authentication → Captcha protection).
        ///
        /// `.dev` uses Cloudflare's documented "always-passes" invisible
        /// test key so the local stack works offline. `.remote` must be
        /// the live site key registered for the host below.
        var turnstileSiteKey: String {
            switch self {
            case .dev:    return "1x00000000000000000000AA"
            // TODO(captcha): swap in the live Turnstile site key after
            // registering pendingname.com in the Cloudflare dashboard.
            // Until then `.remote` shares the dev test key — Supabase
            // backend captcha is also off in `.remote` until the matching
            // secret is set in Dashboard → Auth → Captcha protection.
            case .remote: return "1x00000000000000000000AA"
            }
        }

        /// Origin that hosts the inline Turnstile challenge page inside
        /// the in-app WKWebView. Must match a hostname registered for
        /// the Turnstile site key — Cloudflare validates the embedding
        /// origin server-side. We piggyback on the canonical site URL
        /// rather than registering a separate domain just for this.
        var turnstileHost: URL {
            switch self {
            case .dev:    return URL(string: "https://localhost")!
            case .remote: return URL(string: "https://pendingname.com")!
            }
        }
    }

    /// Active environment. Default = remote; flip to `.dev` when running
    /// the local `wrangler dev` + `supabase start` stack.
    static var environment: Environment = .remote

    /// Convenience aliases — old code reads `HostedConfig.serverURL`. Until B9's
    /// full Networking rewrite, route this to the active env's worker.
    static var serverURL: URL { environment.workerURL }
    static var supabaseURL: URL { environment.supabaseURL }
    static var supabaseAnonKey: String { environment.supabaseAnonKey }

    static let displayName = "大绿豆"
}
