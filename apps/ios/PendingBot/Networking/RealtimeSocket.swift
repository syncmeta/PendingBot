import Foundation
import Supabase

/// One row change delivered over a realtime hub WebSocket. Mirrors the
/// edge `RealtimeChange` wire shape (apps/edge/src/lib/realtime-publish.ts).
struct HubChange: Sendable {
    enum Op: String, Sendable { case insert, update, delete }
    let table: String
    let op: Op
    /// Row JSON in the same `[String: AnyJSON]` shape Supabase Realtime
    /// used to hand callers, so downstream decoding is unchanged.
    let record: [String: AnyJSON]
}

/// WebSocket client for one RealtimeHubDO topic — the replacement for a
/// Supabase `RealtimeChannelV2`.
///
/// Connects to an edge `/v1/realtime-hub/*` endpoint, authenticates with
/// the Supabase JWT on the upgrade request, auto-reconnects with
/// exponential backoff, and keeps the link warm with a periodic "ping"
/// text frame (the DO auto-responds "pong" without waking from
/// hibernation). Receive-only: the hub never expects client frames other
/// than the keepalive.
///
/// Best-effort, like the channel it replaces — a dropped socket simply
/// reconnects, and consumers refetch over HTTP on view/foreground. No
/// missed-event replay.
@MainActor
final class RealtimeSocket {
    private let url: URL
    private let onChange: (HubChange) -> Void

    private var task: URLSessionWebSocketTask?
    private var runLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var closed = false
    private var backoff = 1.0

    /// `path` is relative to the worker base, e.g.
    /// "v1/realtime-hub/conv/<id>" or "v1/realtime-hub/user".
    init(path: String, onChange: @escaping (HubChange) -> Void) {
        self.url = Self.wsURL(path: path)
        self.onChange = onChange
    }

    func start() {
        guard runLoop == nil else { return }
        runLoop = Task { [weak self] in
            await self?.connectLoop()
        }
    }

    func stop() {
        closed = true
        pingLoop?.cancel(); pingLoop = nil
        runLoop?.cancel(); runLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - Internals

    private func connectLoop() async {
        while !closed && !Task.isCancelled {
            // connectOnce returns (throws) when the socket drops; fall
            // through to a backed-off reconnect.
            try? await connectOnce()
            if closed || Task.isCancelled { break }
            let delay = backoff
            backoff = min(backoff * 2, 30)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func connectOnce() async throws {
        // A fresh token each attempt so reconnects survive JWT expiry.
        let token = try await SupabaseStack.shared.auth.session.accessToken
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: req)
        task = ws
        ws.resume()
        startPing()

        // Receive loop — runs until the socket errors or is closed.
        while !closed && !Task.isCancelled {
            let message = try await ws.receive()
            backoff = 1.0   // a delivered frame means the link is healthy
            switch message {
            case .string(let text):
                handle(text)
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) { handle(text) }
            @unknown default:
                break
            }
        }
    }

    private func startPing() {
        pingLoop?.cancel()
        pingLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25 * 1_000_000_000)
                guard let self, !self.closed, let task = self.task else { return }
                try? await task.send(.string("ping"))
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONDecoder().decode(HubFrame.self, from: data),
              frame.type == "change",
              let table = frame.table,
              let opRaw = frame.op, let op = HubChange.Op(rawValue: opRaw),
              let record = frame.record
        else { return }   // "ready" / "pong" / anything unrecognised — ignore
        onChange(HubChange(table: table, op: op, record: record))
    }

    private struct HubFrame: Decodable {
        let type: String
        let table: String?
        let op: String?
        let record: [String: AnyJSON]?
    }

    private static func wsURL(path: String) -> URL {
        var comps = URLComponents(
            url: HostedConfig.environment.workerURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        return comps.url!
    }
}
