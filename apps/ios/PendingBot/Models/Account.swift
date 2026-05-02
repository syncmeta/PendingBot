import Foundation

/// One signed-in user. Derived from a Supabase Session — `id` is the
/// auth.users uuid, `jwt` is the current access token (rotates on refresh).
///
/// Multi-account is not a thing in the new architecture (one Apple ID per
/// device per app); the type stays a struct rather than a singleton so views
/// can take it as a value without coupling to the store.
struct Account: Identifiable, Hashable, Sendable {
    /// Supabase auth.users.id (uuid string).
    let id: String
    /// Display name from auth metadata, falling back to the email local-part
    /// or a literal "你" if neither is available.
    let displayName: String
    let email: String?
    /// Current access token (Supabase JWT). Re-read from the store on use —
    /// supabase-swift refreshes it in the background and we don't want to
    /// hold a stale copy.
    let jwt: String
    /// HTTP base for Worker writes (e.g. POST /v1/messages).
    let workerURL: URL
}
