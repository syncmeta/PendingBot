// Extracted from the vendored BubbleView.swift so this type can be compiled
// into test bundles (and any other Foundation-only context) without dragging
// in the full SwiftUI vendored file.
//
// BubbleView.swift references this type directly; because both files land in
// the same module there is no import needed.
import Foundation

/// Per-message sender resolution for group convs. ConversationView
/// builds a `[messageKey: GroupBubbleSender]` map from the conv's
/// participants and hands the right one to each BubbleView.
struct GroupBubbleSender: Equatable {
    enum Kind { case bot, user }
    let kind: Kind
    /// participant_id (bot.id or user.id). Drives the bot path which
    /// uses BotAvatar(emojiSeed: id, …); for users see `avatarSeed`.
    let id: String
    /// Per-group nickname if set; otherwise the bot.display_name /
    /// user.display_name. Rendered above the bubble.
    let displayName: String
    /// Avatar attachment id for users (nil for bots, which use the
    /// emoji-seed avatar derived from id).
    let avatarPath: String?
    /// Server-supplied placeholder-emoji seed for user senders
    /// (users.custom_fields.avatar_seed). Same value across every
    /// viewer's device so the same person renders the same emoji.
    /// Falls back to `id` for legacy accounts that never bootstrapped.
    let avatarSeed: String
    var isCaptain: Bool = false        // PENDINGCREW SHIM: crew role for avatar badge
    var sessionStatus: String? = nil   // PENDINGCREW SHIM: session run-state dot
    var isSession: Bool = false        // PENDINGCREW SHIM: render terminal-icon avatar
    var hasNotification: Bool = false  // PENDINGCREW SHIM: 未读待办/消息 → 头像红点(盖过状态点)
}
