import Foundation
import PendingBotShared

struct PendingBotMacAPI {
    var baseURL: URL
    var authToken: String?
    var session: URLSession = .shared

    func createDeviceLoginChallenge(deviceName: String) async throws -> PendingBotMacDeviceLoginChallenge {
        try await postUnauthenticated(
            "/v1/device-login/challenges",
            body: DeviceLoginChallengeBody(
                appKind: "pendingbot_macos",
                deviceName: deviceName,
                devicePublicKey: "pendingbot-macos-bootstrap-\(UUID().uuidString)",
                scopes: ["subject:read", "crew:read", "crew:write"]
            )
        )
    }

    func pollDeviceLoginChallenge(challengeId: String, secret: String) async throws -> PendingBotMacDeviceLoginPollResponse {
        let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? secret
        return try await getUnauthenticated("/v1/device-login/challenges/\(challengeId)?secret=\(encoded)")
    }

    func currentSubject() async throws -> PendingBotMacSubject {
        let envelope: SubjectEnvelope = try await get("/v1/me/subject")
        return envelope.subject
    }

    func listCrews() async throws -> [PendingBotCrewSummary] {
        let response: ListResponse<CrewDTO> = try await get("/v1/crew")
        return response.items.map { crew in
            PendingBotCrewSummary(
                id: crew.conversationId,
                title: crew.title,
                status: crew.status,
                runtimeKind: PendingBotCrewRuntimeKind(apiValue: crew.runtimeKind ?? "local"),
                updatedAt: crew.updatedAt
            )
        }
    }

    func crewDetail(crewId: String) async throws -> PendingBotCrewDetail {
        async let links = crewLinks(crewId: crewId)
        async let sessions = crewSessions(crewId: crewId)
        async let members = crewMembers(crewId: crewId)
        async let announcements = crewAnnouncements(crewId: crewId)
        let resolved = try await (links, sessions, members, announcements)
        return PendingBotCrewDetail(
            crewId: crewId,
            parents: resolved.0.parents,
            children: resolved.0.children,
            responsibilityShares: resolved.0.responsibilityShares,
            sessions: resolved.1,
            members: resolved.2,
            announcements: resolved.3
        )
    }

    func sendAnnouncement(crewId: String, summary: String) async throws -> String {
        let response: CreateAnnouncementResponse = try await post(
            "/v1/crew/\(crewId)/announcements",
            body: AnnouncementBody(
                recipientSessionIds: [],
                recipientMemberIds: [],
                messageKind: "announcement",
                summary: summary,
                payload: [:],
                boardVisible: true
            )
        )
        return response.announcementId
    }

    func createSession(crewId: String, runnerKind: PendingBotCrewRunnerKind, taskBrief: String) async throws -> String {
        let response: CreateSessionResponse = try await post(
            "/v1/crew/\(crewId)/sessions",
            body: CreateSessionBody(runnerKind: runnerKind.rawValue, taskBrief: taskBrief)
        )
        return response.sessionId
    }

    func createChildCrew(crewId: String, title: String) async throws -> String {
        let response: CreateCrewResponse = try await post(
            "/v1/crew/\(crewId)/children",
            body: CreateChildCrewBody(title: title)
        )
        return response.conversationId
    }

    private func crewLinks(crewId: String) async throws -> CrewLinksResponse {
        let response: CrewLinksDTO = try await get("/v1/crew/\(crewId)/links")
        return CrewLinksResponse(
            parents: response.parents.map(\.shared),
            children: response.children.map(\.shared),
            responsibilityShares: response.responsibilityShares.map(\.shared)
        )
    }

    private func crewSessions(crewId: String) async throws -> [PendingBotCrewSession] {
        let response: ListResponse<CrewSessionDTO> = try await get("/v1/crew/\(crewId)/sessions")
        return response.items.map(\.shared)
    }

    private func crewMembers(crewId: String) async throws -> [PendingBotCrewMember] {
        let response: ListResponse<CrewMemberDTO> = try await get("/v1/crew/\(crewId)/members")
        return response.items.map(\.shared)
    }

    private func crewAnnouncements(crewId: String) async throws -> [PendingBotCrewAnnouncement] {
        let response: ListResponse<CrewAnnouncementDTO> = try await get("/v1/crew/\(crewId)/announcements")
        return response.items.map(\.shared)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(makeRequest(method: "GET", path: path, body: Optional<String>.none))
    }

    private func getUnauthenticated<T: Decodable>(_ path: String) async throws -> T {
        try await send(makeUnauthenticatedRequest(method: "GET", path: path, body: Optional<String>.none))
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        try await send(makeRequest(method: "POST", path: path, body: body))
    }

    private func postUnauthenticated<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        try await send(makeUnauthenticatedRequest(method: "POST", path: path, body: body))
    }

    private func makeRequest<Body: Encodable>(method: String, path: String, body: Body?) throws -> URLRequest {
        guard let token = authToken, !token.isEmpty else {
            throw PendingBotMacAPIError.missingToken
        }
        var request = try makeUnauthenticatedRequest(method: method, path: path, body: body)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeUnauthenticatedRequest<Body: Encodable>(method: String, path: String, body: Body?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw PendingBotMacAPIError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PendingBotMacAPIError.notHTTP
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let envelope = try? JSONDecoder.pendingBot.decode(ServerErrorEnvelope.self, from: data)
            throw PendingBotMacAPIError.http(
                status: http.statusCode,
                code: envelope?.error.code,
                message: envelope?.error.message,
                body: body
            )
        }
        if data.isEmpty {
            return try JSONDecoder.pendingBot.decode(T.self, from: Data("{}".utf8))
        }
        return try JSONDecoder.pendingBot.decode(T.self, from: data)
    }
}

