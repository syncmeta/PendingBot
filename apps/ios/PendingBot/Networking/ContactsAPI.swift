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
        struct Payload: Decodable {
            struct Row: Decodable {
                let userId: String
                let alias: String?
                let displayName: String
                let avatarPath: String?
                /// Server-supplied placeholder-emoji seed — see HumanPick.avatarSeed.
                /// Older worker builds may omit the field; default to userId so the
                /// emoji still renders consistently across viewers (everyone hashes
                /// the same fallback).
                let avatarSeed: String?
            }
            let contacts: [Row]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.contacts.map {
            FriendsTabView.HumanPick(
                id: $0.userId,
                alias: $0.alias,
                displayName: $0.displayName,
                avatarPath: $0.avatarPath,
                avatarSeed: $0.avatarSeed ?? $0.userId
            )
        }
    }
}
