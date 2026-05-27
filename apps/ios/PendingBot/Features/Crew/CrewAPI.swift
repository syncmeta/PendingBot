import Foundation

struct CrewListResponse<Item: Decodable>: Decodable {
    let items: [Item]
}

struct CrewSubjectEnvelope: Decodable {
    let subject: CrewSubject
}

struct CrewSubject: Decodable, Identifiable, Hashable {
    let id: String
    let subject_type: String
    let display_name: String
    let status: String
}

struct CrewSummary: Decodable, Identifiable, Hashable {
    var id: String { conversation_id }
    let conversation_id: String
    let responsible_subject_id: String
    let status: String
    let title: String
    let runtime_kind: String?
    let created_at: String
    let updated_at: String
}

struct CrewRunnerHost: Decodable, Identifiable, Hashable {
    let id: String
    let responsible_subject_id: String
    let platform: String
    let display_name: String
    let allowed_runner_kinds: [String]
    let status: String
    let last_seen_at: String?
}

struct DeviceLoginApprovalResponse: Decodable, Hashable {
    let ok: Bool
    let status: String
}

struct CrewSessionSummary: Decodable, Identifiable, Hashable {
    let id: String
    let crew_conversation_id: String
    let responsible_subject_id: String
    let runner_kind: String
    let status: String
    let task_brief: String
    let progress_summary: String?
    let created_at: String
    let started_at: String?
    let finished_at: String?
}

struct CrewLinkSummary: Decodable, Identifiable, Hashable {
    var id: String { crew_conversation_id }
    let crew_conversation_id: String
    let title: String
    let status: String
    let runtime_kind: String
    let captain_bot_id: String?
    let captain_member_id: String?
    let created_at: String
}

struct CrewResponsibilityShareSummary: Decodable, Identifiable, Hashable {
    var id: String { subject_id }
    let subject_id: String
    let share_bps: Int
    let source: String
}

struct CrewLinksResponse: Decodable, Hashable {
    let parents: [CrewLinkSummary]
    let children: [CrewLinkSummary]
    let responsibilityShares: [CrewResponsibilityShareSummary]
}

struct CrewMemberSummary: Decodable, Identifiable, Hashable {
    let id: String
    let conversation_id: String
    let member_kind: String
    let user_id: String?
    let bot_id: String?
    let code_session_id: String?
    let display_name: String
    let role: String?
    let status: String
    let created_at: String
}

struct CrewAnnouncementMentionSummary: Decodable, Identifiable, Hashable {
    let id: String
    let announcement_id: String
    let target_kind: String
    let target_session_id: String?
    let target_member_id: String?
    let created_at: String
}

struct CrewAnnouncementSummary: Decodable, Identifiable, Hashable {
    let id: String
    let crew_conversation_id: String
    let responsible_subject_id: String
    let sender_kind: String
    let sender_member_id: String?
    let sender_session_id: String?
    let recipient_mode: String
    let message_kind: String
    let board_visible: Bool
    let summary: String
    let created_at: String
    let mentions: [CrewAnnouncementMentionSummary]
}

struct CrewAnnouncementCreateResponse: Decodable, Hashable {
    let announcementId: String
}

enum DeviceLoginGrantApproval: Equatable {
    case pendingCrewControl
    case pendingBotClient

    var grantKind: String {
        switch self {
        case .pendingCrewControl: "pendingcrew_control"
        case .pendingBotClient: "pendingbot_client"
        }
    }

    var scopes: [String] {
        switch self {
        case .pendingCrewControl:
            ["subject:read", "crew:read", "crew:write", "runner:read", "runner:write"]
        case .pendingBotClient:
            ["subject:read", "crew:read", "crew:write"]
        }
    }

    static func retryPlan(after error: Error) -> DeviceLoginGrantApproval? {
        guard case let APIError.http(status, code, message, body) = error,
              status == 400,
              code == "invalid_body"
        else { return nil }

        let text = [message, body].compactMap { $0?.lowercased() }.joined(separator: "\n")
        if text.contains("grant kind does not match app kind")
            || text.contains("requested scopes exceed grant kind") {
            return .pendingBotClient
        }
        return nil
    }
}

