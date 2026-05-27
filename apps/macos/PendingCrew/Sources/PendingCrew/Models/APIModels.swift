import Foundation

struct SubjectResponse: Decodable {
    let subject: Subject
    let wallet: SubjectWallet
}

struct Subject: Decodable, Identifiable {
    let id: String
    let subjectType: String
    let displayName: String
    let status: String
    let createdAt: String
    let updatedAt: String
}

struct SubjectWallet: Decodable {
    let balanceCredits: Int
    let lifetimeTopupCredits: Int
    let lifetimeSpentCredits: Int
}

struct ListResponse<Item: Decodable>: Decodable {
    let items: [Item]
}

struct CreateCrewResponse: Decodable {
    let conversationId: String
}

struct CreateSessionResponse: Decodable {
    let sessionId: String
}

struct CreateAnnouncementResponse: Decodable {
    let announcementId: String
}

struct RegisterRunnerHostResponse: Decodable {
    let runnerHostId: String
}

struct OkResponse: Decodable {
    let ok: Bool
}

struct DeviceLoginChallenge: Decodable {
    let challengeId: String
    let secret: String
    let code: String
    let qrPayload: String
    let expiresAt: String
    let status: String
}

struct DeviceLoginPollResponse: Decodable {
    let status: String
    let deviceGrantToken: String?
    let grantId: String?
    let subjectId: String?
    let grantKind: String?
    let scopes: [String]?
}

struct RunnerClaimResponse: Decodable {
    let leaseId: String?
    let session: CrewSession?
}

struct Crew: Decodable, Identifiable {
    var id: String { conversationId }
    let conversationId: String
    let responsibleSubjectId: String
    let status: String
    let title: String
    let createdAt: String
    let updatedAt: String
}

struct CrewSession: Decodable, Identifiable {
    let id: String
    let crewConversationId: String
    let responsibleSubjectId: String
    let runnerKind: String
    let status: String
    let taskBrief: String
    let progressSummary: String?
    let createdAt: String
    let startedAt: String?
    let finishedAt: String?
}

struct CrewLink: Decodable, Identifiable {
    var id: String { crewConversationId }
    let crewConversationId: String
    let title: String
    let status: String
    let runtimeKind: String
    let captainBotId: String?
    let captainMemberId: String?
    let createdAt: String

    var hasCaptainRepresentative: Bool {
        captainBotId != nil || captainMemberId != nil
    }
}

struct CrewResponsibilityShare: Decodable, Identifiable {
    var id: String { subjectId }
    let subjectId: String
    let shareBps: Int
    let source: String
}

struct CrewLinksResponse: Decodable {
    let parents: [CrewLink]
    let children: [CrewLink]
    let responsibilityShares: [CrewResponsibilityShare]
}

struct CrewSidebarRow: Identifiable, Hashable {
    var id: String { "\(parentCrewId ?? "root"):\(crewId)" }
    let crewId: String
    let parentCrewId: String?
    let title: String
    let status: String
    let runtimeKind: String
    let depth: Int
    let captainBotId: String?
    let captainMemberId: String?

    var hasCaptainRepresentative: Bool {
        captainBotId != nil || captainMemberId != nil
    }
}

