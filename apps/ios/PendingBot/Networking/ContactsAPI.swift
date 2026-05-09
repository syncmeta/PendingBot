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
    static func fetchContacts() async throws -> [FriendsTabView.HumanPick] {
        let url = HostedConfig.environment.workerURL
            .appendingPathComponent("v1/contacts")
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
            }
            let contacts: [Row]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.contacts.map {
            FriendsTabView.HumanPick(
                id: $0.userId,
                alias: $0.alias,
                displayName: $0.displayName,
                avatarPath: $0.avatarPath
            )
        }
    }
}
