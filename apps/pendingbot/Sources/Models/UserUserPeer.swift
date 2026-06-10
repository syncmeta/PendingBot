import Foundation

/// Resolved peer for a user_user conv shown in the list. Built once during
/// `load()` from the participants embed + the friends list so each row can
/// render the other person's name + avatar without per-row worker calls.
struct UserUserPeer: Hashable {
    let userId: String
    let alias: String?
    let displayName: String
    let avatarPath: String?
    /// Server-supplied placeholder-emoji seed (mirrored from the friends
    /// list HumanPick.avatarSeed) so the conv row renders the same emoji
    /// every viewer of this peer sees.
    let avatarSeed: String

    /// Title shown on the row + carried into ConversationView's pendingPeer
    /// so opening the chat doesn't re-flicker the header label.
    var rowName: String {
        if let a = alias, !a.isEmpty { return a }
        if !displayName.isEmpty { return displayName }
        return String(userId.prefix(8))
    }
}
