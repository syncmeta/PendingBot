import Foundation
import Supabase

// ─────────────────────────────────────────────────────────────────────
// MARK: - Shared human-contacts fetch (iOS + macOS one implementation)
//
// `GET /v1/contacts` lives here as ONE worker call returning a neutral
// `ContactProfile` DTO, so iOS (`ContactsAPI` → `FriendsTabView.HumanPick`) and
// macOS (`FriendsDataSource` → `HumanContact`) both decode the same payload
// instead of two hand-copied request+decode blocks that could drift.
//
// The endpoint exists because `pendingbot.users` RLS is self-only — joining a
// peer's display_name / avatar on the client returns null, so the worker
// attaches those with service-role.
// ─────────────────────────────────────────────────────────────────────

/// One human contact with the peer profile fields the worker attaches. Neutral
/// (no view coupling) so both platforms project their own list model.
struct ContactProfile: Decodable, Equatable, Hashable {
    let userId: String
    let alias: String?
    let displayName: String
    let avatarPath: String?
    /// Server-supplied placeholder-emoji seed. Older worker builds may omit it;
    /// callers default to `userId` so the emoji renders consistently.
    let avatarSeed: String?
    /// Friend-added time as epoch seconds (`user_contacts.created_at`), drives
    /// the "按加好友时间" sort. Optional on older worker builds; default 0.
    let addedAt: Int?
}

enum ContactsFetch {
    /// Full contacts list with peer profile fields, ordered oldest-friend-first.
    ///
    /// Pass `viaHandleId` to narrow to contacts who reached the caller via that
    /// specific handle (drives the per-handle friend list in 我的隐私号 详情页).
    static func fetch(viaHandleId: String? = nil) async throws -> [ContactProfile] {
        var url = HostedConfig.environment.workerURL
            .appendingPathComponent("v1/contacts")
        if let viaHandleId, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = [URLQueryItem(name: "via_handle_id", value: viaHandleId)]
            if let withQuery = comps.url { url = withQuery }
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let token = try await SupabaseStack.shared.auth.session.accessToken
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct Payload: Decodable { let contacts: [ContactProfile] }
        return try JSONDecoder().decode(Payload.self, from: data).contacts
    }
}
