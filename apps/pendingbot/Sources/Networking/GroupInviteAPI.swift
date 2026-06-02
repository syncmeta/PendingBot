import Foundation

// Per-inviter group invite-link API (decisions.md D2). Mirrors the bot invite
// model: every member mints their own reusable, revocable token to the same
// group; joining records invited_by. The old shared group_join_handles code is
// superseded. See apps/edge/src/routes/group-invites.ts + migration
// 20260601082502.

struct GroupInviteLink: Decodable, Identifiable {
    let token: String
    let createdAt: String?
    let expiresAt: String?
    let revokedAt: String?

    var id: String { token }
    var isActive: Bool { revokedAt == nil }
}

/// Group preview returned when resolving a group invite token.
struct GroupInvitePreview: Decodable {
    let conversationId: String
    let title: String?
    let memberCount: Int
    let joinPolicy: String
    let inviterName: String?
}

/// Result of redeeming a group invite token: joined (scan_open) or a filed
/// request (approval).
struct GroupRedeemResult: Decodable {
    let conversationId: String
    let requestId: String?
    let joined: Bool
}

extension APIClient {
    private struct CreateInviteResponse: Decodable {
        let token: String
        let expiresAt: String?
    }

    private struct InviteLinksResponse: Decodable {
        let links: [GroupInviteLink]
    }

    private struct RedeemBody: Encodable {
        let message: String?
    }

    /// Mint a reusable group invite link. Caller must be a member of the group.
    func createGroupInviteLink(conversationId: String) async throws -> GroupInviteLink {
        let r: CreateInviteResponse = try await postEmpty("/v1/groups/\(conversationId)/invite-links")
        return GroupInviteLink(token: r.token, createdAt: nil, expiresAt: r.expiresAt, revokedAt: nil)
    }

    /// List the caller's own active invite links for a group (management UI).
    func listGroupInviteLinks(conversationId: String) async throws -> [GroupInviteLink] {
        let r: InviteLinksResponse = try await get("/v1/groups/\(conversationId)/invite-links")
        return r.links
    }

    /// Revoke a group invite link the caller minted.
    func revokeGroupInviteLink(token: String) async throws {
        try await deleteVoid("/v1/group-invites/\(token)")
    }

    /// Resolve a group invite token to a preview (the join confirmation page).
    func resolveGroupInvite(token: String) async throws -> GroupInvitePreview {
        try await get("/v1/group-invites/\(token)")
    }

    /// Redeem a group invite token: join (scan_open) or file a request
    /// (approval). Records invited_by either way.
    func redeemGroupInvite(token: String, message: String? = nil) async throws -> GroupRedeemResult {
        try await post("/v1/group-invites/\(token)/redeem", body: RedeemBody(message: message))
    }
}
