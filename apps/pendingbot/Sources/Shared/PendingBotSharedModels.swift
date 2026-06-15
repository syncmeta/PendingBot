import Foundation

public enum PendingBotBigScreenTab: String, CaseIterable, Identifiable, Hashable {
    case message
    case friends
    case crew
    case envelope
    case me

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .message: "消息"
        case .friends: "好友"
        case .crew: "机组"
        case .envelope: "来信"
        case .me: "我"
        }
    }

    /// SF Symbol fallback for non-custom-symbol callers. SwiftUI surfaces map
    /// `.crew` to the PendingCrew custom symbol instead.
    public var systemImage: String {
        switch self {
        case .message: "bubble.left.and.bubble.right"
        case .friends: "person.2"
        case .crew: "person.3.sequence"
        case .envelope: "envelope.open"
        case .me: "person.crop.circle"
        }
    }
}

public enum PendingBotCrewRuntimeKind: String, Hashable, Codable {
    case local
    case reservedCloud

    public init(apiValue: String) {
        switch apiValue {
        case "cloud", "reserved_cloud", "reservedCloud":
            self = .reservedCloud
        default:
            self = .local
        }
    }

    public var title: String {
        switch self {
        case .local: "本地"
        case .reservedCloud: "云端预留"
        }
    }
}

public enum PendingBotCrewRunnerKind: String, CaseIterable, Identifiable, Hashable, Codable {
    case cloudSandbox = "cloud_sandbox"
    case localClaudeCode = "local_claude_code"
    case localCodex = "local_codex"
    case localOpencode = "local_opencode"
    case localKilo = "local_kilo"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cloudSandbox: "云端 Sandbox"
        case .localClaudeCode: "Mac Claude Code"
        case .localCodex: "Mac Codex"
        case .localOpencode: "Mac opencode"
        case .localKilo: "Mac Kilo"
        }
    }
}

public struct PendingBotCrewSummary: Identifiable, Hashable, Codable {
    public let id: String
    public let title: String
    public let status: String
    public let runtimeKind: PendingBotCrewRuntimeKind
    public let updatedAt: String

    public init(
        id: String,
        title: String,
        status: String,
        runtimeKind: PendingBotCrewRuntimeKind,
        updatedAt: String
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.runtimeKind = runtimeKind
        self.updatedAt = updatedAt
    }
}

public struct PendingBotCrewSidebarRow: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let systemImage: String

    public static func rows(for crews: [PendingBotCrewSummary]) -> [PendingBotCrewSidebarRow] {
        crews
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .map { crew in
                PendingBotCrewSidebarRow(
                    id: crew.id,
                    title: crew.title,
                    subtitle: "\(crew.runtimeKind.title) · \(crew.status)",
                    systemImage: crew.runtimeKind == .local ? "desktopcomputer" : "cloud"
                )
            }
    }
}

public struct PendingBotCrewLink: Identifiable, Hashable, Codable {
    public var id: String { crewId }
    public let crewId: String
    public let title: String
    public let status: String
    public let runtimeKind: PendingBotCrewRuntimeKind
    public let captainBotId: String?
    public let captainMemberId: String?
    public let createdAt: String

    public init(
        crewId: String,
        title: String,
        status: String,
        runtimeKind: PendingBotCrewRuntimeKind,
        captainBotId: String?,
        captainMemberId: String?,
        createdAt: String
    ) {
        self.crewId = crewId
        self.title = title
        self.status = status
        self.runtimeKind = runtimeKind
        self.captainBotId = captainBotId
        self.captainMemberId = captainMemberId
        self.createdAt = createdAt
    }

    public var hasCaptainRepresentative: Bool {
        captainBotId != nil || captainMemberId != nil
    }
}

public struct PendingBotCrewResponsibilityShare: Identifiable, Hashable, Codable {
    public var id: String { subjectId }
    public let subjectId: String
    public let shareBps: Int
    public let source: String

    public init(subjectId: String, shareBps: Int, source: String) {
        self.subjectId = subjectId
        self.shareBps = shareBps
        self.source = source
    }

    public var percentText: String {
        let whole = shareBps / 100
        let remainder = abs(shareBps % 100)
        if remainder == 0 {
            return "\(whole)%"
        }
        if remainder % 10 == 0 {
            return "\(whole).\(remainder / 10)%"
        }
        return "\(whole).\(String(format: "%02d", remainder))%"
    }
}

public struct PendingBotCrewSession: Identifiable, Hashable, Codable {
    public let id: String
    public let crewId: String
    public let responsibleSubjectId: String
    public let runnerKind: PendingBotCrewRunnerKind
    public let status: String
    public let taskBrief: String
    public let progressSummary: String?
    public let createdAt: String
    public let startedAt: String?
    public let finishedAt: String?

    public init(
        id: String,
        crewId: String,
        responsibleSubjectId: String,
        runnerKind: PendingBotCrewRunnerKind,
        status: String,
        taskBrief: String,
        progressSummary: String?,
        createdAt: String,
        startedAt: String?,
        finishedAt: String?
    ) {
        self.id = id
        self.crewId = crewId
        self.responsibleSubjectId = responsibleSubjectId
        self.runnerKind = runnerKind
        self.status = status
        self.taskBrief = taskBrief
        self.progressSummary = progressSummary
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var pendingCrewDeepLink: URL? {
        URL(string: "pendingcrew://crew/\(crewId)/session/\(id)")
    }
}

public struct PendingBotCrewMember: Identifiable, Hashable, Codable {
    public let id: String
    public let crewId: String
    public let memberKind: String
    public let displayName: String
    public let role: String
    public let status: String
    public let createdAt: String

