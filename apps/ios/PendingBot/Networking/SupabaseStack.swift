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
        return SupabaseClient(
            supabaseURL: env.supabaseURL,
            supabaseKey: env.supabaseAnonKey,
            options: SupabaseClientOptions(
                db: SupabaseClientOptions.DatabaseOptions(schema: "pendingbot")
            )
        )
    }()
}
