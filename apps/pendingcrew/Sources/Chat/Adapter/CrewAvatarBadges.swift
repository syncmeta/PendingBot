import SwiftUI

/// `BotAvatar`(PendingBot 同款 emoji+柔色头像)+ crew 角标(captain 星标 /
/// session 运行状态点),driven by `GroupBubbleSender`。
///
/// Replaces the old `CrewAvatar` at the bubble avatar slot (A8 wires it in;
/// A11 deletes `CrewAvatar`). Cross-platform — no `#if os(macOS)` gate.
///
/// 头像本体:bot / captain / code session 一律走 `BotAvatar(emojiSeed:colorSeed:)`
/// —— 和 PendingBot 里 bot 头像同一套生成法,同一 id 永远同一张脸。session 不再用
/// 专门的 terminal 图标,改由运行状态点(bot 没有)区分。
///
/// Badge geometry:
/// - Captain star:  `star.fill`, orange, size×0.30 bold, canvas-backed circle,
///   offset (+size×0.34, -size×0.34) → top-trailing quadrant.
/// - Status dot:    plain circle size×0.26, canvas stroke 1.5 pt,
///   offset (+size×0.34, +size×0.34) → bottom-trailing quadrant.
///   有未读=红;否则 working|running=绿 / idle|queued=黄 / 其余=灰;nil 时隐藏。
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
        // 所有成员 —— bot / captain / code session —— 一律走 PendingBot 同款
        // BotAvatar:emoji 种子 = participant id(稳定身份)、色种子 = avatarSeed
        // (按群着色)。session 不再用专门的 terminal 图标,改由下面的运行状态点
        // (bot 没有)区分。
        BotAvatar(emojiSeed: sender.id, colorSeed: sender.avatarSeed, size: size)
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
        case "working", "running": return .green   // 干活中
        case "idle", "queued":     return .yellow  // 空闲/排队中
        default:                   return .gray     // 已退出/停止
        }
    }
}