    public init(
        id: String,
        crewId: String,
        memberKind: String,
        displayName: String,
        role: String,
        status: String,
        createdAt: String
    ) {
        self.id = id
        self.crewId = crewId
        self.memberKind = memberKind
        self.displayName = displayName
        self.role = role
        self.status = status
        self.createdAt = createdAt
    }
}

public struct PendingBotCrewAnnouncementMention: Identifiable, Hashable, Codable {
    public let id: String
    public let announcementId: String
    public let targetKind: String
    public let targetSessionId: String?
    public let targetMemberId: String?
    public let createdAt: String

    public init(
        id: String,
        announcementId: String,
        targetKind: String,
        targetSessionId: String?,
        targetMemberId: String?,
        createdAt: String
    ) {
        self.id = id
        self.announcementId = announcementId
        self.targetKind = targetKind
        self.targetSessionId = targetSessionId
        self.targetMemberId = targetMemberId
        self.createdAt = createdAt
    }
}

public struct PendingBotCrewAnnouncement: Identifiable, Hashable, Codable {
    public let id: String
    public let crewId: String
    public let responsibleSubjectId: String
    public let senderKind: String
    public let senderMemberId: String?
    public let senderSessionId: String?
    public let recipientMode: String
    public let messageKind: String
    public let boardVisible: Bool
    public let summary: String
    public let createdAt: String
    public let mentions: [PendingBotCrewAnnouncementMention]

    public init(
        id: String,
        crewId: String,
        responsibleSubjectId: String,
        senderKind: String,
        senderMemberId: String?,
        senderSessionId: String?,
        recipientMode: String,
        messageKind: String,
        boardVisible: Bool,
        summary: String,
        createdAt: String,
        mentions: [PendingBotCrewAnnouncementMention]
    ) {
        self.id = id
        self.crewId = crewId
        self.responsibleSubjectId = responsibleSubjectId
        self.senderKind = senderKind
        self.senderMemberId = senderMemberId
        self.senderSessionId = senderSessionId
        self.recipientMode = recipientMode
        self.messageKind = messageKind
        self.boardVisible = boardVisible
        self.summary = summary
        self.createdAt = createdAt
        self.mentions = mentions
    }
}

public struct PendingBotCrewDetail: Hashable, Codable {
    public let crewId: String
    public let parents: [PendingBotCrewLink]
    public let children: [PendingBotCrewLink]
    public let responsibilityShares: [PendingBotCrewResponsibilityShare]
    public let sessions: [PendingBotCrewSession]
    public let members: [PendingBotCrewMember]
    public let announcements: [PendingBotCrewAnnouncement]

    public init(
        crewId: String,
        parents: [PendingBotCrewLink],
        children: [PendingBotCrewLink],
        responsibilityShares: [PendingBotCrewResponsibilityShare],
        sessions: [PendingBotCrewSession],
        members: [PendingBotCrewMember],
        announcements: [PendingBotCrewAnnouncement]
    ) {
        self.crewId = crewId
        self.parents = parents
        self.children = children
        self.responsibilityShares = responsibilityShares
        self.sessions = sessions
        self.members = members
        self.announcements = announcements
    }

    public var displaySessions: [PendingBotCrewSession] {
        sessions.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.taskBrief.localizedCaseInsensitiveCompare(rhs.taskBrief) == .orderedAscending
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    public var displayAnnouncements: [PendingBotCrewAnnouncement] {
        announcements.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.summary.localizedCaseInsensitiveCompare(rhs.summary) == .orderedAscending
            }
            return lhs.createdAt < rhs.createdAt
        }
    }
}

public struct PendingBotCrewRelationshipRow: Identifiable, Hashable {
    public let id: String
    public let crewId: String
    public let title: String
    public let subtitle: String
    public let systemImage: String

    public static func rows(for detail: PendingBotCrewDetail) -> [PendingBotCrewRelationshipRow] {
        let parents = detail.parents
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { link in row(for: link, directionTitle: "上级", directionId: "parent", systemImage: "arrow.up.left.and.arrow.down.right") }
        let children = detail.children
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { link in row(for: link, directionTitle: "下级", directionId: "child", systemImage: "arrow.down.right.and.arrow.up.left") }
        return parents + children
    }

    private static func row(
        for link: PendingBotCrewLink,
        directionTitle: String,
        directionId: String,
        systemImage: String
    ) -> PendingBotCrewRelationshipRow {
        var subtitleParts = [directionTitle]
        if link.hasCaptainRepresentative {
            subtitleParts.append("机长")
        }
        subtitleParts.append(contentsOf: [link.runtimeKind.title, link.status])

        return PendingBotCrewRelationshipRow(
            id: "\(directionId):\(link.crewId)",
            crewId: link.crewId,
            title: link.title,
            subtitle: subtitleParts.joined(separator: " · "),
            systemImage: systemImage
        )
    }
}
