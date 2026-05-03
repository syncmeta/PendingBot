import SwiftUI

/// Tag pill that labels a bot as 私有机器人 (plum) or 公有机器人 (yellow).
/// Replaces the old "AI" generic tag now that bots split into creator-only
/// and IM-account flavors. Pass the raw `bots.visibility` string from the
/// DB; nil falls back to the public-open style (the schema default).
struct BotVisibilityTag: View {
    let visibility: String?

    var body: some View {
        let isPrivate = visibility == "private"
        let text = isPrivate ? "私有机器人" : "公有机器人"
        let fg: Color = isPrivate ? Theme.Palette.plum : Theme.Palette.amber
        let bg: Color = isPrivate ? Theme.Palette.plumBg : Theme.Palette.amberBg
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
    }
}
