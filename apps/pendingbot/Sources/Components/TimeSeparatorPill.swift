import SwiftUI

/// Centered timestamp pill inserted between messages whose time-gap to
/// the previous bubble crossed RelativeMessageTime.separatorGapSeconds.
/// Visually quiet — secondary color, small caption font — so it doesn't
/// compete with the bubbles.
struct TimeSeparatorPill: View {
    let date: Date

    var body: some View {
        Text(RelativeMessageTime.format(date, style: .pill))
            .font(Theme.Fonts.caption2)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
            .accessibilityLabel("时间:\(RelativeMessageTime.format(date, style: .pill))")
    }
}
