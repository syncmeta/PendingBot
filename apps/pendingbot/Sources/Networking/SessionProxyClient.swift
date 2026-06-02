#if os(iOS)
import Foundation

/// The viewer-side WebSocket transport for T4.5 cross-device remote control on
/// PendingBot (iOS/iPad). Wraps a `URLSessionWebSocketTask` connected to the
/// session's `SessionProxyDO`
/// (`GET /v1/sessions/<id>/proxy/connect?role=viewer`).
///
/// It's the live counterpart to the HTTP `getCrewSessions` / `getCrewSessionEvents`
/// polling: where those mirror the durable transcript every 3s, this surfaces
/// the runner's low-latency `session.state` fan-out and lets the viewer send
/// `session.command` (e.g. `cancel`) back to whatever machine is running the
/// session. The durable poll remains the always-available source; this live
/// layer is best-effort decoration over it.
///
/// Auth: unlike the Mac runner (a long-lived `pdg_` device grant), an iOS
/// viewer authenticates with the user's Supabase JWT, which expires (~1h). So
/// the bearer is fetched fresh from `tokenProvider` on every (re)connect rather
/// than fixed at init — a reconnect that crosses a token refresh still carries a
/// valid bearer. The HTTP route authenticates it and stamps trusted facts onto
/// the DO upgrade (see `apps/edge/src/routes/session-proxy.ts`); the in-band
/// `subscribe.token` is omitted (defence-in-depth echo only, and the JWT
/// shouldn't be re-sent in-band).
///
/// Self-contained: only Foundation + the `SessionProxyProtocol` codec.
actor SessionProxyClient {
    /// Live state fan-out (`session.state` from the runner). A watching client
    /// consumes this to render progress the instant the runner publishes it,
    /// instead of waiting for the next durable poll.
    let states: AsyncStream<SessionStateSnapshot>

    private let baseURL: URL
    private let sessionId: String
    private let role: ProxyRole
    private let tokenProvider: @Sendable () async -> String?
    private let urlSession: URLSession
    private let statesContinuation: AsyncStream<SessionStateSnapshot>.Continuation

    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var closed = false
    private var subscribed = false

    /// Ping cadence + backoff bounds. Conservative — the DO is non-hibernating
    /// so an idle socket only needs an occasional liveness probe.
    private static let pingInterval: Duration = .seconds(20)
    private static let maxBackoff: Double = 30

    init(
        baseURL: URL,
        sessionId: String,
        role: ProxyRole = .viewer,
        token: @escaping @Sendable () async -> String?,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.sessionId = sessionId
        self.role = role
        self.tokenProvider = token
        self.urlSession = urlSession
        var stateCont: AsyncStream<SessionStateSnapshot>.Continuation!
        self.states = AsyncStream { stateCont = $0 }
        self.statesContinuation = stateCont
    }

    // MARK: - Public lifecycle

    /// Open the socket and start the receive + ping loops. Idempotent-ish: a
    /// second call while already connected is a no-op.
    func connect() async {
        guard !closed, task == nil else { return }
        await openSocket()
    }

    /// Viewer → DO: send a command to the session's runner (e.g. `cancel`).
    /// Best-effort over the live socket; the DO persists + queues it durably, so
    /// a momentary disconnect still reaches the runner on its next inbox pull.
    func sendCommand(kind: String, payload: [String: JSONValue]? = nil) {
        guard subscribed, let task else { return }
        send(.command(kind: kind, payload: payload), over: task)
    }

    /// Viewer → DO: approve/reject a pending permission request. Best-effort.
    func sendPermissionDecision(requestId: String, decision: String) {
        guard subscribed, let task else { return }
        send(.permissionDecision(requestId: requestId, decision: decision), over: task)
    }

    /// Tear down for good. Cancels loops + the socket and finishes `states`.
    /// After this the client will not reconnect.
    func close() {
        guard !closed else { return }
        closed = true
        subscribed = false
        pingLoop?.cancel(); pingLoop = nil
        receiveLoop?.cancel(); receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        statesContinuation.finish()
    }

    // MARK: - Socket bring-up

    private func openSocket() async {
        subscribed = false
        let token = await tokenProvider()
        guard !closed else { return }
        let request = Self.makeConnectRequest(
            baseURL: baseURL, sessionId: sessionId, role: role, token: token)
        let task = urlSession.webSocketTask(with: request)
        self.task = task
        task.resume()
        // Send the subscribe frame immediately; the DO acks with `subscribed`,
        // which flips us live. We don't echo the JWT in-band (the upgrade header
        // already carried it).
        send(subscribe: role, over: task)
        startReceiveLoop(on: task)
        startPingLoop(on: task)
    }

    private func startReceiveLoop(on task: URLSessionWebSocketTask) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self else { return }
                    if case let .string(text) = message {
                        await self.dispatch(SessionProxyInbound.parse(text), raw: text)
                    }
                    // Binary frames aren't part of this protocol — ignore.
                } catch {
                    await self?.handleDisconnect(task)
                    return
                }
            }
        }
    }

    private func startPingLoop(on task: URLSessionWebSocketTask) {
        pingLoop?.cancel()
        pingLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                if Task.isCancelled { return }
                let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    task.sendPing { error in cont.resume(returning: error == nil) }
                }
                if !ok {
                    await self?.handleDisconnect(task)
                    return
                }
            }
        }
    }

    // MARK: - Inbound routing

    /// Route one parsed inbound frame. `subscribed` flips us live; the live
    /// `session.state` fan-out (parsed as `.unknown` by `SessionProxyInbound`)
    /// is decoded and yielded on `states`; errors log; anything else is dropped.
    private func dispatch(_ frame: SessionProxyInbound, raw: String) {
        switch frame {
        case .subscribed:
            subscribed = true
            reconnectAttempts = 0
        case let .error(code, message):
            print("[session-proxy] server error frame: \(code) \(message)")
        case .unknown:
            if let snapshot = SessionStateSnapshot.parse(raw) {
                statesContinuation.yield(snapshot)
            }
            // Truly-unknown frames (incl. viewer permission.request, not yet
            // wired on iOS) are dropped silently.
        }
    }

    // MARK: - Reconnect

    /// Called when the live socket dies (receive error or failed ping). Drops
    /// the dead socket and, unless closed, schedules a backed-off reconnect.
    private func handleDisconnect(_ deadTask: URLSessionWebSocketTask) {
        // A stale loop from a previous socket can fire after we've moved on —
        // ignore unless this is still the current task.
        guard !closed, task === deadTask else { return }
        subscribed = false
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        pingLoop?.cancel(); pingLoop = nil
        receiveLoop?.cancel(); receiveLoop = nil

        let attempt = reconnectAttempts
        reconnectAttempts += 1
        let delay = min(Self.maxBackoff, pow(2, Double(attempt)))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.reconnectIfNeeded()
        }
    }

    private func reconnectIfNeeded() async {
        guard !closed, task == nil else { return }
        await openSocket()
    }

    // MARK: - Send helpers

    private func send(_ frame: SessionProxyViewerOutbound, over task: URLSessionWebSocketTask) {
        guard let data = try? frame.jsonData(),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error { print("[session-proxy] viewer send failed: \(error)") }
        }
    }

    /// The `subscribe` frame. `role` must match what the HTTP route authorized.
    /// The JWT is NOT echoed in-band (`token` omitted) — the upgrade header is
    /// the source of truth and we avoid re-shipping the bearer.
    private func send(subscribe role: ProxyRole, over task: URLSessionWebSocketTask) {
        let dict: [String: Any] = ["type": "subscribe", "role": role.rawValue]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error { print("[session-proxy] subscribe send failed: \(error)") }
        }
    }

    // MARK: - Request building (pure; matches the Mac SessionProxyClient)

    /// Build the WebSocket upgrade request: `http(s)` → `ws(s)`, the
    /// `/v1/sessions/<id>/proxy/connect` path, `?role=` query, and the bearer on
    /// `Authorization`. Pure + static so the wire shape is assertable without a
    /// socket.
    static func makeConnectRequest(
        baseURL: URL,
        sessionId: String,
        role: ProxyRole,
        token: String?
    ) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: components.scheme = "wss"
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/v1/sessions/\(sessionId)/proxy/connect"
        components.queryItems = [URLQueryItem(name: "role", value: role.rawValue)]

        var request = URLRequest(url: components.url!)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
#endif