struct PendingBotMacSubject: Decodable, Hashable {
    let id: String
    let subjectType: String
    let displayName: String
    let status: String
}

struct PendingBotMacDeviceLoginChallenge: Decodable, Hashable {
    let challengeId: String
    let secret: String
    let code: String
    let qrPayload: String
    let expiresAt: String
    let status: String
}

struct PendingBotMacDeviceLoginPollResponse: Decodable, Hashable {
    let status: String
    let deviceGrantToken: String?
    let grantId: String?
    let subjectId: String?
    let grantKind: String?
    let scopes: [String]?
}

private struct ListResponse<Item: Decodable>: Decodable {
    let items: [Item]
}

private struct SubjectEnvelope: Decodable {
    let subject: PendingBotMacSubject
}

private struct CrewDTO: Decodable {
    let conversationId: String
    let status: String
    let title: String
    let runtimeKind: String?
    let updatedAt: String
}

private struct CrewLinkDTO: Decodable {
    let crewConversationId: String
    let title: String
    let status: String
    let runtimeKind: String
    let captainBotId: String?
    let captainMemberId: String?
    let createdAt: String

    var shared: PendingBotCrewLink {
        PendingBotCrewLink(
            crewId: crewConversationId,
            title: title,
            status: status,
            runtimeKind: PendingBotCrewRuntimeKind(apiValue: runtimeKind),
            captainBotId: captainBotId,
            captainMemberId: captainMemberId,
            createdAt: createdAt
        )
    }
}

private struct CrewResponsibilityShareDTO: Decodable {
    let subjectId: String
    let shareBps: Int
    let source: String

    var shared: PendingBotCrewResponsibilityShare {
        PendingBotCrewResponsibilityShare(subjectId: subjectId, shareBps: shareBps, source: source)
    }
}

private struct CrewLinksDTO: Decodable {
    let parents: [CrewLinkDTO]
    let children: [CrewLinkDTO]
    let responsibilityShares: [CrewResponsibilityShareDTO]
}

private struct CrewLinksResponse {
    let parents: [PendingBotCrewLink]
    let children: [PendingBotCrewLink]
    let responsibilityShares: [PendingBotCrewResponsibilityShare]
}

private struct CrewSessionDTO: Decodable {
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

    var shared: PendingBotCrewSession {
        PendingBotCrewSession(
            id: id,
            crewId: crewConversationId,
            responsibleSubjectId: responsibleSubjectId,
            runnerKind: PendingBotCrewRunnerKind(rawValue: runnerKind) ?? .localCodex,
            status: status,
            taskBrief: taskBrief,
            progressSummary: progressSummary,
            createdAt: createdAt,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }
}

private struct CrewMemberDTO: Decodable {
    let id: String
    let conversationId: String
    let memberKind: String
    let displayName: String
    let role: String
    let status: String
    let createdAt: String

    var shared: PendingBotCrewMember {
        PendingBotCrewMember(
            id: id,
            crewId: conversationId,
            memberKind: memberKind,
            displayName: displayName,
            role: role,
            status: status,
            createdAt: createdAt
        )
    }
}

private struct CrewAnnouncementDTO: Decodable {
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
    let createdAt: String
    let mentions: [CrewAnnouncementMentionDTO]

    var shared: PendingBotCrewAnnouncement {
        PendingBotCrewAnnouncement(
            id: id,
            crewId: crewConversationId,
            responsibleSubjectId: responsibleSubjectId,
            senderKind: senderKind,
            senderMemberId: senderMemberId,
            senderSessionId: senderSessionId,
            recipientMode: recipientMode,
            messageKind: messageKind,
            boardVisible: boardVisible,
            summary: summary,
            createdAt: createdAt,
            mentions: mentions.map(\.shared)
        )
    }
}

private struct CrewAnnouncementMentionDTO: Decodable {
    let id: String
    let announcementId: String
    let targetKind: String
    let targetSessionId: String?
    let targetMemberId: String?
    let createdAt: String

    var shared: PendingBotCrewAnnouncementMention {
        PendingBotCrewAnnouncementMention(
            id: id,
            announcementId: announcementId,
            targetKind: targetKind,
            targetSessionId: targetSessionId,
            targetMemberId: targetMemberId,
            createdAt: createdAt
        )
    }
}

private struct DeviceLoginChallengeBody: Encodable {
    let appKind: String
    let deviceName: String
    let devicePublicKey: String
    let scopes: [String]
}

private struct AnnouncementBody: Encodable {
    let recipientSessionIds: [String]
    let recipientMemberIds: [String]
    let messageKind: String
    let summary: String
    let payload: [String: String]
    let boardVisible: Bool
}

private struct CreateAnnouncementResponse: Decodable {
    let announcementId: String
}

private struct CreateSessionBody: Encodable {
    let runnerKind: String
    let taskBrief: String
}

private struct CreateSessionResponse: Decodable {
    let sessionId: String
}

private struct CreateChildCrewBody: Encodable {
    let title: String
}

private struct CreateCrewResponse: Decodable {
    let conversationId: String
}

private struct ServerErrorEnvelope: Decodable {
    let error: ServerErrorPayload
}

private struct ServerErrorPayload: Decodable {
    let code: String?
    let message: String?
}

enum PendingBotMacAPIError: LocalizedError {
    case badURL
    case missingToken
    case notHTTP
    case http(status: Int, code: String?, message: String?, body: String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            "URL 无效"
        case .missingToken:
            "尚未登录"
        case .notHTTP:
            "非 HTTP 响应"
        case .http(let status, _, let message, let body):
            message ?? "HTTP \(status): \(body.prefix(200))"
        }
    }
}

private extension JSONDecoder {
    static var pendingBot: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
