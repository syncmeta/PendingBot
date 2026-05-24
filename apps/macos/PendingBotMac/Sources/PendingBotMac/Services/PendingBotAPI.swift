import Foundation

struct PendingBotAPI {
    var baseURL: URL
    var authToken: String
    var session: URLSession = .shared

    func getSubject() async throws -> SubjectResponse {
        try await get("/v1/me/subject")
    }

    func listCrews() async throws -> [Crew] {
        let response: ListResponse<Crew> = try await get("/v1/crew")
        return response.items
    }

    func createCrew(responsibleSubjectId: String, title: String) async throws -> String {
        let response: CreateCrewResponse = try await post(
            "/v1/crew",
            body: ["responsibleSubjectId": responsibleSubjectId, "title": title]
        )
        return response.conversationId
    }

    func listSessions(crewId: String) async throws -> [CrewSession] {
        let response: ListResponse<CrewSession> = try await get("/v1/crew/\(crewId)/sessions")
        return response.items
    }

    func createSession(crewId: String, runnerKind: RunnerKind, taskBrief: String) async throws -> String {
        let response: CreateSessionResponse = try await post(
            "/v1/crew/\(crewId)/sessions",
            body: ["runnerKind": runnerKind.rawValue, "taskBrief": taskBrief]
        )
        return response.sessionId
    }

    func listEvents(sessionId: String) async throws -> [SessionEvent] {
        let response: ListResponse<SessionEvent> = try await get("/v1/crew/sessions/\(sessionId)/events")
        return response.items
    }

    func listRunnerHosts() async throws -> [RunnerHost] {
        let response: ListResponse<RunnerHost> = try await get("/v1/runner-hosts")
        return response.items
    }

    func registerRunnerHost(
        responsibleSubjectId: String,
        displayName: String,
        allowedRunnerKinds: [RunnerKind]
    ) async throws -> String {
        let response: RegisterRunnerHostResponse = try await post(
            "/v1/runner-hosts",
            body: RegisterRunnerHostBody(
                responsibleSubjectId: responsibleSubjectId,
                displayName: displayName,
                capabilities: [
                    "platform": "macos",
                    "mode": "local"
                ],
                allowedRunnerKinds: allowedRunnerKinds.map(\.rawValue)
            )
        )
        return response.runnerHostId
    }

    func heartbeatRunnerHost(id: String, allowedRunnerKinds: [RunnerKind]) async throws {
        let _: OkResponse = try await post(
            "/v1/runner-hosts/\(id)/heartbeat",
            body: RunnerHeartbeatBody(
                capabilities: [
                    "platform": "macos",
                    "mode": "local"
                ],
                allowedRunnerKinds: allowedRunnerKinds.map(\.rawValue)
            )
        )
    }

    func claimNextSession(hostId: String, runnerKinds: [RunnerKind]) async throws -> RunnerClaimResponse {
        try await post(
            "/v1/runner-hosts/\(hostId)/claim-next",
            body: ClaimNextBody(runnerKinds: runnerKinds.map(\.rawValue))
        )
    }

    func appendRunnerEvent(
        hostId: String,
        sessionId: String,
        eventType: String,
        summary: String,
        progressSummary: String?
    ) async throws -> String {
        let response: AppendRunnerEventResponse = try await post(
            "/v1/runner-hosts/\(hostId)/sessions/\(sessionId)/events",
            body: RunnerEventBody(
                eventType: eventType,
                visibility: "crew_members",
                summary: summary,
                payload: [:],
                progressSummary: progressSummary
            )
        )
        return response.eventId
    }

    func finishRunnerSession(
        hostId: String,
        sessionId: String,
        status: String,
        summary: String,
        progressSummary: String?
    ) async throws {
        let _: OkResponse = try await post(
            "/v1/runner-hosts/\(hostId)/sessions/\(sessionId)/finish",
            body: FinishRunnerSessionBody(
                status: status,
                summary: summary,
                payload: [:],
                progressSummary: progressSummary
            )
        )
    }

    func listHumanHelpRequests() async throws -> [HumanHelpRequest] {
        let response: ListResponse<HumanHelpRequest> = try await get("/v1/human-help-requests")
        return response.items
    }

    func decideHumanHelpRequest(id: String, decision: String) async throws {
        let _: OkResponse = try await post(
            "/v1/human-help-requests/\(id)/decision",
            body: ["decision": decision]
        )
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(makeRequest(method: "GET", path: path, body: Optional<String>.none))
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        try await send(makeRequest(method: "POST", path: path, body: body))
    }

    private func makeRequest<Body: Encodable>(method: String, path: String, body: Body?) async throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
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
            throw APIError.notHTTP
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data)
            throw APIError.http(
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

private struct RegisterRunnerHostBody: Encodable {
    let responsibleSubjectId: String
    let displayName: String
    let capabilities: [String: String]
    let allowedRunnerKinds: [String]
}

private struct RunnerHeartbeatBody: Encodable {
    let capabilities: [String: String]
    let allowedRunnerKinds: [String]
}

private struct ClaimNextBody: Encodable {
    let runnerKinds: [String]
}

private struct RunnerEventBody: Encodable {
    let eventType: String
    let visibility: String
    let summary: String
    let payload: [String: String]
    let progressSummary: String?
}

private struct AppendRunnerEventResponse: Decodable {
    let eventId: String
}

private struct FinishRunnerSessionBody: Encodable {
    let status: String
    let summary: String
    let payload: [String: String]
    let progressSummary: String?
}

private struct ServerErrorEnvelope: Decodable {
    let error: ServerErrorPayload
}

private struct ServerErrorPayload: Decodable {
    let code: String?
    let message: String?
}

enum APIError: LocalizedError {
    case badURL
    case notHTTP
    case http(status: Int, code: String?, message: String?, body: String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            "URL 无效"
        case .notHTTP:
            "非 HTTP 响应"
        case .http(let status, _, let message, let body):
            message ?? "HTTP \(status): \(body.prefix(200))"
        }
    }
}

extension JSONDecoder {
    static var pendingBot: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
