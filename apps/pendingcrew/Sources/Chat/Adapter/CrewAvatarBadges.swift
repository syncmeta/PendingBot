import SwiftUI

/// Vendored `BotAvatar` + crew badges (captain star / session status dot /
/// terminal-icon avatar), driven by `GroupBubbleSender`.
///
/// Replaces the old `CrewAvatar` at the bubble avatar slot (A8 wires it in;
/// A11 deletes `CrewAvatar`). Cross-platform — no `#if os(macOS)` gate.
///
/// Badge geometry mirrors `CrewAvatar` (macOS-only, `Sources/Mac/Views/Chat/`):
/// - Captain star:  `star.fill`, orange, size×0.30 bold, canvas-backed circle,
///   offset (+size×0.34, -size×0.34) → top-trailing quadrant.
/// - Status dot:    plain circle size×0.26, canvas stroke 1.5 pt,
///   offset (+size×0.34, +size×0.34) → bottom-trailing quadrant.
///   green="running", yellow="queued", gray=anything else; hidden when nil.
/// - Session base:  green-tinted circle + `terminal.fill` icon, same hue/sat/
///   brightness as `CrewAvatar`'s `.session` case.
struct CrewAvatarBadges: View {
    let sender: GroupBubbleSender
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            base
            if sender.isCaptain { captainStar }
            statusDot
        }
        .frame(width: size, height: size)
    }

    // MARK: - Base avatar

    @ViewBuilder private var base: some View {
        if sender.isSession {
            // Terminal-icon avatar — mirrors CrewAvatar's `.session` case exactly:
            // hue 0.38 (green), sat 0.22, brightness 0.93 background;
            // icon foreground: hue 0.38, sat 0.60, brightness 0.50.
            Circle()
                .fill(Color(hue: 0.38, saturation: 0.22, brightness: 0.93))
                .overlay(
                    Image(systemName: "terminal.fill")
                        .font(Theme.Fonts.glyph(size: size * 0.45))
                        .foregroundStyle(Color(hue: 0.38, saturation: 0.60, brightness: 0.50))
                )
                .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
        } else {
            // Bot avatar: emoji seed = participant id (stable identity across
            // conversations), color seed = avatarSeed (per-group tint).
            BotAvatar(emojiSeed: sender.id, colorSeed: sender.avatarSeed, size: size)
        }
    }

    // MARK: - Captain star badge (top-trailing)

    private var captainStar: some View {
        Image(systemName: "star.fill")
            .font(.system(size: size * 0.30, weight: .bold))
            .foregroundStyle(.orange)
            .padding(1.5)
            .background(Circle().fill(Theme.Palette.canvas))
            .offset(x: size * 0.34, y: -(size * 0.34))
    }

    // MARK: - Session status dot (bottom-trailing)
    //
    // 三态(用户定调):有未读 → 红点(最显眼、可操作,盖过状态);否则按 run 状态 ——
    // running=绿(在跑着)、其余=灰(空闲/已退出)。红点比状态点略大一圈以示突出。

    @ViewBuilder private var statusDot: some View {
        if sender.hasNotification {
            Circle()
                .fill(Color.red)
                .frame(width: size * 0.30, height: size * 0.30)
                .overlay(Circle().strokeBorder(Theme.Palette.canvas, lineWidth: 1.5))
                .offset(x: size * 0.34, y: size * 0.34)
        } else if let status = sender.sessionStatus {
            Circle()
                .fill(statusColor(status))
                .frame(width: size * 0.26, height: size * 0.26)
                .overlay(Circle().strokeBorder(Theme.Palette.canvas, lineWidth: 1.5))
                .offset(x: size * 0.34, y: size * 0.34)
        }
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "running": return .green
        case "queued":  return .yellow
        default:        return .gray
        }
    }
}