enum CrewSidebarIndex {
    static func flatten(
        crews: [Crew],
        linksByCrew: [String: CrewLinksResponse]
    ) -> [CrewSidebarRow] {
        let crewById = Dictionary(uniqueKeysWithValues: crews.map { ($0.id, $0) })
        let childIds = Set(linksByCrew.values.flatMap { $0.children.map(\.crewConversationId) })
        let roots = crews
            .filter { !childIds.contains($0.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        var rows: [CrewSidebarRow] = []
        for root in roots {
            append(
                crewId: root.id,
                parentCrewId: nil,
                link: nil,
                crewById: crewById,
                linksByCrew: linksByCrew,
                depth: 0,
                visitedPath: [],
                rows: &rows
            )
        }
        return rows
    }

    private static func append(
        crewId: String,
        parentCrewId: String?,
        link: CrewLink?,
        crewById: [String: Crew],
        linksByCrew: [String: CrewLinksResponse],
        depth: Int,
        visitedPath: Set<String>,
        rows: inout [CrewSidebarRow]
    ) {
        guard !visitedPath.contains(crewId) else { return }
        let crew = crewById[crewId]
        rows.append(
            CrewSidebarRow(
                crewId: crewId,
                parentCrewId: parentCrewId,
                title: link?.title ?? crew?.title ?? "机组",
                status: link?.status ?? crew?.status ?? "active",
                runtimeKind: link?.runtimeKind ?? "local",
                depth: depth,
                captainBotId: link?.captainBotId,
                captainMemberId: link?.captainMemberId
            )
        )

        let nextVisited = visitedPath.union([crewId])
        let children = (linksByCrew[crewId]?.children ?? [])
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        for child in children {
            append(
                crewId: child.crewConversationId,
                parentCrewId: crewId,
                link: child,
                crewById: crewById,
                linksByCrew: linksByCrew,
                depth: depth + 1,
                visitedPath: nextVisited,
                rows: &rows
            )
        }
    }
}

struct CrewMember: Decodable, Identifiable {
    let id: String
    let conversationId: String
    let memberKind: String
    let userId: String?
    let botId: String?
    let codeSessionId: String?
    let displayName: String
    let role: String
    let capabilities: JSONValue
    let status: String
    let createdAt: String

    var isCaptainRepresentative: Bool {
        memberKind == "captain" || memberKind == "master_bot" || role == "captain"
    }

    var crewDisplayName: String {
        isCaptainRepresentative ? "机长 · \(displayName)" : displayName
    }
}

struct SessionEvent: Decodable, Identifiable {
    let id: String
    let crewSessionId: String
    let eventType: String
    let visibility: String
    let summary: String?
    let payload: JSONValue
    let createdAt: String
}

struct CrewAnnouncement: Decodable, Identifiable {
    let id: String
    let crewConversationId: String
    let responsibleSubjectId: String
    let senderKind: String
    let senderMemberId: String?
    let senderSessionId: String?
    let recipientMode: String
    let messageKind: String
    let boardVisible: Bool
    let summary: String
    let payload: JSONValue
    let createdAt: String
    let mentions: [CrewAnnouncementMention]
}

struct CrewAnnouncementMention: Decodable, Identifiable {
    let id: String
    let announcementId: String
    let targetKind: String
    let targetSessionId: String?
    let targetMemberId: String?
    let createdAt: String
}

struct SessionMailboxItem: Decodable, Identifiable {
    let id: String
    let announcementId: String?
    let crewConversationId: String
    let responsibleSubjectId: String
    let senderKind: String?
    let senderMemberId: String?
    let senderSessionId: String?
    let recipientSessionId: String?
    let messageKind: String
    let summary: String
    let payload: JSONValue
    let status: String
    let createdAt: String
    let readAt: String?
}

struct RunnerHost: Decodable, Identifiable {
    let id: String
    let responsibleSubjectId: String
    let platform: String
    let displayName: String
    let capabilities: JSONValue
    let allowedRunnerKinds: JSONValue
    let status: String
    let lastSeenAt: String?
    let createdAt: String
    let updatedAt: String
}

struct HumanHelpRequest: Decodable, Identifiable {
    let id: String
    let temporaryGroupId: String
    let responsibleSubjectId: String
    let status: String
    let reason: String?
    let createdAt: String
    let decidedAt: String?
    let temporaryGroup: TemporaryGroupSummary
    let requester: HelpRequester?
}

struct TemporaryGroupSummary: Decodable {
    let title: String
    let temporaryKind: String?
    let status: String?
}

struct HelpRequester: Decodable {
    let id: String
    let displayName: String
    let memberKind: String
}

enum RunnerKind: String, CaseIterable, Identifiable, Codable {
    case cloudSandbox = "cloud_sandbox"
    case localClaudeCode = "local_claude_code"
    case localCodex = "local_codex"
    case localOpencode = "local_opencode"
    case localKilo = "local_kilo"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cloudSandbox: "Cloud Sandbox"
        case .localClaudeCode: "Claude Code"
        case .localCodex: "Codex"
        case .localOpencode: "opencode"
        case .localKilo: "Kilo"
        }
    }
}

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
