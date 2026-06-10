import Foundation
import Supabase

/// Worker-backed lookups for the friends list. Lives behind /v1/contacts
/// because pendingbot.users RLS is self-only — iOS can read its own
/// user_contacts rows, but joining to the peer's display_name / avatar_path
/// would silently return null on the client. The worker uses service-role
/// to attach those fields.
enum ContactsAPI {
    /// Full contacts list with peer profile fields. Order matches
    /// user_contacts.created_at ascending (oldest friend first).
    ///
    /// Pass `viaHandleId` to narrow the list to contacts who reached
    /// the caller via that specific handle — drives the per-handle
    /// friend list in 加我为好友的方式 → 我的隐私号 详情页。
    static func fetchContacts(viaHandleId: String? = nil) async throws -> [FriendsTabView.HumanPick] {
        // Request + decode lives in the shared `ContactsFetch.fetch()`
        // (Networking/) so iOS + macOS hit one implementation; this just maps the
        // neutral `ContactProfile` into the iOS view's `HumanPick`.
        try await ContactsFetch.fetch(viaHandleId: viaHandleId).map {
            FriendsTabView.HumanPick(
                id: $0.userId,
                alias: $0.alias,
                displayName: $0.displayName,
                avatarPath: $0.avatarPath,
                avatarSeed: $0.avatarSeed ?? $0.userId,
                addedAt: $0.addedAt ?? 0
            )
        }
    }
}
