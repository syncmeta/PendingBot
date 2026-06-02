import Foundation

// Bot invite-link API (decisions.md D1). Bots are invite-only; the share
// artifact is an inviter-scoped, reusable, revocable token — not the bot's
// slug. Minting requires being a friend (or the creator) of the bot; the
// backend records who invited whom. See apps/edge/src/routes/bot-invites.ts
// and routes/bots.ts (/:id/invite-links).

struct BotInviteLink: Decodable, Identifiable {
    let token: String
    let createdAt: String?
    let expiresAt: String?
    let revokedAt: String?

    var id: String { token }
    var isActive: Bool { revokedAt == nil }
}

/// Bot preview returned when resolving an invite token (the "add bot" page).
struct BotInvitePreview: Decodable {
    let botId: String
    let displayName: String
    let slug: String?
    let modelId: String?
    let visibility: String?
    let inviterName: String?
}

extension APIClient {
    private struct CreateInviteResponse: Decodable {
        let token: String
        let expiresAt: String?
    }

    private struct InviteLinksResponse: Decodable {
        let links: [BotInviteLink]
    }

    private struct RedeemResponse: Decodable {
        let botId: String
    }

    /// Mint a reusable invite link for a bot. Caller must be a friend/creator.
    func createBotInviteLink(botId: String) async throws -> BotInviteLink {
        let r: CreateInviteResponse = try await postEmpty("/v1/bots/\(botId)/invite-links")
        return BotInviteLink(token: r.token, createdAt: nil, expiresAt: r.expiresAt, revokedAt: nil)
    }

    /// List the caller's own active invite links for a bot (management UI).
    func listBotInviteLinks(botId: String) async throws -> [BotInviteLink] {
        let r: InviteLinksResponse = try await get("/v1/bots/\(botId)/invite-links")
        return r.links
    }

    /// Revoke an invite link the caller minted.
    func revokeBotInviteLink(token: String) async throws {
        try await deleteVoid("/v1/bot-invites/\(token)")
    }

    /// Resolve an invite token to a bot preview (the add-bot confirmation page).
    func resolveBotInvite(token: String) async throws -> BotInvitePreview {
        try await get("/v1/bot-invites/\(token)")
    }

    /// Redeem an invite token: grant the bot + record attribution. Returns the
    /// bot id so the caller can open the chat.
    func redeemBotInvite(token: String) async throws -> String {
        let r: RedeemResponse = try await postEmpty("/v1/bot-invites/\(token)/redeem")
        return r.botId
    }
}
