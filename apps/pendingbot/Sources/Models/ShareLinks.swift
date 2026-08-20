import Foundation

/// Codec for the bot-share deep link (decisions.md D1 — invite-only model).
///
/// Encoded form is `https://bot.pendingname.com/b/<token>` — same `bot.`
/// subdomain as the contact/group QRs (so the Universal Links entitlement
/// applies), AASA path `/b/` (see apps/edge/src/routes/well-known.ts). The
/// payload is an inviter-scoped, revocable invite *token* (minted by
/// POST /v1/bots/:id/invite-links), NOT the bot slug — bots are invite-only.
/// The token is opaque (64 hex); not normalised.
enum BotShareLink {
    static let host = "bot.pendingname.com"
    static let pathPrefix = "/b/"

    /// Matches *pendingname.com so apex-host links (pre-`bot.` subdomain)
    /// still parse, mirroring PendingBotQR.
    private static let urlHostSuffix = "pendingname.com"

    static func url(forToken token: String) -> String {
        "https://\(host)\(pathPrefix)\(token)"
    }

    /// Parse a payload back into the bare invite token. Accepts the current
    /// `bot.pendingname.com/b/<token>` form, the legacy apex form, and a
    /// bare token. Opaque — returned verbatim.
    static func token(fromScanned raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           url.host?.lowercased().hasSuffix(urlHostSuffix) == true,
           url.path.hasPrefix(pathPrefix) {
            let token = String(url.path.dropFirst(pathPrefix.count))
            if !token.isEmpty { return token }
        }
        return trimmed
    }

    /// Strict check: only true when the payload is unambiguously a
    /// bot-share URL (`*pendingname.com/b/<token>`). Bare tokens are not
    /// recognised here (indistinguishable from arbitrary text).
    static func isBotShareLink(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.host?.lowercased().hasSuffix(urlHostSuffix) == true,
              url.path.hasPrefix(pathPrefix) else { return false }
        return !url.path.dropFirst(pathPrefix.count).isEmpty
    }
}

/// Codec for the group-invite deep link (decisions.md D2 — per-inviter).
///
/// Encoded form is `https://bot.pendingname.com/g/<token>` — AASA path `/g/`.
/// The payload is an inviter-scoped, revocable group invite *token* (minted by
/// POST /v1/groups/:id/invite-links). Every member's link is a distinct token;
/// joining records invited_by. Supersedes the shared group_join_handles code.
enum GroupShareLink {
    static let host = "bot.pendingname.com"
    static let pathPrefix = "/g/"
    private static let urlHostSuffix = "pendingname.com"

    static func url(forToken token: String) -> String {
        "https://\(host)\(pathPrefix)\(token)"
    }

    /// Parse a payload back into the bare group invite token. Accepts the
    /// `*pendingname.com/g/<token>` form and a bare token. Opaque — verbatim.
    static func token(fromScanned raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           url.host?.lowercased().hasSuffix(urlHostSuffix) == true,
           url.path.hasPrefix(pathPrefix) {
            let token = String(url.path.dropFirst(pathPrefix.count))
            if !token.isEmpty { return token }
        }
        return trimmed
    }

    /// Strict check: only true for an unambiguous `*pendingname.com/g/<token>`.
    static func isGroupShareLink(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.host?.lowercased().hasSuffix(urlHostSuffix) == true,
              url.path.hasPrefix(pathPrefix) else { return false }
        return !url.path.dropFirst(pathPrefix.count).isEmpty
    }
}
