import SwiftUI

/// Backing store for one crew session's remote-control detail page.
///
/// Data model (spec §详情页):
///   * durable truth = HTTP polls of the session row, its `session_events`
///     transcript, and its `permission_requests`. Non-terminal sessions poll
///     every 5s — this is the *primary* channel because PendingCrew Phase 1's
///     claude PTY path doesn't publish structured live state.
///   * live accelerator = the SessionProxyDO viewer WebSocket. `session.state`
///     frames update the banner instantly; a `permission.request` frame just
///     triggers an immediate permission-requests re-pull (the frame may carry
///     no id, so HTTP stays authoritative).
///
/// Steering (send_prompt), cancel, and permission decisions go out over the WS
/// (durably queued by the DO); permission decisions ALSO hit the HTTP decide
/// endpoint so the DB row is bound even if the runner is offline.
@MainActor
final class CrewSessionDetailStore: ObservableObject {
    @Published private(set) var session: CrewSessionRow?
    @Published private(set) var events: [SessionEventRow] = []
    @Published private(set) var permissionRequests: [PermissionRequestRowFull] = []
    @Published private(set) var liveState: SessionStateSnapshot?
    @Published var deciding: Set<String> = []
    @Published var loadError: String?

    let sessionId: String
    private var api: APIClient?
    private var proxy: SessionProxyClient?
    private var pollTask: Task<Void, Never>?
    private var wsTask: Task<Void, Never>?

    private static let pollInterval: Duration = .seconds(5)

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func configure(api: APIClient?) {
        self.api = api
    }

    /// Current status, preferring the live WS snapshot when present.
    var status: CrewSessionStatus {
        if let live = liveState?.status, !live.isEmpty {
            return CrewSessionStatus(raw: live)
        }
        return CrewSessionStatus(raw: session?.status ?? "queued")
    }

    var pendingPermissionRequests: [PermissionRequestRowFull] {
        permissionRequests.filter { ($0.status ?? "pending").lowercased() == "pending" }
    }

    // MARK: - Loading

    func loadAll() async {
        guard let api else { return }
        do {
            async let sessionsCall = api.listAllSessions()
            async let eventsCall = api.getSessionEvents(sessionId: sessionId)
            async let permsCall = api.listPermissionRequests(sessionId: sessionId)
            let (sessions, loadedEvents, perms) = try await (sessionsCall, eventsCall, permsCall)
            self.session = sessions.first { $0.id == sessionId }
            self.events = loadedEvents
            self.permissionRequests = perms
            self.loadError = nil
        } catch {
            self.loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func refreshDurable() async {
        guard let api else { return }
        if let sessions = try? await api.listAllSessions() {
            self.session = sessions.first { $0.id == sessionId }
        }
        if let loadedEvents = try? await api.getSessionEvents(sessionId: sessionId) {
            self.events = loadedEvents
        }
        await refreshPermissions()
    }

    func refreshPermissions() async {
        guard let api else { return }
        if let perms = try? await api.listPermissionRequests(sessionId: sessionId) {
            self.permissionRequests = perms
        }
    }

    // MARK: - Lifecycle

    func start() {
        startPolling()
        startWebSocket()
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        wsTask?.cancel(); wsTask = nil
        let proxy = self.proxy
        self.proxy = nil
        Task { await proxy?.close() }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                // Stop churning once the session is terminal — but keep the
                // last durable pull so a just-finished session settles.
                if await self.status.isActive == false { continue }
                await self.refreshDurable()
            }
        }
    }

    private func startWebSocket() {
        guard proxy == nil else { return }
        let client = SessionProxyClient(
            baseURL: HostedConfig.serverURL,
            sessionId: sessionId,
            tokenProvider: { try await SupabaseStack.shared.auth.session.accessToken }
        )
        self.proxy = client
        wsTask = Task { [weak self] in
            await client.connect()
            for await frame in await client.inbound {
                guard let self else { return }
                switch frame {
                case let .state(snapshot):
                    self.liveState = snapshot
                case .permissionRequest:
                    // Frame may not carry an id — re-pull the authoritative list.
                    await self.refreshPermissions()
                case .error, .subscribed, .unknown:
                    break
                }
            }
        }
    }

    // MARK: - Actions

    /// Steer the running agent with a free-text prompt (WS send_prompt).
    func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let proxy else { return }
        Task { await proxy.sendCommand(kind: "send_prompt", payload: ["text": .string(trimmed)]) }
    }

    /// Cancel the session (WS cancel; DO persists it to the mailbox).
    func cancel() {
        guard let proxy else { return }
        Task { await proxy.sendCommand(kind: "cancel") }
    }

    /// Approve/reject a permission request. Binds the DB row via the HTTP
    /// decide endpoint AND signals the runner over the WS (dual channel).
    func decide(_ request: PermissionRequestRowFull, approve: Bool) {
        guard let api else { return }
        deciding.insert(request.id)
        let decision: APIClient.PermissionRequestDecision = approve ? .approve : .reject
        Task { [weak self] in
            defer { Task { @MainActor in self?.deciding.remove(request.id) } }
            _ = try? await api.decidePermissionRequest(id: request.id, decision: decision)
            if let proxy = await self?.proxy {
                await proxy.sendPermissionDecision(
                    requestId: request.id,
                    decision: approve ? "approve" : "reject"
                )
            }
            await self?.refreshPermissions()
        }
    }

    /// Change the session's permission mode override (nil = inherit crew).
    func setPermissionMode(_ mode: String?) {
        guard let api else { return }
        Task { try? await api.setSessionPermissionMode(sessionId: sessionId, mode: mode) }
    }

    deinit {
        pollTask?.cancel()
        wsTask?.cancel()
    }
}
