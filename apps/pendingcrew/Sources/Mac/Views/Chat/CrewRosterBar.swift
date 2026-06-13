#if os(macOS)
import SwiftUI

/// 顶部 roster 头像条：一排成员头像（session 带状态点），保留 crew 特有的
/// "一眼看 captain/session 运行状态" 价值，视觉对齐 iOS。
struct CrewRosterBar: View {
    let members: [CrewMember]
    let captainBotId: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(members) { m in
                    let sender = senderFor(m)
                    VStack(spacing: 3) {
                        CrewAvatar(sender: sender, size: 28)
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

    private func senderFor(_ m: CrewMember) -> CrewSender {
        let isCaptain = m.memberKind == "captain" || (m.botId != nil && m.botId == captainBotId)
        let kind: CrewSender.Kind = {
            switch m.memberKind {
            case "code_session": return .session
            case "human":        return .human
            default:             return .bot   // bot / captain
            }
        }()
        let seed = m.botId ?? m.userId ?? m.codeSessionId ?? m.id
        let name = m.displayName?.isEmpty == false ? m.displayName!
            : (isCaptain ? "机长" : kind == .human ? "我" : kind == .session ? "session" : "bot")
        return CrewSender(kind: kind, displayName: name, avatarSeed: seed,
                          isCaptain: isCaptain, sessionStatus: m.sessionStatus, isMine: false)
    }
}
#endif
