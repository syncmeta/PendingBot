// VENDORED from apps/pendingcrew/Sources/Mac/LocalRunner/SessionProxyClient.swift
// @ 4087018333705de981bf6227593c8c5d04115734
//
// Viewer-side adaptation for PendingBot (iOS + macOS remote control / monitor).
// Changes vs the PendingCrew runner original:
//   * dropped `#if os(macOS)` — dual-platform, pure Foundation.
//   * viewer role only: subscribes as `.viewer`, consumes `session.state` +
//     `permission.request` fan-out over `inbound`, sends `session.command` /
//     `permission.decision` up. It never publishes runner state.
//   * per-connect token: the Supabase JWT refreshes, so instead of pinning a
//     token at init we take an async `tokenProvider` and fetch a fresh bearer
//     on every (re)connect. The WS upgrade `Authorization` header is what the
//     route authenticates.
// Keep-alive ping + capped-exponential-backoff reconnect are copied verbatim.
import Foundation

/// The viewer-side WebSocket transport for T4.5 cross-device remote control.
/// Connects to a session's `SessionProxyDO`
/// (`GET /v1/sessions/<id>/proxy/connect?role=viewer`), streams live frames out
/// on `inbound`, and offers send helpers for commands + permission decisions.
actor SessionProxyClient {
    /// Viewer-relevant inbound frames (state / permission.request / error).
    /// The `subscribed` ack is handled internally. Consumed on the MainActor.
    let inbound: AsyncStream<SessionProxyViewerInbound>

    private let baseURL: URL
    private let sessionId: String
    private let tokenProvider: @Sendable () async throws -> String
    private let session: URLSession
    private let inboundContinuation: AsyncStream<SessionProxyViewerInbound>.Continuation

    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var closed = false
    private var subscribed = false

    private static let pingInterval: Duration = .seconds(20)
    private static let maxBackoff: Double = 30

    init(
        baseURL: URL,
        sessionId: String,
        tokenProvider: @escaping @Sendable () async throws -> String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.sessionId = sessionId
        self.tokenProvider = tokenProvider
        self.session = session
        var cont: AsyncStream<SessionProxyViewerInbound>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        self.inboundContinuation = cont
    }

    // MARK: - Public lifecycle

    /// Open the socket and start the receive + ping loops. Idempotent-ish.
    func connect() {
        guard !closed, task == nil else { return }
        Task { await self.openSocket() }
    }

    /// Viewer → DO: send a command to the session's runner (e.g. `cancel`,
    /// `send_prompt`). Best-effort over the live socket; the DO persists +
    /// queues it durably so a momentary disconnect still reaches the runner.
    func sendCommand(kind: String, payload: [String: JSONValue]? = nil) {
        guard subscribed, let task else { return }
        send(.command(kind: kind, payload: payload), over: task)
    }

    /// Viewer → DO: approve/reject a pending permission request. Best-effort.
    func sendPermissionDecision(requestId: String, decision: String) {
        guard subscribed, let task else { return }
        send(.permissionDecision(requestId: requestId, decision: decision), over: task)
    }

    /// Tear down for good. Cancels loops + the socket and finishes `inbound`.
    func close() {
        guard !closed else { return }
        closed = true
        subscribed = false
        pingLoop?.cancel(); pingLoop = nil
        receiveLoop?.cancel(); receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        inboundContinuation.finish()
    }

    // MARK: - Socket bring-up

    private func openSocket() async {
        guard !closed, task == nil else { return }
        subscribed = false
        // Fetch a fresh bearer per connect — the Supabase JWT refreshes.
        let token: String?
        do {
            token = try await tokenProvider()
        } catch {
            print("[session-proxy] token fetch failed: \(error)")
            scheduleReconnect()
            return
        }
        guard !closed, task == nil else { return }
        let request = Self.makeConnectRequest(baseURL: baseURL, sessionId: sessionId, token: token)
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        send(.subscribe(role: .viewer, token: token), over: task)
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
                        await self.dispatch(SessionProxyViewerInbound.parse(text))
                    }
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

    private func dispatch(_ frame: SessionProxyViewerInbound) {
        switch frame {
        case .subscribed:
            subscribed = true
            reconnectAttempts = 0
        case .state, .permissionRequest, .error:
            inboundContinuation.yield(frame)
        case let .unknown(raw):
            print("[session-proxy] ignoring unknown inbound frame: \(raw)")
        }
    }

    // MARK: - Reconnect

    private func handleDisconnect(_ deadTask: URLSessionWebSocketTask) {
        guard !closed, task === deadTask else { return }
        subscribed = false
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        pingLoop?.cancel(); pingLoop = nil
        receiveLoop?.cancel(); receiveLoop = nil
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let attempt = reconnectAttempts
        reconnectAttempts += 1
        let delay = min(Self.maxBackoff, pow(2, Double(attempt)))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            await self.reconnectIfNeeded()
        }
    }

    private func reconnectIfNeeded() async {
        guard !closed, task == nil else { return }
        await openSocket()
    }

    // MARK: - Send helper

    private func send(_ frame: SessionProxyViewerOutbound, over task: URLSessionWebSocketTask) {
        guard let data = try? frame.jsonData(),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error { print("[session-proxy] viewer send failed: \(error)") }
        }
    }

    // MARK: - Request building (pure; unit tested)

    /// Build the WebSocket upgrade request: `http(s)` → `ws(s)`, the
    /// `/v1/sessions/<id>/proxy/connect` path, `?role=viewer`, and the Supabase
    /// JWT bearer on `Authorization`. Pure + static so a test can assert the
    /// wire shape without opening a socket.
    static func makeConnectRequest(
        baseURL: URL,
        sessionId: String,
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
        components.queryItems = [URLQueryItem(name: "role", value: ProxyRole.viewer.rawValue)]

        var request = URLRequest(url: components.url!)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
