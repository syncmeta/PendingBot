import Foundation
import Observation

/// App-level inbox for incoming universal links (https deep links). The
/// app root pumps `onOpenURL` here; the tab that owns the matching
/// surface observes the relevant slot and consumes it.
///
/// Mirrors the IncomingCallStore.shared pattern (an @Observable singleton
/// read by the tab views) rather than threading a binding through the
/// whole hierarchy.
@MainActor
@Observable
final class DeepLinkStore {
    static let shared = DeepLinkStore()
    private init() {}

    /// Set when a `bot.pendingname.com/b/<token>` invite link is opened. The
    /// friends tab switches itself in and presents the add-bot preview,
    /// then clears this back to nil.
    var pendingAddBotToken: String?

    /// Set when a `bot.pendingname.com/g/<token>` group invite link is opened
    /// (decisions.md D2). The message tab presents the join-group preview,
    /// then clears this back to nil.
    var pendingJoinGroupToken: String?

    /// Parse an incoming URL into a pending action. Returns true when the
    /// link was recognised (so the caller can stop here).
    @discardableResult
    func handle(_ url: URL) -> Bool {
        let raw = url.absoluteString
        if BotShareLink.isBotShareLink(raw) {
            pendingAddBotToken = BotShareLink.token(fromScanned: raw)
            return true
        }
        if GroupShareLink.isGroupShareLink(raw) {
            pendingJoinGroupToken = GroupShareLink.token(fromScanned: raw)
            return true
        }
        return false
    }
}
