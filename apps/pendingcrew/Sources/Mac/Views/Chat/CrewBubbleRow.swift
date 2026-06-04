#if os(macOS)
import SwiftUI

/// 单条白板消息行，对齐 PendingBot iOS BubbleView 语法。
/// 我 → 右对齐绿气泡无头像；别人 → 左对齐头像+名字抬头+surface 气泡。
struct CrewBubbleRow: View {
    let entry: CrewWhiteboardEntry
    let sender: CrewSender

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if sender.isMine {
                Spacer(minLength: 48)
                bubble(mine: true)
            } else {
                CrewAvatar(sender: sender)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sender.displayName)
                        .font(CrewTheme.Fonts.rounded(11, weight: .semibold))
                        .foregroundStyle(CrewTheme.Palette.inkMuted)
                    bubble(mine: false)
                }
                Spacer(minLength: 32)
            }
        }
        .padding(.horizontal, CrewTheme.Metrics.gutter)
        .padding(.vertical, 4)
    }

    private func bubble(mine: Bool) -> some View {
        Text(entry.displayText)
            .font(CrewTheme.Fonts.body)
            .foregroundStyle(CrewTheme.Palette.ink)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CrewTheme.Metrics.bubbleRadius, style: .continuous)
                    .fill(mine ? CrewTheme.Palette.userBubble : CrewTheme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CrewTheme.Metrics.bubbleRadius, style: .continuous)
                    .strokeBorder(CrewTheme.Palette.hairline, lineWidth: 0.5)
            )
            .frame(maxWidth: 520, alignment: mine ? .trailing : .leading)
    }
}
#endif
