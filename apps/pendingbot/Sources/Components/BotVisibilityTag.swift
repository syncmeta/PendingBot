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
            .font(Theme.Fonts.system(size: 10, weight: .semibold))
            .foregroundStyle(fg)
            .lineLimit(1)
            .fixedSize()   // 窄列(Mac 侧栏)下也不换行成两行
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
    }
}

/// Tag pill for group conversations. The fill is a tri-tone wash of the
/// three entity-type tag bgs (人类 / 私有机器人 / 公有机器人), kept
/// intentionally pale so the pill reads as "all categories" without
/// shouting over the per-type pills around it.
///
/// On every appearance (tab switch, pop-back from chat, pull-to-refresh,
/// scroll-into-view) the gradient slides in over 3s with `easeOut` —
/// instant motion at start, decelerating to a static rest position. Lives
/// inside a `LazyVStack` so only visible rows ever animate; off-screen
/// cells aren't even instantiated until they scroll in.
struct GroupChatTag: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        Text("群聊")
            .font(Theme.Fonts.system(size: 10, weight: .semibold))
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
                        // phase=0 → gradient sits entirely off the left
                        // edge, so the pill reads as a uniform plumBg
                        // (clamp colour past endPoint). phase=1 → gradient
                        // fits the pill exactly: the static rest state.
                        startPoint: UnitPoint(x: phase - 1, y: 0.5),
                        endPoint: UnitPoint(x: phase, y: 0.5)
                    )
                )
            )
            .onAppear {
                // Snap to the start state, then on the next runloop tick
                // animate to rest. The async hop is what gives SwiftUI a
                // frame to commit phase=0 before the withAnimation hint
                // reads it — without it the two state writes get coalesced
                // into a single transition from the previous value to 1.
                phase = 0
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    withAnimation(.easeOut(duration: 3.0)) {
                        phase = 1
                    }
                }
            }
    }
}
