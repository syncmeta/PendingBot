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
