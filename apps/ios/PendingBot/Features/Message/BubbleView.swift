import SwiftUI

/// Asymmetric layout inspired by Claude.ai (not iMessage):
///   • Bot — borderless, left-aligned, avatar + name row, then content.
///   • User — right-aligned, soft-tinted bubble with rounded radius.
///
/// Bot messages render full Markdown (headings, lists, fenced code with a
/// copy/run toolbar, tables, blockquotes) via `MarkdownText`. User input is
/// plain text — they just typed it, no need to interpret syntax.
struct BubbleView: View {
    let message: ChatMessage
    let botName: String
    /// Conversation id — drives the per-conv pastel tint on BotAvatar.
    let conversationID: String
    /// Bot identity, passed in so the avatar emoji stays consistent for
    /// the same bot across all your conversations with it (background
    /// tint still varies per conv). nil falls back to conversationID
    /// for non-bot contexts.
    var botID: String? = nil
    /// Self-chat override: when set, the bot bubble uses the user's
    /// uploaded photo / BotAvatar(seed) instead of the standard
    /// per-bot glyph — the conversation reads as the user talking to
    /// a mirror of themselves.
    var selfAvatar: (seed: String, attachmentId: String?)? = nil
    /// Logged-in user's id, used to decide which side of the chat each
    /// bubble lives on. For user_user / group both parties share
    /// sender_type=="user"; without the id check both sides would
    /// render as right-aligned "mine" bubbles.
    var currentUserId: String? = nil
    /// Peer profile for user_user conversations — drives the left-side
    /// avatar on the other person's bubbles. nil for user_bot / self.
    /// `avatarSeed` is the server-supplied placeholder-emoji seed so the
    /// same person renders identically across every viewer's device.
    var peerProfile: (userId: String, displayName: String, avatarPath: String?, avatarSeed: String)? = nil
    /// Per-message sender resolution for *group* convs — many possible
    /// senders, name shown above the bubble. Takes precedence over
    /// peerProfile / selfAvatar / botID when set. `kind == "bot"`
    /// renders BotAvatar; `"user"` renders UserAvatar. The display
    /// name sits above the bubble so multi-sender threads stay
    /// readable.
    var groupSender: GroupBubbleSender? = nil
    let serverURL: URL?
    /// Web-search citations referenced by inline `[N]` markers in
    /// `message.content`. Empty for bubbles that didn't trigger search.
    var citations: [MessageCitation] = []
    /// Whether this bubble is the live streaming target — drives the
    /// trailing cursor. Caller clears it the moment the reveal finishes
    /// so the cursor's `.opacity` transition fades it out.
    var isStreaming: Bool = false
    /// True while we're streaming but the reveal buffer is empty (no new
    /// token yet). Switches the cursor from solid to TTY-style blink.
    var streamPaused: Bool = false

    private var hasText: Bool { !message.content.isEmpty }

    /// User bubble background — switches on the optimistic-send state:
    ///   • failed   → red wash
    ///   • sending  → lighter green (request in flight, no HTTP ack yet)
    ///   • sent / nil → standard green (server returned 200 or canonical row)
    private var userBubbleFill: Color {
        if message.isFailed { return Color.red.opacity(0.12) }
        if message.isSending { return Theme.Palette.userBubbleSending }
        return Theme.Palette.userBubble
    }

    var body: some View {
        if message.isMine(currentUserId: currentUserId) {
            userLayout
        } else {
            botLayout
        }
    }

    // ── Bot ─────────────────────────────────────────────────────────────────

    private var botLayout: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let g = groupSender {
                    // Group conv — sender resolved per-message.
                    switch g.kind {
                    case .bot:
                        BotAvatar(emojiSeed: g.id, colorSeed: g.id, size: 30)
                    case .user:
                        UserAvatar(seed: g.avatarSeed, attachmentId: g.avatarPath, size: 30)
                    }
                } else if let peer = peerProfile, message.sender_type == "user" {
                    // user_user / group peer — use UserAvatar so it matches
                    // the same person's avatar in the friends list.
                    UserAvatar(seed: peer.avatarSeed, attachmentId: peer.avatarPath, size: 30)
                } else if let s = selfAvatar {
                    UserAvatar(seed: s.seed, attachmentId: s.attachmentId, size: 30)
                } else {
                    BotAvatar(
                        emojiSeed: (botID?.isEmpty == false ? botID! : conversationID),
                        colorSeed: conversationID,
                        size: 30
                    )
                }
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                if let g = groupSender {
                    Text(g.displayName)
                        .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }

                if let attachments = message.attachments, !attachments.isEmpty,
                   let serverURL {
                    AttachmentGrid(attachments: attachments, serverURL: serverURL)
                }

                if hasText || isStreaming {
                    MarkdownText(text: message.content,
                                 allowCodeRun: true,
                                 citations: citations)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius,
                                             style: .continuous)
                                .fill(Theme.Palette.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius,
                                             style: .continuous)
                                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                        )
                        // Trailing caret — sits at the bottom-trailing of
                        // the rendered text. Inline-with-last-char would
                        // be nicer but isn't reachable through MarkdownUI;
                        // the bubble's trailing edge still reads as
                        // "more on the way".
                        .overlay(alignment: .bottomTrailing) {
                            if isStreaming {
                                BlinkingCursor(paused: streamPaused)
                                    .padding(.trailing, 12)
                                    .padding(.bottom, 12)
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeOut(duration: 0.28), value: isStreaming)
                }
            }
            Spacer(minLength: 32)
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 4)
    }

    // ── User ────────────────────────────────────────────────────────────────

    private var userLayout: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 48)

            VStack(alignment: .trailing, spacing: 6) {
                if let attachments = message.attachments, !attachments.isEmpty,
                   let serverURL {
                    AttachmentGrid(attachments: attachments, serverURL: serverURL)
                }

                if hasText {
                    HStack(alignment: .center, spacing: 6) {
                        if message.isFailed {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Color.red.opacity(0.85))
                        }
                        Text(message.content)
                            .textSelection(.enabled)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(message.isFailed
                                             ? Color.red.opacity(0.95)
                                             : Theme.Palette.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius,
                                                 style: .continuous)
                                    .fill(userBubbleFill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius,
                                                 style: .continuous)
                                    .strokeBorder(
                                        message.isFailed ? Color.red.opacity(0.55) : .clear,
                                        lineWidth: 1
                                    )
                            )
                            .animation(.easeInOut(duration: 0.22), value: message.status)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 4)
    }
}

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
}

struct AttachmentGrid: View {
    let attachments: [Attachment]
    let serverURL: URL

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6),
                            count: min(attachments.count, 3))
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(attachments) { att in
                ServerImage(path: att.url, serverURL: serverURL)
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}
