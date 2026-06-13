#if os(macOS)
import SwiftUI

/// 顶部 roster 头像条：一排成员头像（session 带状态点），保留 crew 特有的
/// "一眼看 captain/session 运行状态" 价值，视觉对齐 iOS。
///
/// 头像改用 `CrewAvatarBadges(sender:size:)` — 与气泡行里的头像来自同一组件，
/// 保证星标角标 / 状态点 / terminal 头像在 roster 和对话里完全一致。
struct CrewRosterBar: View {
    let members: [CrewMember]
    let captainBotId: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(members) { m in
                    let sender = groupSenderFor(m)
                    VStack(spacing: 3) {
                        CrewAvatarBadges(sender: sender, size: 28)
                        Text(sender.displayName)
                            .font(Theme.Fonts.caption2)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .lineLimit(1)
                            .frame(maxWidth: 76)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Theme.Palette.surfaceMuted.opacity(0.5))
    }

    /// Build a `GroupBubbleSender` from a `CrewMember` for `CrewAvatarBadges`.
    /// Maps the same fields that `CrewSenderResolver` uses when resolving a
    /// whiteboard entry, so roster and bubble avatars stay visually identical.
    private func groupSenderFor(_ m: CrewMember) -> GroupBubbleSender {
        let isCaptain = m.memberKind == "captain" || (m.botId != nil && m.botId == captainBotId)
        let isSession = m.memberKind == "code_session"
        let isHuman   = m.memberKind == "human"
        let seed = m.botId ?? m.userId ?? m.codeSessionId ?? m.id
        let name: String = {
            if let n = m.displayName, !n.isEmpty { return n }
            if isCaptain  { return "机长" }
            if isHuman    { return "我" }
            if isSession  { return "session" }
            return "bot"
        }()
        return GroupBubbleSender(
            kind: isHuman ? .user : .bot,
            id: seed,
            displayName: name,
            avatarPath: nil,
            avatarSeed: seed,
            isCaptain: isCaptain,
            sessionStatus: m.sessionStatus,
            isSession: isSession
        )
    }
}
#endif
