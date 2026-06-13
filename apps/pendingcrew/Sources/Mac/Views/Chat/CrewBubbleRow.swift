#if os(macOS)
import SwiftUI

/// 单条白板消息行，对齐 PendingBot iOS BubbleView 语法。
/// 我 → 右对齐绿气泡无头像；别人 → 左对齐头像+名字抬头+surface 气泡。
struct CrewBubbleRow: View {
    let entry: CrewWhiteboardEntry
    let sender: CrewSender

    private var attachments: [CrewAttachment] { entry.attachments ?? [] }
    /// Image-only messages (e.g. a sent screenshot) carry no prose — skip the
    /// empty text bubble so we don't render a blank green pill above the grid.
    private var hasText: Bool { !entry.displayText.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if sender.isMine {
                Spacer(minLength: 48)
                content(mine: true)
            } else {
                CrewAvatar(sender: sender)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sender.displayName)
                        .font(Theme.Fonts.rounded(11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                    content(mine: false)
                }
                Spacer(minLength: 32)
            }
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 4)
    }

    /// Text bubble (when present) stacked above the attachment grid, both
    /// aligned to the bubble's side.
    @ViewBuilder
    private func content(mine: Bool) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            if hasText {
                bubble(mine: mine)
            }
            if !attachments.isEmpty {
                CrewAttachmentView(attachments: attachments,
                                   alignment: mine ? .trailing : .leading)
            }
        }
    }

    private func bubble(mine: Bool) -> some View {
        Text(entry.displayText)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Palette.ink)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius, style: .continuous)
                    .fill(mine ? Theme.Palette.userBubble : Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
            )
            .frame(maxWidth: 520, alignment: mine ? .trailing : .leading)
    }
}
#endif
