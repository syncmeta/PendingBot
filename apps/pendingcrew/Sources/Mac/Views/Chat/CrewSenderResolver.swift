#if os(macOS)
import Foundation

/// 一条消息的作者解析结果，供 CrewBubbleRow / CrewAvatar 渲染。
struct CrewSender: Equatable {
    enum Kind: Equatable { case bot, session, human }
    let kind: Kind
    let displayName: String
    let avatarSeed: String          // 喂给 CrewColorHash 的稳定 id
    let isCaptain: Bool
    let sessionStatus: String?      // 仅 session：running/queued/…
    let isMine: Bool                // 我自己 → 右对齐、无头像
}

enum CrewSenderResolver {
    /// `entry` 的作者。`localUserId` = 当前登录用户（用于判断"我"）。
    static func resolve(
        _ entry: CrewWhiteboardEntry,
        members: [CrewMember],
        captainBotId: String?,
        localUserId: String?
    ) -> CrewSender {
        switch entry.senderKind {
        case "user", "human":
            let uid = entry.senderUserId
            let mine = uid != nil ? (uid == localUserId) : true   // 缺 id 时 BYOK 单人 → 当我
            let m = members.first { $0.userId != nil && $0.userId == uid }
            return CrewSender(
                kind: .human,
                displayName: m?.displayName ?? "我",
                avatarSeed: uid ?? "me",
                isCaptain: false, sessionStatus: nil, isMine: mine
            )

        case "session":
            let m = members.first { $0.codeSessionId != nil && $0.codeSessionId == entry.senderSessionId }
            let short = entry.senderSessionId.map { "session · \($0.prefix(8))" } ?? "session"
            return CrewSender(
                kind: .session,
                displayName: m?.displayName ?? short,
                avatarSeed: entry.senderSessionId ?? entry.id,
                isCaptain: false, sessionStatus: m?.sessionStatus, isMine: false
            )

        case "bot":
            let bid = entry.senderBotId
            let m = members.first { $0.botId != nil && $0.botId == bid }
                ?? members.first { $0.memberKind == "captain" }   // null 兜底 captain
            let isCaptain = (bid != nil && bid == captainBotId) || m?.memberKind == "captain"
            return CrewSender(
                kind: .bot,
                displayName: m?.displayName ?? (isCaptain ? "机长" : "bot"),
                avatarSeed: bid ?? captainBotId ?? "bot",
                isCaptain: isCaptain, sessionStatus: nil, isMine: false
            )

        default:
            return CrewSender(kind: .bot, displayName: entry.senderKind,
                              avatarSeed: entry.id, isCaptain: false, sessionStatus: nil, isMine: false)
        }
    }
}
#endif
