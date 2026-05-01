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
        var workerURL: URL {
            switch self {
            case .staging:
                return URL(string: "https://api-staging.pendingname.com")!
            case .production:
                return URL(string: "https://api.pendingname.com")!
            }
        }

        /// Supabase project URL — direct reads (RLS守门) + Realtime + Auth.
        var supabaseURL: URL {
            switch self {
            case .staging:
                return URL(string: "https://REPLACE-ME-staging.supabase.co")!
            case .production:
                return URL(string: "https://REPLACE-ME-prod.supabase.co")!
            }
        }

        /// Public anon key for supabase-swift client. RLS守门, not a secret.
        /// Real values land via build setting / Info.plist injection (TODO B9).
        var supabaseAnonKey: String {
            switch self {
            case .staging:
                return "REPLACE_ME_STAGING_ANON_KEY"
            case .production:
                return "REPLACE_ME_PROD_ANON_KEY"
            }
        }
    }

    /// Active environment. Set once at app launch (e.g. from PendingBotApp).
    /// Default below routes Debug builds to staging, Release to prod.
    #if DEBUG
    static var environment: Environment = .staging
    #else
    static var environment: Environment = .production
    #endif

    /// Convenience aliases — old code reads `HostedConfig.serverURL`. Until B9's
    /// full Networking rewrite, route this to the active env's worker.
    static var serverURL: URL { environment.workerURL }
    static var supabaseURL: URL { environment.supabaseURL }
    static var supabaseAnonKey: String { environment.supabaseAnonKey }

    static let displayName = "大绿豆"
}

// ── Auth exchange ─────────────────────────────────────────────────────────
//
// HISTORICAL: This used to bridge Clerk JWT → pbk_live_* bearer key. The new
// architecture replaces Clerk with Supabase Auth (Sign in with Apple via
// supabase-swift). This struct is preserved so existing callers compile
// while the auth migration lands in B9. New writes go through Supabase JWT
// directly on the X-Supabase-Auth header — no exchange step needed.

/// Network glue for the legacy Clerk JWT → pbk_live_* exchange.
/// **Do not call from new code.** Will be removed when Supabase Auth lands.
enum AuthExchange {
    struct Response: Decodable {
        let ok: Bool
        let key: String
        let user: User
        struct User: Decodable {
            let id: String
            let display_name: String
            let email: String?
            let is_admin: Bool
        }
    }

    enum ExchangeError: LocalizedError {
        case http(status: Int, body: String)
        case malformedResponse
        var errorDescription: String? {
            switch self {
            case .http(let status, let body):
                return "服务器拒绝了登录 (\(status))：\(body)"
            case .malformedResponse:
                return "服务器返回了无法识别的内容"
            }
        }
    }

    /// POST /api/auth/clerk/exchange. Sends the Clerk session JWT and gets
    /// back a long-lived pbk_live_* bearer key bound to this user.
    static func exchange(clerkJwt: String,
                         against base: URL = HostedConfig.serverURL) async throws -> Response {
        var req = URLRequest(url: base.appendingPathComponent("api/auth/clerk/exchange"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // clientHint lets the server tag fresh accounts with channel='ios'
        // so iOS users aren't bucketed alongside web logins for analytics.
        req.httpBody = try JSONEncoder().encode([
            "token": clerkJwt,
            "clientHint": "ios",
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            throw ExchangeError.http(
                status: http?.statusCode ?? -1,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ExchangeError.malformedResponse
        }
    }
}
