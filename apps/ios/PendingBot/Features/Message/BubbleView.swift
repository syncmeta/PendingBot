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
    let serverURL: URL?
    /// Web-search citations referenced by inline `[N]` markers in
    /// `message.content`. Empty for bubbles that didn't trigger search.
    var citations: [MessageCitation] = []

    private var hasText: Bool { !message.content.isEmpty }

    var body: some View {
        if message.isUser {
            userLayout
        } else {
            botLayout
        }
    }

    // ── Bot ─────────────────────────────────────────────────────────────────

    private var botLayout: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let s = selfAvatar {
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

            VStack(alignment: .leading, spacing: 6) {
                if let attachments = message.attachments, !attachments.isEmpty,
                   let serverURL {
                    AttachmentGrid(attachments: attachments, serverURL: serverURL)
                }

                if hasText {
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
                                    .fill(message.isFailed
                                          ? Color.red.opacity(0.12)
                                          : Theme.Palette.userBubble)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius,
                                                 style: .continuous)
                                    .strokeBorder(
                                        message.isFailed ? Color.red.opacity(0.55) : .clear,
                                        lineWidth: 1
                                    )
                            )
                            .opacity(message.isSending ? 0.55 : 1)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 4)
    }
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
