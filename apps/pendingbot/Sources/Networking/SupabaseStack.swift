import Foundation
import Supabase

/// Single SupabaseClient for the app. supabase-swift is thread-safe and the
/// client is stateless aside from the auth session it manages internally —
/// so a singleton is the right shape, not a per-screen instance.
///
/// Default schema is set to `pendingbot`; auth.users / storage live in their
/// own schemas and the client surfaces those via dedicated APIs (`auth`,
/// `storage`) regardless of this default.
enum SupabaseStack {
    /// Lazily-initialized so we read HostedConfig.environment after the app
    /// has had a chance to override it (e.g. from a debug menu).
    static let shared: SupabaseClient = {
        let env = HostedConfig.environment
        // Arm the anon-write tripwire before the first request can be built.
        SupabaseAnonWriteGuard.arm(publishableKey: env.supabasePublishableKey)
        return SupabaseClient(
            supabaseURL: env.supabaseURL,
            supabaseKey: env.supabasePublishableKey,
            options: SupabaseClientOptions(
                db: SupabaseClientOptions.DatabaseOptions(schema: "pendingbot"),
                // Opt into the v3 behaviour described in
                // https://github.com/supabase/supabase-swift/pull/822 so
                // we no longer get the "Initial session emitted after
                // attempting to refresh the local stored session" warning
                // on every launch. AccountStore explicitly checks
                // session.expires_at before flipping `current`.
                auth: SupabaseClientOptions.AuthOptions(
                    // Force the data-protection keychain on every platform.
                    // Native macOS otherwise defaults to the legacy file
                    // login keychain, whose ACL is bound to the signing
                    // binary, so every rebuild re-prompts for the keychain
                    // password. See DataProtectionKeychainStorage.
                    storage: DataProtectionKeychainStorage(),
                    emitLocalSessionAsInitialSession: true
                ),
                global: SupabaseClientOptions.GlobalOptions(
                    session: guardedSession()
                )
            )
        )
    }()

    /// A private `URLSession` with `SupabaseAnonWriteGuard` first in the
    /// protocol chain. The guard claims only requests that already violate
    /// the invariant below, so everything else loads exactly as it would on
    /// `URLSession.shared`.
    private static func guardedSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [SupabaseAnonWriteGuard.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Fail-loud write gate
    //
    // supabase-swift's `SupabaseClient.adapt(request:)` fetches the auth
    // session with `try?` — if the session can't be resolved (keychain
    // miss, refresh failure, signed out) it silently falls back to the
    // anon key and sends the request anyway. For login-required writes
    // that surfaces as an RLS "permission denied for table X", which has
    // twice been misdiagnosed as a backend bug (see docs/tech-debt.md).
    //
    // INVARIANT: every login-required `.from(...).insert/update/delete/
    // upsert` and write-semantic `.rpc(...)` in this app goes through
    // `authedClient()` instead of touching `shared` directly. The gate
    // resolves the session explicitly (`auth.session` refreshes an
    // expired token) and throws `SupabaseAuthUnavailableError` when it
    // can't — a write request is NEVER sent bearing only the anon key.
    // Read paths may keep using `shared`; anon reads fail visibly as
    // empty results, not as corrupt-looking permission errors.
    //
    // Enforcement is mechanical, not just review: `SupabaseAnonWriteGuard`
    // is registered on this client's own URLSession and fails any
    // `/rest/v1/<table>` write still bearing the publishable key **before
    // the request leaves the device** (assertionFailure in Debug). The
    // library's `adapt` remains `try?` upstream — we deliberately do not
    // fork it; we refuse the request instead.
    //
    // `/rest/v1/rpc/...` stays outside the tripwire because read-only and
    // write RPCs are indistinguishable at the HTTP layer — write-semantic
    // RPCs still rely on the `authedClient()` convention. See
    // docs/tech-debt.md.
    // ─────────────────────────────────────────────────────────────────

    /// Returns the shared client only after proving a usable auth session
    /// exists (triggering a token refresh if needed). Throws
    /// `SupabaseAuthUnavailableError` otherwise — never lets a
    /// login-required write degrade to an anon-key request.
    static func authedClient() async throws -> SupabaseClient {
        do {
            _ = try await shared.auth.session
        } catch {
            throw SupabaseAuthUnavailableError(underlying: error)
        }
        return shared
    }
}

/// 登录态不可用（会话丢失 / 刷新失败 / 已登出）时写门抛出的错误。
/// 用户可见文案固定为中文提示；底层错误保留在 `underlying` 供日志排查。
struct SupabaseAuthUnavailableError: LocalizedError {
    let underlying: Error?

    var errorDescription: String? {
        "登录态不可用，请重新登录后再试"
    }
}
