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
}

