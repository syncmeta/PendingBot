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
///                  api.example.com + Supabase project YOUR-PROJECT
///                  (EU / Frankfurt eu-central-1).
///                  Called `.remote` (not `.production`) on purpose: there are
///                  no real users yet, so labelling it "production" overstates
///                  what it is. After v1 ships we'll split this into
///                  `.staging` + `.production` (see CLAUDE.md).
///
/// Default is `.remote`; flip to `.dev` from a debug entry point when running
/// the local stack.
enum HostedConfig {
    /// Placeholder literals for the hosted-backend coordinates.
    ///
    /// A public clone of this repo carries these instead of real project
    /// coordinates. `isConfigured` compares against them, so **when you wire
    /// in your own backend, change only the `.remote` values below — never
    /// these literals**; editing them would make the check permanently pass
    /// and the app would go back to failing silently.
    enum Placeholder {
        static let workerURL = "https://api.example.com"
        static let supabaseURL = "https://YOUR-PROJECT.supabase.co"
        static let supabasePublishableKey = "sb_publishable_REPLACE_ME"
        static let turnstileSiteKey = "0x0000000000000000000000"
        static let turnstileHost = "https://example.com"
    }

    enum Environment {
        case dev
        case remote

        /// Worker base — REST writes (POST /v1/messages, /v1/upload, etc).
        var workerURL: URL {
            switch self {
            case .dev:    return URL(string: "http://localhost:8787")!
            case .remote: return URL(string: "https://api.example.com")!
            }
        }

        /// Supabase project URL — direct reads (RLS守门) + Realtime + Auth.
        var supabaseURL: URL {
            switch self {
            case .dev:    return URL(string: "http://localhost:54321")!
            case .remote: return URL(string: "https://YOUR-PROJECT.supabase.co")!
            }
        }

        /// Publishable API key for supabase-swift client. RLS守门, not a
        /// secret — embedded in the binary by design. `.remote` is the
        /// project's `sb_publishable_…` key (new key system; the legacy anon
        /// JWT is retired there). `.dev` keeps the canonical `supabase start`
        /// legacy anon JWT — the local CLI stack still issues that format;
        /// swap in your own from `supabase status` if customised.
        var supabasePublishableKey: String {
            switch self {
            case .dev:
                return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
            case .remote:
                return "sb_publishable_REPLACE_ME"
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
            // Live site key registered for `example.com` in
            // the Cloudflare Turnstile dashboard. The matching secret
            // is only useful once it's pasted into the remote Supabase
            // project (Dashboard → Authentication → Captcha protection)
            // — until that's done, the iOS client will still mint
            // tokens but the Supabase backend won't validate them, so
            // captcha effectively no-ops.
            case .remote: return "0x0000000000000000000000"
            }
        }

        /// Origin that hosts the inline Turnstile challenge page inside
        /// the in-app WKWebView. Must match a hostname registered for
        /// the Turnstile site key — Cloudflare validates the embedding
        /// origin server-side. We use `example.com` to match the
        /// project's existing convention (AASA, Universal Links, and
        /// QR-code landing all live under `bot.`), keeping iOS-app
        /// origins namespaced away from the brand root `pendingname.com`
        /// in case that ever gets a separate web property.
        var turnstileHost: URL {
            switch self {
            case .dev:    return URL(string: "https://localhost")!
            case .remote: return URL(string: "https://example.com")!
            }
        }

        // ── Configured-or-not ─────────────────────────────────────────
        // The single source of truth for "does this build have a backend
        // to talk to". Entry points read it to decide whether to run a
        // flow or say plainly that the coordinate isn't there; README
        // points at these two properties instead of keeping its own list,
        // so filling in real coordinates silences the app and updates the
        // docs in one move.
        //
        // Deliberately NOT checked at launch: someone who never taps
        // sign-in never needs to hear about it, and a startup warning
        // nobody can act on just trains people to ignore warnings.

