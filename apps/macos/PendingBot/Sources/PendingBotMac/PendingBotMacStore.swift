import Foundation
import PendingBotShared

@MainActor
final class PendingBotMacStore: ObservableObject {
    @Published var apiBaseURLString: String
    @Published private(set) var authToken: String?
    @Published private(set) var subject: PendingBotMacSubject?
    @Published private(set) var loginChallenge: PendingBotMacDeviceLoginChallenge?
    @Published private(set) var loginStatus: String?
    @Published private(set) var isPollingLogin = false
    @Published private(set) var crews: [PendingBotCrewSummary] = []
    @Published var selectedCrewId: String?
    @Published private(set) var crewDetails: [String: PendingBotCrewDetail] = [:]
    @Published private(set) var crewDetailLoadingIds: Set<String> = []
    @Published private(set) var crewDetailErrors: [String: String] = [:]
    @Published private(set) var isLoadingCrews = false
    @Published var errorMessage: String?

    private var pollTask: Task<Void, Never>?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apiBaseURLString = defaults.string(forKey: DefaultsKey.apiBaseURL) ?? "https://api.pendingname.com"
        self.authToken = PendingBotMacTokenStore.load()
    }

    var isLoggedIn: Bool {
        authToken?.isEmpty == false
    }

    func saveAPIBaseURL() {
        apiBaseURLString = apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(apiBaseURLString, forKey: DefaultsKey.apiBaseURL)
        if isLoggedIn {
            Task { await reloadAll() }
        }
    }

    func startDeviceLogin() async {
        errorMessage = nil
        loginStatus = "正在创建登录挑战"
        loginChallenge = nil
        pollTask?.cancel()

        do {
            let challenge = try await api(authToken: nil).createDeviceLoginChallenge(deviceName: deviceName)
            loginChallenge = challenge
            loginStatus = "等待 PendingBot 扫码批准"
            beginPolling(challenge: challenge)
        } catch {
            loginStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    func cancelLogin() {
        pollTask?.cancel()
        pollTask = nil
        isPollingLogin = false
        loginChallenge = nil
        loginStatus = nil
    }

    func signOut() {
        pollTask?.cancel()
        PendingBotMacTokenStore.clear()
        authToken = nil
        subject = nil
        loginChallenge = nil
        loginStatus = nil
        crews = []
        selectedCrewId = nil
        crewDetails = [:]
        crewDetailErrors = [:]
        crewDetailLoadingIds = []
    }

    func reloadAll() async {
        guard isLoggedIn else { return }
        errorMessage = nil
        isLoadingCrews = true
        defer { isLoadingCrews = false }

        do {
            async let loadedSubject = api().currentSubject()
            async let loadedCrews = api().listCrews()
            subject = try await loadedSubject
            crews = try await loadedCrews
            selectFirstCrewIfNeeded()
            if let selectedCrewId {
                await loadCrewDetail(crewId: selectedCrewId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectCrew(_ crewId: String) {
        selectedCrewId = crewId
        Task { await loadCrewDetail(crewId: crewId) }
    }

    func loadCrewDetail(crewId: String) async {
        guard isLoggedIn else { return }
        crewDetailLoadingIds.insert(crewId)
        crewDetailErrors[crewId] = nil
        defer { crewDetailLoadingIds.remove(crewId) }

        do {
            crewDetails[crewId] = try await api().crewDetail(crewId: crewId)
        } catch {
            crewDetailErrors[crewId] = error.localizedDescription
        }
    }

    func sendAnnouncement(crewId: String, summary: String) {
        Task {
            do {
                _ = try await api().sendAnnouncement(crewId: crewId, summary: summary)
                await loadCrewDetail(crewId: crewId)
            } catch {
                crewDetailErrors[crewId] = error.localizedDescription
            }
        }
    }

    func createSession(crewId: String, runnerKind: PendingBotCrewRunnerKind, taskBrief: String) {
        Task {
            do {
                _ = try await api().createSession(crewId: crewId, runnerKind: runnerKind, taskBrief: taskBrief)
                await loadCrewDetail(crewId: crewId)
            } catch {
                crewDetailErrors[crewId] = error.localizedDescription
            }
        }
    }

    func createChildCrew(parentCrewId: String, title: String) {
        Task {
            do {
                _ = try await api().createChildCrew(crewId: parentCrewId, title: title)
                await reloadAll()
            } catch {
                crewDetailErrors[parentCrewId] = error.localizedDescription
            }
        }
    }

    private func beginPolling(challenge: PendingBotMacDeviceLoginChallenge) {
        pollTask?.cancel()
        isPollingLogin = true
        let pollAPI = api(authToken: nil)
        pollTask = Task { [weak self] in
            for _ in 0..<120 {
                guard !Task.isCancelled else { return }
                do {
                    let response = try await pollAPI.pollDeviceLoginChallenge(
                        challengeId: challenge.challengeId,
                        secret: challenge.secret
                    )
                    await self?.handlePoll(response)
                    if response.deviceGrantToken != nil || response.status == "expired" || response.status == "rejected" {
                        return
                    }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    self?.handlePollError(error)
                    return
                }
            }
            self?.handlePollTimeout()
        }
    }

    private func handlePoll(_ response: PendingBotMacDeviceLoginPollResponse) async {
        loginStatus = response.status
        guard let token = response.deviceGrantToken, !token.isEmpty else {
            return
        }
        PendingBotMacTokenStore.save(token)
        authToken = token
        loginChallenge = nil
        loginStatus = "已登录"
        isPollingLogin = false
        await reloadAll()
    }

    private func handlePollError(_ error: Error) {
        isPollingLogin = false
        loginStatus = nil
        errorMessage = error.localizedDescription
    }

    private func handlePollTimeout() {
        isPollingLogin = false
        loginStatus = "登录挑战已超时，请重新创建"
    }

    private func selectFirstCrewIfNeeded() {
        let crewIds = Set(crews.map(\.id))
        if let selectedCrewId, crewIds.contains(selectedCrewId) {
            return
        }
        selectedCrewId = crews.first?.id
    }

    private func api(authToken overrideToken: String? = nil) -> PendingBotMacAPI {
        PendingBotMacAPI(baseURL: apiBaseURL, authToken: overrideToken ?? authToken)
    }

    private var apiBaseURL: URL {
        let trimmed = apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://api.pendingname.com")!
    }

    private var deviceName: String {
        Host.current().localizedName ?? "PendingBot Mac"
    }
}

private enum DefaultsKey {
    static let apiBaseURL = "PendingBotMac.apiBaseURL"
}
