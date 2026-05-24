import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Selection: Hashable {
        case crews
        case crew(String)
        case runnerHosts
        case helpRequests
    }

    @Published var apiBaseURL: String
    @Published var authToken: String
    @Published var subjectResponse: SubjectResponse?
    @Published var crews: [Crew] = []
    @Published var sessionsByCrew: [String: [CrewSession]] = [:]
    @Published var eventsBySession: [String: [SessionEvent]] = [:]
    @Published var runnerHosts: [RunnerHost] = []
    @Published var activeRunnerHostId: String?
    @Published var activeRunnerLeaseId: String?
    @Published var activeRunnerSession: CrewSession?
    @Published var helpRequests: [HumanHelpRequest] = []
    @Published var deviceLoginChallenge: DeviceLoginChallenge?
    @Published var deviceGrantToken: String?
    @Published var selection: Selection? = .crews
    @Published var isLoading = false
    @Published var statusMessage = ""
    @Published var errorMessage: String?

    init() {
        apiBaseURL = UserDefaults.standard.string(forKey: "apiBaseURL") ?? "https://api.pendingname.com"
        authToken = KeychainStore.get(account: "worker-jwt") ?? ""
        deviceGrantToken = KeychainStore.get(account: "device-grant")
    }

    var api: PendingBotAPI? {
        guard let url = URL(string: apiBaseURL), !authToken.isEmpty else {
            return nil
        }
        return PendingBotAPI(baseURL: url, authToken: authToken)
    }

    var personalSubjectId: String? {
        subjectResponse?.subject.id
    }

    func bootstrap() async {
        guard api != nil else {
            statusMessage = "请先在设置里填写 API URL 和登录 JWT"
            return
        }
        await refreshAll()
    }

    func saveSettings() {
        UserDefaults.standard.set(apiBaseURL, forKey: "apiBaseURL")
        if authToken.isEmpty {
            KeychainStore.delete(account: "worker-jwt")
        } else {
            do {
                try KeychainStore.set(authToken, account: "worker-jwt")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func startDeviceLogin() async {
        await run("扫码登录已创建") {
            guard let url = URL(string: apiBaseURL) else { throw APIError.badURL }
            let api = PendingBotAPI(baseURL: url, authToken: "")
            let name = Host.current().localizedName ?? "Mac"
            deviceLoginChallenge = try await api.createDeviceLoginChallenge(deviceName: name)
            deviceGrantToken = nil
        }
    }

    func pollDeviceLogin() async {
        await run("扫码登录状态已更新") {
            guard let url = URL(string: apiBaseURL) else { throw APIError.badURL }
            guard let challenge = deviceLoginChallenge else { throw LocalError.missingDeviceLoginChallenge }
            let api = PendingBotAPI(baseURL: url, authToken: "")
            let response = try await api.pollDeviceLoginChallenge(
                challengeId: challenge.challengeId,
                secret: challenge.secret
            )
            if let token = response.deviceGrantToken {
                deviceGrantToken = token
                try KeychainStore.set(token, account: "device-grant")
                statusMessage = "设备 grant 已保存"
            } else {
                statusMessage = "扫码登录状态：\(response.status)"
            }
        }
    }

    func refreshAll() async {
        await run("已刷新") {
            guard let api else { throw LocalError.missingAuth }
            async let subject = api.getSubject()
            async let crews = api.listCrews()
            async let hosts = api.listRunnerHosts()
            async let help = api.listHumanHelpRequests()
            subjectResponse = try await subject
            self.crews = try await crews
            runnerHosts = try await hosts
            helpRequests = try await help
        }
    }

    func refreshCrew(_ crewId: String) async {
        await run("Crew 已刷新") {
            guard let api else { throw LocalError.missingAuth }
            sessionsByCrew[crewId] = try await api.listSessions(crewId: crewId)
        }
    }

    func refreshEvents(sessionId: String) async {
        await run("事件已刷新") {
            guard let api else { throw LocalError.missingAuth }
            eventsBySession[sessionId] = try await api.listEvents(sessionId: sessionId)
        }
    }

    func createCrew(title: String) async {
        await run("Crew 已创建") {
            guard let api else { throw LocalError.missingAuth }
            guard let subjectId = personalSubjectId else { throw LocalError.missingSubject }
            let id = try await api.createCrew(responsibleSubjectId: subjectId, title: title)
            selection = .crew(id)
            crews = try await api.listCrews()
            sessionsByCrew[id] = try await api.listSessions(crewId: id)
        }
    }

    func createSession(crewId: String, runnerKind: RunnerKind, taskBrief: String) async {
        await run("Session 已排队") {
            guard let api else { throw LocalError.missingAuth }
            let sessionId = try await api.createSession(crewId: crewId, runnerKind: runnerKind, taskBrief: taskBrief)
            sessionsByCrew[crewId] = try await api.listSessions(crewId: crewId)
            eventsBySession[sessionId] = try await api.listEvents(sessionId: sessionId)
        }
    }

    func registerRunnerHost(displayName: String, kinds: Set<RunnerKind>) async {
        await run("Runner 已注册") {
            guard let api else { throw LocalError.missingAuth }
            guard let subjectId = personalSubjectId else { throw LocalError.missingSubject }
            _ = try await api.registerRunnerHost(
                responsibleSubjectId: subjectId,
                displayName: displayName,
                allowedRunnerKinds: Array(kinds)
            )
            runnerHosts = try await api.listRunnerHosts()
        }
    }

    func heartbeat(hostId: String, kinds: Set<RunnerKind>) async {
        await run("心跳已发送") {
            guard let api else { throw LocalError.missingAuth }
            try await api.heartbeatRunnerHost(id: hostId, allowedRunnerKinds: Array(kinds))
            runnerHosts = try await api.listRunnerHosts()
        }
    }

    func claimNextSession(hostId: String, kinds: Set<RunnerKind>) async {
        await run("已检查队列") {
            guard let api else { throw LocalError.missingAuth }
            let claim = try await api.claimNextSession(hostId: hostId, runnerKinds: Array(kinds))
            activeRunnerHostId = hostId
            activeRunnerLeaseId = claim.leaseId
            activeRunnerSession = claim.session
            if let session = claim.session {
                sessionsByCrew[session.crewConversationId] = try await api.listSessions(crewId: session.crewConversationId)
                eventsBySession[session.id] = try await api.listEvents(sessionId: session.id)
                statusMessage = "已认领 session"
            } else {
                statusMessage = "没有可认领的 session"
            }
            runnerHosts = try await api.listRunnerHosts()
        }
    }

    func appendRunnerStatus(summary: String) async {
        await run("已上报进度") {
            guard let api else { throw LocalError.missingAuth }
            guard let hostId = activeRunnerHostId, let session = activeRunnerSession else {
                throw LocalError.missingRunnerSession
            }
            _ = try await api.appendRunnerEvent(
                hostId: hostId,
                sessionId: session.id,
                eventType: "status",
                summary: summary,
                progressSummary: summary
            )
            eventsBySession[session.id] = try await api.listEvents(sessionId: session.id)
            sessionsByCrew[session.crewConversationId] = try await api.listSessions(crewId: session.crewConversationId)
        }
    }

    func finishActiveRunnerSession(status: String, summary: String) async {
        await run("Session 已结束") {
            guard let api else { throw LocalError.missingAuth }
            guard let hostId = activeRunnerHostId, let session = activeRunnerSession else {
                throw LocalError.missingRunnerSession
            }
            try await api.finishRunnerSession(
                hostId: hostId,
                sessionId: session.id,
                status: status,
                summary: summary,
                progressSummary: summary
            )
            sessionsByCrew[session.crewConversationId] = try await api.listSessions(crewId: session.crewConversationId)
            eventsBySession[session.id] = try await api.listEvents(sessionId: session.id)
            activeRunnerLeaseId = nil
            activeRunnerSession = nil
        }
    }

    func decideHelpRequest(id: String, accepted: Bool) async {
        await run(accepted ? "已接受请求" : "已拒绝请求") {
            guard let api else { throw LocalError.missingAuth }
            try await api.decideHumanHelpRequest(id: id, decision: accepted ? "accepted" : "declined")
            helpRequests = try await api.listHumanHelpRequests()
            crews = try await api.listCrews()
        }
    }

    private func run(_ successMessage: String, operation: () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await operation()
            statusMessage = successMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum LocalError: LocalizedError {
    case missingAuth
    case missingSubject
    case missingRunnerSession
    case missingDeviceLoginChallenge

    var errorDescription: String? {
        switch self {
        case .missingAuth:
            "请先填写 API URL 和登录 JWT"
        case .missingSubject:
            "还没有加载到当前账号的 subject"
        case .missingRunnerSession:
            "当前没有已认领的 runner session"
        case .missingDeviceLoginChallenge:
            "请先创建扫码登录"
        }
    }
}