enum CrewRunnerKind: String, CaseIterable, Identifiable, Hashable {
    case cloudSandbox = "cloud_sandbox"
    case localClaudeCode = "local_claude_code"
    case localCodex = "local_codex"
    case localOpencode = "local_opencode"
    case localKilo = "local_kilo"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cloudSandbox: "云端 Sandbox"
        case .localClaudeCode: "Mac Claude Code"
        case .localCodex: "Mac Codex"
        case .localOpencode: "Mac opencode"
        case .localKilo: "Mac Kilo"
        }
    }
}

extension APIClient {
    func crewCurrentSubject() async throws -> CrewSubject {
        let envelope: CrewSubjectEnvelope = try await get("v1/me/subject")
        return envelope.subject
    }

    func crewList() async throws -> [CrewSummary] {
        let response: CrewListResponse<CrewSummary> = try await get("v1/crew")
        return response.items
    }

    func crewCreate(responsibleSubjectId: String, title: String) async throws -> String {
        struct Body: Encodable {
            let responsibleSubjectId: String
            let title: String
        }
        struct Response: Decodable {
            let conversationId: String
        }
        let response: Response = try await post(
            "v1/crew",
            body: Body(responsibleSubjectId: responsibleSubjectId, title: title)
        )
        return response.conversationId
    }

    func crewCreateChild(crewId: String, title: String) async throws -> String {
        struct Body: Encodable {
            let title: String
        }
        struct Response: Decodable {
            let conversationId: String
        }
        let response: Response = try await post(
            "v1/crew/\(crewId)/children",
            body: Body(title: title)
        )
        return response.conversationId
    }

    func crewLinks(crewId: String) async throws -> CrewLinksResponse {
        try await get("v1/crew/\(crewId)/links")
    }

    func crewMembers(crewId: String) async throws -> [CrewMemberSummary] {
        let response: CrewListResponse<CrewMemberSummary> = try await get("v1/crew/\(crewId)/members")
        return response.items
    }

    func crewAnnouncements(crewId: String) async throws -> [CrewAnnouncementSummary] {
        let response: CrewListResponse<CrewAnnouncementSummary> = try await get("v1/crew/\(crewId)/announcements")
        return response.items
    }

    func crewCreateAnnouncement(
        crewId: String,
        summary: String,
        recipientSessionIds: [String] = [],
        recipientMemberIds: [String] = []
    ) async throws -> CrewAnnouncementCreateResponse {
        struct Body: Encodable {
            let recipientSessionIds: [String]
            let recipientMemberIds: [String]
            let messageKind: String
            let summary: String
            let payload: [String: String]
            let boardVisible: Bool
        }
        return try await post(
            "v1/crew/\(crewId)/announcements",
            body: Body(
                recipientSessionIds: recipientSessionIds,
                recipientMemberIds: recipientMemberIds,
                messageKind: "announcement",
                summary: summary,
                payload: [:],
                boardVisible: true
            )
        )
    }

    func crewSessions(crewId: String) async throws -> [CrewSessionSummary] {
        let response: CrewListResponse<CrewSessionSummary> = try await get("v1/crew/\(crewId)/sessions")
        return response.items
    }

    func crewCreateSession(
        crewId: String,
        runnerKind: CrewRunnerKind,
        taskBrief: String
    ) async throws -> String {
        struct Body: Encodable {
            let runnerKind: String
            let taskBrief: String
        }
        struct Response: Decodable {
            let sessionId: String
        }
        let response: Response = try await post(
            "v1/crew/\(crewId)/sessions",
            body: Body(runnerKind: runnerKind.rawValue, taskBrief: taskBrief)
        )
        return response.sessionId
    }

    func crewRunnerHosts() async throws -> [CrewRunnerHost] {
        let response: CrewListResponse<CrewRunnerHost> = try await get("v1/runner-hosts")
        return response.items
    }

    func approvePendingCrewDeviceLogin(
        challengeId: String,
        secret: String,
        subjectId: String,
        approval: DeviceLoginGrantApproval = .pendingCrewControl
    ) async throws -> DeviceLoginApprovalResponse {
        struct Body: Encodable {
            let secret: String
            let subjectId: String
            let grantKind: String
            let scopes: [String]
        }
        return try await post(
            "v1/device-login/challenges/\(challengeId)/approve",
            body: Body(secret: secret, subjectId: subjectId, grantKind: approval.grantKind, scopes: approval.scopes)
        )
    }
}
