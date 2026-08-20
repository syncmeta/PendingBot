import Foundation
import Supabase
#if os(iOS)
import UIKit
#endif

/// Email-based sign-in via Supabase OTP.
///
/// Two-step flow:
///   1. `requestCode(email:)` — Supabase sends a 6-digit code to the
///      address. The first time this triggers `shouldCreateUser=true`
///      so the user row is provisioned on the way through.
///   2. `verify(email:, code:)` — exchange the code for a session.
///
/// Server-side prerequisite: Supabase project → Authentication →
/// Providers → Email is enabled (default on). Email templates can stay
/// at the supabase defaults; the OTP code is rendered in the {{Token}}
/// placeholder of the magic-link template by default.
@MainActor
enum EmailSignIn {
    enum Error: Swift.Error, LocalizedError {
        case underlying(Swift.Error)
        var errorDescription: String? {
            switch self {
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    /// Send the OTP. Throws if the address is malformed or rate-limited.
    ///
    /// `captchaToken` is the Cloudflare Turnstile token obtained from
    /// `TurnstileWebView`. Required when the Supabase project has
    /// captcha protection enabled (local dev: `supabase/config.toml`,
    /// remote: Dashboard → Auth). Pass `nil` only for tests / local
    /// runs where captcha is intentionally off.
    static func requestCode(email: String, captchaToken: String? = nil) async throws {
        do {
            try await SupabaseStack.shared.auth.signInWithOTP(
                email: email,
                shouldCreateUser: true,
                captchaToken: captchaToken
            )
        } catch {
            throw Error.underlying(error)
        }
    }

    /// Exchange the 6-digit code for a session. supabase-swift returns
    /// an AuthResponse whose .session is non-nil after a successful
    /// email verifyOTP — pull that out for the caller's convenience.
    static func verify(email: String, code: String) async throws -> Session {
        do {
            let response = try await SupabaseStack.shared.auth.verifyOTP(
                email: email,
                token: code,
                type: .email
            )
            if let session = response.session {
                return session
            }
            // Pull whatever the auth client persisted as a fallback.
            return try await SupabaseStack.shared.auth.session
        } catch {
            throw Error.underlying(error)
        }
    }

    /// Exchange a Supabase magic-link token hash for a persisted session.
    /// Used by PendingBot Mac QR login: the signed-in phone approves the
    /// device-login challenge, the worker returns a one-time token hash, and
    /// this Mac establishes the same normal Supabase Auth session as email OTP.
    static func verifyTokenHash(_ tokenHash: String) async throws -> Session {
        do {
            let response = try await SupabaseStack.shared.auth.verifyOTP(
                tokenHash: tokenHash,
                type: .email
            )
            if let session = response.session {
                return session
            }
            return try await SupabaseStack.shared.auth.session
        } catch {
            throw Error.underlying(error)
        }
    }
}

struct PendingBotDeviceLoginChallenge: Decodable, Equatable {
    let challengeId: String
    let secret: String
    let code: String
    let qrPayload: String
    let expiresAt: String
    let status: String
}

struct PendingBotDeviceLoginPollResponse: Decodable, Equatable {
    let status: String
    let deviceGrantToken: String?
    let supabaseTokenHash: String?
    let grantId: String?
    let subjectId: String?
    let grantKind: String?
    let scopes: [String]?
    let familyCredential: String?
}

struct PendingBotDeviceLoginAPI {
    let workerURL: URL
    let session: URLSession

    init(workerURL: URL = HostedConfig.environment.workerURL,
         session: URLSession = .shared) {
        self.workerURL = workerURL
        self.session = session
    }

    func createChallenge(
        deviceName: String = currentPendingBotDeviceName(),
        devicePublicKey: String = currentPendingBotDevicePublicKey()
    ) async throws -> PendingBotDeviceLoginChallenge {
        struct Body: Encodable {
            let appKind: String
            let deviceName: String
            let devicePublicKey: String
            let scopes: [String]
        }
        return try await post(
            path: "v1/device-login/challenges",
            body: Body(
                appKind: "pendingbot_macos",
                deviceName: deviceName,
                devicePublicKey: devicePublicKey,
                scopes: ["subject:read", "crew:read", "crew:write"]
            )
        )
    }

    func poll(
        challengeId: String,
        secret: String
    ) async throws -> PendingBotDeviceLoginPollResponse {
        let url = workerURL
            .appendingPathComponent("v1/device-login/challenges")
            .appendingPathComponent(challengeId)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "secret", value: secret)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return try await perform(request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: workerURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.notHTTP
        }
        if !(200..<300).contains(http.statusCode) {
            let bodyMsg = String(data: data, encoding: .utf8) ?? ""
            let envelope = (try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data))?.error
            switch http.statusCode {
            case 401:
                throw APIError.unauthorized
            case 410:
                throw APIError.gone(message: envelope?.message ?? bodyMsg)
            default:
                throw APIError.http(
                    status: http.statusCode,
                    code: envelope?.code,
                    message: envelope?.message,
                    body: bodyMsg
                )
            }
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decode(underlying: error, body: String(data: data, encoding: .utf8) ?? "<binary>")
        }
    }

}

private func currentPendingBotDeviceName() -> String {
    #if os(macOS)
    return Host.current().localizedName ?? "PendingBot Mac"
    #elseif os(iOS)
    return UIDevice.current.name
    #else
    return "PendingBot Device"
    #endif
}

private func currentPendingBotDevicePublicKey() -> String {
    "pendingbot-macos-\(UUID().uuidString)"
}
