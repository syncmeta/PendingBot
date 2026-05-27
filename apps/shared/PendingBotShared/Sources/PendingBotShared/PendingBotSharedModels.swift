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

    public var title: String {
        switch self {
        case .local: "本地"
        case .reservedCloud: "云端预留"
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
