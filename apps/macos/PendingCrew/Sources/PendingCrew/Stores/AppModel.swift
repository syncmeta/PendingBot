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
    @Published var debugUserJWT: String
    @Published var subjectResponse: SubjectResponse?
    @Published var crews: [Crew] = []
    @Published var sessionsByCrew: [String: [CrewSession]] = [:]
    @Published var membersByCrew: [String: [CrewMember]] = [:]
    @Published var eventsBySession: [String: [SessionEvent]] = [:]
    @Published var announcementsByCrew: [String: [CrewAnnouncement]] = [:]
    @Published var mailboxBySession: [String: [SessionMailboxItem]] = [:]
    @Published var runnerHosts: [RunnerHost] = []
    @Published var activeRunnerHostId: String?
    @Published var activeRunnerLeaseId: String?
    @Published var activeRunnerSession: CrewSession?
    @Published var helpRequests: [HumanHelpRequest] = []
    @Published var deviceLoginChallenge: DeviceLoginChallenge?
    @Published var deviceGrantToken: String?
    @Published var localWorkspacePath: String
    @Published var selection: Selection? = .crews
    @Published var isLoading = false
    @Published var statusMessage = ""
    @Published var errorMessage: String?

    init() {
        let isUITestMode = ProcessInfo.processInfo.arguments.contains("--pendingcrew-ui-test")
        apiBaseURL = UserDefaults.standard.string(forKey: "apiBaseURL") ?? "https://api.pendingname.com"
#if DEBUG
        debugUserJWT = isUITestMode
            ? ""
            : (KeychainStore.get(account: "debug-worker-jwt")
                ?? KeychainStore.get(account: "worker-jwt")
                ?? "")
#else
        debugUserJWT = ""
#endif
        deviceGrantToken = isUITestMode ? nil : KeychainStore.get(account: "device-grant")
        localWorkspacePath = UserDefaults.standard.string(forKey: "localWorkspacePath") ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var api: PendingBotAPI? {
        guard let url = URL(string: apiBaseURL) else {
            return nil
        }
        guard let credential = authCredential else {
            return nil
        }
        return PendingBotAPI(baseURL: url, authToken: credential.token)
    }

    private static var allowDebugUserJWT: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    private var authCredential: PendingCrewAuthCredential? {
        PendingCrewAuthCredential.resolve(
            deviceGrantToken: deviceGrantToken,
            debugUserJWT: debugUserJWT,
            allowDebugUserJWT: Self.allowDebugUserJWT
        )
    }

    private var isDeviceGrantOnly: Bool {
        authCredential?.kind == .deviceGrant
    }

    var personalSubjectId: String? {
        subjectResponse?.subject.id
    }

    func bootstrap() async {
        guard api != nil else {
            statusMessage = "请先扫码登录"
            return
        }
        await refreshAll()
    }

    func saveSettings() {
        UserDefaults.standard.set(apiBaseURL, forKey: "apiBaseURL")
        UserDefaults.standard.set(localWorkspacePath, forKey: "localWorkspacePath")
#if DEBUG
        if debugUserJWT.isEmpty {
            KeychainStore.delete(account: "debug-worker-jwt")
            KeychainStore.delete(account: "worker-jwt")
        } else {
            do {
                try KeychainStore.set(debugUserJWT, account: "debug-worker-jwt")
                KeychainStore.delete(account: "worker-jwt")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
#else
        KeychainStore.delete(account: "debug-worker-jwt")
        KeychainStore.delete(account: "worker-jwt")
#endif
    }

    func clearDeviceGrant() {
        deviceGrantToken = nil
        KeychainStore.delete(account: "device-grant")
        subjectResponse = nil
        crews = []
        sessionsByCrew = [:]
        membersByCrew = [:]
        eventsBySession = [:]
        announcementsByCrew = [:]
        mailboxBySession = [:]
        runnerHosts = []
        helpRequests = []
        statusMessage = "已退出登录"
    }

    func clearDebugUserJWT() {
        debugUserJWT = ""
        KeychainStore.delete(account: "debug-worker-jwt")
        KeychainStore.delete(account: "worker-jwt")
    }

    func startDeviceLogin() async {
        await run("扫码登录已创建") {
            guard let url = URL(string: apiBaseURL) else { throw APIError.badURL }
            let api = PendingBotAPI(baseURL: url, authToken: "")
            let name = Host.current().localizedName ?? "Mac"
            deviceLoginChallenge = try await api.createDeviceLoginChallenge(deviceName: name)
            deviceGrantToken = nil
            KeychainStore.delete(account: "device-grant")
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
                await refreshAll()
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
            subjectResponse = try await subject
            self.crews = try await crews
            runnerHosts = try await hosts
            if isDeviceGrantOnly {
                helpRequests = []
            } else {
                helpRequests = try await api.listHumanHelpRequests()
            }
        }
    }

    func refreshCrew(_ crewId: String) async {
        await run("Crew 已刷新") {
            guard let api else { throw LocalError.missingAuth }
            async let sessions = api.listSessions(crewId: crewId)
            async let announcements = api.listAnnouncements(crewId: crewId)
            async let members = api.listMembers(crewId: crewId)
            sessionsByCrew[crewId] = try await sessions
            announcementsByCrew[crewId] = try await announcements
            membersByCrew[crewId] = try await members
        }
    }

    func refreshEvents(sessionId: String) async {
        await run("事件已刷新") {
            guard let api else { throw LocalError.missingAuth }
            async let events = api.listEvents(sessionId: sessionId)
            async let mailbox = api.listMailbox(sessionId: sessionId)
            eventsBySession[sessionId] = try await events
            mailboxBySession[sessionId] = try await mailbox
        }
    }

    func createCrew(title: String) async {
        await run("Crew 已创建") {
            guard let api else { throw LocalError.missingAuth }
            guard let subjectId = personalSubjectId else { throw LocalError.missingSubject }
            let id = try await api.createCrew(responsibleSubjectId: subjectId, title: title)
            selection = .crew(id)
            crews = try await api.listCrews()
            async let sessions = api.listSessions(crewId: id)
            async let announcements = api.listAnnouncements(crewId: id)
            async let members = api.listMembers(crewId: id)
            sessionsByCrew[id] = try await sessions
            announcementsByCrew[id] = try await announcements
            membersByCrew[id] = try await members
        }
    }

    func createSession(crewId: String, runnerKind: RunnerKind, taskBrief: String) async {
        await run("Session 已排队") {
            guard let api else { throw LocalError.missingAuth }
            let sessionId = try await api.createSession(crewId: crewId, runnerKind: runnerKind, taskBrief: taskBrief)
            async let sessions = api.listSessions(crewId: crewId)
            async let announcements = api.listAnnouncements(crewId: crewId)
            async let members = api.listMembers(crewId: crewId)
            sessionsByCrew[crewId] = try await sessions
            announcementsByCrew[crewId] = try await announcements
            membersByCrew[crewId] = try await members
            eventsBySession[sessionId] = try await api.listEvents(sessionId: sessionId)
        }
    }

    func createAnnouncement(
        crewId: String,
        summary: String,
        recipientSessionIds: Set<String>,
        recipientMemberIds: Set<String>
    ) async {
        await run("公告已发送") {
            guard let api else { throw LocalError.missingAuth }
            _ = try await api.createAnnouncement(
                crewId: crewId,
                summary: summary,
                recipientSessionIds: Array(recipientSessionIds),
                recipientMemberIds: Array(recipientMemberIds)
            )
            announcementsByCrew[crewId] = try await api.listAnnouncements(crewId: crewId)
            let sessions = try await api.listSessions(crewId: crewId)
            sessionsByCrew[crewId] = sessions
            let deliveredSessionIds = recipientSessionIds.isEmpty ? Set(sessions.map(\.id)) : recipientSessionIds
            for sessionId in deliveredSessionIds {
                mailboxBySession[sessionId] = try await api.listMailbox(sessionId: sessionId)
            }
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

    func runActiveSessionLocally() async {
        await run("本机执行已结束") {
            guard let api else { throw LocalError.missingAuth }
            guard let hostId = activeRunnerHostId, let session = activeRunnerSession else {
                throw LocalError.missingRunnerSession
            }
            guard let profile = LocalCodingAgentProfile.defaultProfile(
                for: session.runnerKind,
                workingDirectoryPath: localWorkspacePath
            ) else {
                throw LocalError.unsupportedLocalRunner
            }

            let mailbox = try await api.listMailbox(sessionId: session.id)
            mailboxBySession[session.id] = mailbox
            let taskPrompt = LocalCodingAgentContextPacket.render(session: session, mailbox: mailbox)
            let command = profile.renderCommand(for: session, taskPrompt: taskPrompt)
            _ = try await api.appendRunnerEvent(
                hostId: hostId,
                sessionId: session.id,
                eventType: "status",
                summary: "本机执行已启动",
                progressSummary: "本机执行中"
            )

            let runner = LocalCodingAgentProcessRunner()
            let result: LocalCodingAgentProcessResult
            do {
                result = try await Task.detached {
                    try await runner.run(command)
                }.value
            } catch {
                let summary = "本机执行启动失败：\(error.localizedDescription)"
                try? await api.finishRunnerSession(
                    hostId: hostId,
                    sessionId: session.id,
                    status: "failed",
                    summary: summary,
                    progressSummary: summary
                )
                throw error
            }

            let summary = LocalCodingAgentOutput.finalSummary(result)
            try await api.finishRunnerSession(
                hostId: hostId,
                sessionId: session.id,
                status: result.exitCode == 0 ? "completed" : "failed",
                summary: summary,
                progressSummary: result.exitCode == 0 ? "本机执行完成" : "本机执行失败"
            )
            sessionsByCrew[session.crewConversationId] = try await api.listSessions(crewId: session.crewConversationId)
            eventsBySession[session.id] = try await api.listEvents(sessionId: session.id)
            activeRunnerLeaseId = nil
            activeRunnerSession = nil
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
    case unsupportedLocalRunner

    var errorDescription: String? {
        switch self {
        case .missingAuth:
            "请先扫码登录"
        case .missingSubject:
            "还没有加载到当前账号的 subject"
        case .missingRunnerSession:
            "当前没有已认领的 runner session"
        case .missingDeviceLoginChallenge:
            "请先创建扫码登录"
        case .unsupportedLocalRunner:
            "这个 session 不是本机 runner 类型"
        }
    }
}