        /// Worker + Supabase coordinates are real (not placeholders).
        /// Everything in this app — sign-in, chat, contacts — goes through
        /// one of those two, so this gates the whole hosted line.
        var isConfigured: Bool {
            switch self {
            // localhost coordinates are the canonical `supabase start` /
            // `wrangler dev` values, not placeholders — a local stack is
            // configured by definition.
            case .dev: return true
            case .remote:
                return workerURL.absoluteString != Placeholder.workerURL
                    && supabaseURL.absoluteString != Placeholder.supabaseURL
                    && supabasePublishableKey != Placeholder.supabasePublishableKey
            }
        }

        /// Email-code sign-in additionally needs Turnstile: the OTP request
        /// carries a captcha token, and Supabase Auth rejects it when captcha
        /// protection is on. Kept separate from `isConfigured` on purpose —
        /// Apple / Google sign-in work without Turnstile, so folding it into
        /// one flag would block two paths that are actually fine.
        var isEmailSignInConfigured: Bool {
            switch self {
            case .dev: return true
            case .remote:
                return isConfigured
                    && turnstileSiteKey != Placeholder.turnstileSiteKey
                    && turnstileHost.absoluteString != Placeholder.turnstileHost
            }
        }

        // ── Telemetry / billing-identity SDK keys ──────────────────────
        // All three are public/client keys by design (PostHog project
        // token, Sentry DSN, RevenueCat public SDK key — none are secrets,
        // they're meant to ship in the binary). An EMPTY string means
        // "feature off": Telemetry.configure() skips that SDK entirely, so
        // `.dev` builds (and any env with a key not yet provisioned) stay
        // silent rather than spraying junk data. The user identifier sent
        // to all three is `subject_id` (= auth.users.id), matching the edge
        // side (distinctId=subjectId) — never email/PII.

        /// PostHog project API key (`phc_…`). Same project as the edge
        /// `POSTHOG_KEY`; the token is write-only ingest, safe in-binary.
        var posthogKey: String {
            switch self {
            case .dev:    return ""
            case .remote: return ""   // fill in your own PostHog project key ("" = off)
            }
        }

        /// PostHog ingest host. The project lives in PostHog's EU region.
        var posthogHost: String {
            switch self {
            case .dev:    return "https://eu.i.posthog.com"
            case .remote: return "https://eu.i.posthog.com"
            }
        }

        /// Sentry DSN for the **Apple/iOS** project (distinct from the edge
        /// worker's JS DSN — different platform project in the same org).
        var sentryDSN: String {
            switch self {
            case .dev:    return ""
            case .remote: return ""   // fill in your own Sentry DSN ("" = off)
            }
        }

        /// RevenueCat public SDK key for the Apple app (`appl_…`).
        var revenueCatKey: String {
            switch self {
            case .dev:    return ""
            case .remote: return ""   // fill in your own RevenueCat public SDK key ("" = off)
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
    static var supabasePublishableKey: String { environment.supabasePublishableKey }

    /// See `Environment.isConfigured`. README's capability list cites this
    /// rather than restating it, so the two can't drift.
    static var isConfigured: Bool { environment.isConfigured }

    /// See `Environment.isEmailSignInConfigured`.
    static var isEmailSignInConfigured: Bool { environment.isEmailSignInConfigured }

    /// Shown when someone actually reaches for a sign-in method this build
    /// can't perform. Copy rules: state what this repo ships and where to
    /// wire in your own — no "failed", no "error", no apology. Nothing is
    /// broken; a public clone simply doesn't carry someone else's backend.
    static let unconfiguredNotice = """
        本仓库只带占位后端坐标，登录走不通。\
        要接自己的 Cloudflare Worker + Supabase，见 README 的「配置」一节。
        """

    /// Same, for the email-code path specifically.
    static let emailSignInUnconfiguredNotice = """
        邮箱验证码登录还需要 Cloudflare Turnstile 站点密钥，本仓库只带占位值。\
        填法见 README 的「配置」一节。
        """

    static let displayName = "大绿豆"
}
