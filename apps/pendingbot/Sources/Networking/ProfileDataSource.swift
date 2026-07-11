import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Cross-platform profile write seam (§10 client Repository unify)
//
// The single seam for persisting the signed-in user's own profile row
// (display name + avatar attachment + the `custom_fields` knobs the random-roll
// onboarding stamps). The shared onboarding/edit surface
// (`Features/Onboarding/ProfileBootstrapView`, cross-platform — iOS cover +
// macOS onboarding/sheet) drives this one method instead of open-coding the
// `.from("users").update(...)` write per platform.
//
// Why a direct supabase UPDATE and not `/v1/me/profile`:
// the worker's `PATCH /v1/me/profile` (apps/edge/src/routes/me.ts) only accepts
// `notification_preview_mode` — its Zod body strips anything else and returns
// `{ ok: true }` having written nothing. display_name / avatar_path / avatar_seed
// have never gone through that endpoint; the verified iOS path writes them with a
// direct RLS-gated `users` UPDATE (policy `users_self_update` scopes it to the
// caller's own row). Routing the Mac write through `/v1/me/profile` would
// silently drop the name and avatar. So this façade preserves the iOS contract
// exactly — it just collapses the two open-coded copies into one.
//
// `@MainActor` to match `AccountStore` mirror updates the caller does right
// after; no `#if os(...)` — one implementation, both platforms.
// ─────────────────────────────────────────────────────────────────────

enum ProfileDataSource {
    /// Persist the user's own profile. `avatarSeed` always written into
    /// `custom_fields.avatar_seed`; `bootstrapped` is stamped to "1" so the
    /// onboarding gate flips. `attachmentId` (nil ⇒ omit the uploaded image,
    /// fall back to the deterministic seed avatar) maps to `users.avatar_path`.
    ///
    /// Mirrors `ProfileBootstrapView.save()` byte-for-byte on the wire — same
    /// `Patch` shape, same column names, same RLS — so the two platforms write
    /// identical rows. Throws on the supabase error so the caller can surface it
    /// and skip the `AccountStore.markBootstrapped` mirror update.
    @MainActor
    static func updateProfile(
        userId: String,
        displayName: String,
        avatarSeed: String,
        attachmentId: String?
    ) async throws {
        struct Patch: Encodable {
            let display_name: String
            let avatar_path: String?
            let custom_fields: [String: String]
        }
        let fields: [String: String] = [
            "avatar_seed": avatarSeed,
            "bootstrapped": "1",
        ]
        let aid = (attachmentId?.isEmpty == false) ? attachmentId : nil
        try await SupabaseStack.authedClient()
            .from("users")
            .update(Patch(display_name: displayName,
                          avatar_path: aid,
                          custom_fields: fields))
            .eq("id", value: userId)
            .execute()
    }
}
