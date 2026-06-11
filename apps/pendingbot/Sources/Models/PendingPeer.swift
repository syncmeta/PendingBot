import Foundation

/// Identifies the peer for a conversation that hasn't been materialised in
/// the DB yet — set when the user taps a friend (bot or human) in the
/// friends tab. We defer creating the `conversations` row until they
/// actually send a first message, so empty/abandoned chats don't pile up
/// in the message list.
struct PendingPeer: Hashable {
    let kind: String       // "bot" | "user"
    let peerId: String
    let displayName: String
    /// Peer avatar carried over from whatever list the tap came from
    /// (message list / friends list), so the chat header + incoming
    /// bubbles render the correct face on the very first frame instead
    /// of flashing a generic glyph until `loadPeerProfileIfNeeded()`'s
    /// round-trip lands. nil when the tap origin had no avatar (e.g. the
    /// group-member-tap path); `peerProfileForBubble` falls back to the
    /// peer id as the emoji seed in that case.
    var avatarPath: String? = nil
    var avatarSeed: String? = nil
    /// Pre-resolved conv id, populated by the friends-tab tap path when
    /// we already looked up the singleton user_user conv before navigating.
    /// When set, `pendingConversation(for:)` builds a fully-keyed Conversation
    /// instead of one with `id: ""`, so ConversationView jumps straight to
    /// loading existing history instead of waiting for a first message to
    /// materialize the row.
    var existingConvId: String? = nil
}
