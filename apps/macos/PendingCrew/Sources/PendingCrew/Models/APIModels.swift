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
