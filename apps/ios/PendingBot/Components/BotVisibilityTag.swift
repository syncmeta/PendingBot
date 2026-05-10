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

/// Tag pill for group conversations. The fill is a tri-tone wash of the
/// three entity-type tag bgs (人类 / 私有机器人 / 公有机器人), kept
/// intentionally pale so the pill reads as "all categories" without
/// shouting over the per-type pills around it.
struct GroupChatTag: View {
    var body: some View {
        Text("群聊")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Palette.inkMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [
                            Theme.Palette.accentBg.opacity(0.55),
                            Theme.Palette.amberBg.opacity(0.55),
                            Theme.Palette.plumBg.opacity(0.55),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            )
    }
}
