import Foundation
import Supabase

/// One frame delivered over a realtime hub WebSocket. Two payload kinds
/// share the socket — a row change ("change") and a group voice call
/// lifecycle event ("voice_call") — and the variants below mirror the
/// edge wire shapes in `apps/edge/src/lib/realtime-publish.ts`.
enum HubFrame: Sendable {
    case change(HubChange)
    case voiceCall(VoiceCallFrame)
}

struct HubChange: Sendable {
    enum Op: String, Sendable { case insert, update, delete }
    let table: String
    let op: Op
    /// Row JSON in the same `[String: AnyJSON]` shape Supabase Realtime
    /// used to hand callers, so downstream decoding is unchanged.
    let record: [String: AnyJSON]
}

/// "voice_call" frames — emitted by RoomVoiceDO on every membership /
/// pending change and on final teardown. The conv-hub subscriber uses
/// these to drive the in-conv banner and ActiveVoiceCallStore.
struct VoiceCallFrame: Sendable {
    enum Event: String, Sendable { case state, ended }
    let event: Event
    let conversationId: String
    let startedAt: Double?      // ms epoch, absent on `.ended`
    let initiatorId: String?
    let participants: [Participant]
    let pending: [Participant]

    struct Participant: Sendable, Hashable {
        enum Kind: String, Sendable { case human, bot }
        let kind: Kind
        let id: String
    }
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
    private let onFrame: (HubFrame) -> Void

    private var task: URLSessionWebSocketTask?
    private var runLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var closed = false
    private var backoff = 1.0

    /// `path` is relative to the worker base, e.g.
    /// "v1/realtime-hub/conv/<id>" or "v1/realtime-hub/user".
    init(path: String, onFrame: @escaping (HubFrame) -> Void) {
        self.url = Self.wsURL(path: path)
        self.onFrame = onFrame
    }

    /// Convenience for callers that only care about row changes — keeps
    /// the common case in RealtimeManager from threading the union.
    convenience init(path: String, onChange: @escaping (HubChange) -> Void) {
        self.init(path: path) { frame in
            if case .change(let c) = frame { onChange(c) }
        }
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
              let raw = try? JSONDecoder().decode(RawFrame.self, from: data)
        else { return }
        switch raw.type {
        case "change":
            guard let table = raw.table,
                  let opRaw = raw.op, let op = HubChange.Op(rawValue: opRaw),
                  let record = raw.record
            else { return }
            onFrame(.change(HubChange(table: table, op: op, record: record)))
        case "voice_call":
            guard let convId = raw.conversation_id,
                  let eventRaw = raw.event,
                  let event = VoiceCallFrame.Event(rawValue: eventRaw)
            else { return }
            let participants = (raw.participants ?? []).compactMap { p -> VoiceCallFrame.Participant? in
                guard let k = VoiceCallFrame.Participant.Kind(rawValue: p.kind) else { return nil }
                return VoiceCallFrame.Participant(kind: k, id: p.id)
            }
            let pending = (raw.pending ?? []).compactMap { p -> VoiceCallFrame.Participant? in
                guard let k = VoiceCallFrame.Participant.Kind(rawValue: p.kind) else { return nil }
                return VoiceCallFrame.Participant(kind: k, id: p.id)
            }
            onFrame(.voiceCall(VoiceCallFrame(
                event: event,
                conversationId: convId,
                startedAt: raw.started_at,
                initiatorId: raw.initiator_id,
                participants: participants,
                pending: pending,
            )))
        default:
            // "ready" / "pong" / anything unrecognised — ignore.
            break
        }
    }

    private struct RawFrame: Decodable {
        let type: String
        // row-change fields
        let table: String?
        let op: String?
        let record: [String: AnyJSON]?
        // voice-call fields
        let event: String?
        let conversation_id: String?
        let started_at: Double?
        let initiator_id: String?
        let participants: [RawParticipant]?
        let pending: [RawParticipant]?
    }

    private struct RawParticipant: Decodable { let kind: String; let id: String }

    private static func wsURL(path: String) -> URL {
        var comps = URLComponents(
            url: HostedConfig.environment.workerURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        return comps.url!
    }
}
