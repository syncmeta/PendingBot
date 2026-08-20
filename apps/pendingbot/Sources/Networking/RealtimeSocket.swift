import Foundation
import OSLog
import Supabase

/// Observable lifecycle of one hub socket. Surfaced by RealtimeManager as
/// `@Published` state so UI / diagnostics can see whether realtime is
/// actually connected instead of guessing from silence.
enum RealtimeConnectionState: Equatable, Sendable {
    case idle
    case connecting
    /// The hub acked the subscription with its "ready" frame.
    case connected
    /// The last attempt failed; the socket is waiting out the backoff.
    /// `failures` counts consecutive failures since the last ready frame.
    case retrying(failures: Int, lastError: String)
}

/// One frame delivered over a realtime hub WebSocket. Three payload
/// kinds share the socket — a row change ("change"), a group voice call
/// lifecycle event ("voice_call"), and a per-turn voice call cost
/// preview ("voice_cost") — and the variants below mirror the edge
/// wire shapes in `apps/edge/src/lib/realtime-publish.ts`.
enum HubFrame: Sendable {
    case change(HubChange)
    case voiceCall(VoiceCallFrame)
    case voiceCost(VoiceCostFrame)
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
    // `reconnecting` — the DO↔container media link dropped and the DO is
    // re-dialing + replaying room state. Transient: a later `state`
    // (resync ok) or `ended` (gave up) supersedes it.
    enum Event: String, Sendable { case state, ended, reconnecting }
    let event: Event
    let conversationId: String
    let startedAt: Double?      // ms epoch, absent on `.ended`
    let initiatorId: String?
    let participants: [Participant]
    let pending: [Participant]
    let diagnostics: GroupMediaDiagnostics?

    struct Participant: Sendable, Hashable {
        enum Kind: String, Sendable { case human, bot }
        let kind: Kind
        let id: String
    }
}

/// "voice_cost" frames — emitted by RealtimeMeterDO (1:1) and
/// RoomVoiceDO (group) after each settleTurn. Drives the live spend
/// display in CallView / GroupCallView. Values are **pnc_micros**: the
/// exact unit (and amount — no markup) the WalletDO debits, so the live
/// figure reconciles with the wallet drain on hang-up. `cumulativePncMicros`
/// is the authoritative running total for the session; `deltaPncMicros` is
/// the turn's increment (kept so callers can blink it if they want).
struct VoiceCostFrame: Sendable {
    let conversationId: String
    let sessionId: String
    let deltaPncMicros: Int
    let cumulativePncMicros: Int
    let atMs: Double
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
    private static let log = Logger.category("realtime")

    private let url: URL
    /// Short topic label for log lines, e.g. "user" or "conv/<id>".
    private let label: String
    private let onFrame: (HubFrame) -> Void
    /// Optional lifecycle observer — RealtimeManager forwards this into
    /// its `@Published` connection state.
    var onStateChange: ((RealtimeConnectionState) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var runLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var closed = false
    private var backoff = 1.0
    /// Consecutive failed connection attempts since the last ready frame.
    private var failureCount = 0

    /// `path` is relative to the worker base, e.g.
    /// "v1/realtime-hub/conv/<id>" or "v1/realtime-hub/user".
    init(path: String, onFrame: @escaping (HubFrame) -> Void) {
        self.url = Self.wsURL(path: path)
        self.label = path.replacingOccurrences(of: "v1/realtime-hub/", with: "")
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
        onStateChange?(.idle)
    }

    // MARK: - Internals

    private func connectLoop() async {
        while !closed && !Task.isCancelled {
            // connectOnce returns/throws when the socket drops; fall
            // through to a backed-off reconnect. Failures are never
            // swallowed silently — every one is logged with its reason
            // and reflected in the connection state.
            do {
                try await connectOnce()
            } catch {
                if closed || Task.isCancelled { break }
                failureCount += 1
                let reason = Self.describe(error)
                Self.log.error("[\(self.label, privacy: .public)] connection failed (attempt #\(self.failureCount)): \(reason, privacy: .public) — retrying in \(Int(self.backoff))s")
                onStateChange?(.retrying(failures: failureCount, lastError: reason))
            }
            if closed || Task.isCancelled { break }
            let delay = backoff
            backoff = min(backoff * 2, 30)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func connectOnce() async throws {
        // A fresh token each attempt so reconnects survive JWT expiry.
        // `auth.session` already auto-refreshes an expired session; if it
        // still fails (e.g. stale refresh token), try one explicit
        // refreshSession() before giving up this attempt — and say so
        // out loud either way, because "no token" is the classic silent
        // realtime killer (esp. macOS keychain paths).
        let token: String
        do {
            token = try await SupabaseStack.shared.auth.session.accessToken
        } catch {
            Self.log.warning("[\(self.label, privacy: .public)] auth token unavailable (\(Self.describe(error), privacy: .public)); trying refreshSession()")
            do {
                token = try await SupabaseStack.shared.auth.refreshSession().accessToken
            } catch {
                Self.log.error("[\(self.label, privacy: .public)] refreshSession failed — abandoning this attempt: \(Self.describe(error), privacy: .public)")
                throw error
            }
        }
        Self.log.debug("[\(self.label, privacy: .public)] connecting to \(self.url.absoluteString, privacy: .public)")
        onStateChange?(.connecting)
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

    /// Human-readable failure reason, with URLError codes spelled out so
    /// Console logs distinguish DNS / TLS / refused / timeout at a glance.
    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError(\(urlError.code.rawValue)) \(urlError.localizedDescription)"
        }
        return String(describing: error)
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
                diagnostics: raw.diagnostics,
            )))
        case "voice_cost":
            guard let convId = raw.conversation_id,
                  let sid = raw.session_id,
                  let delta = raw.delta_pnc_micros,
                  let cum = raw.cumulative_pnc_micros,
                  let at = raw.at_ms
            else { return }
            onFrame(.voiceCost(VoiceCostFrame(
                conversationId: convId,
                sessionId: sid,
                deltaPncMicros: delta,
                cumulativePncMicros: cum,
                atMs: at,
            )))
        case "ready":
            // The hub acked the subscription — the channel is live.
            Self.log.info("[\(self.label, privacy: .public)] subscribed (ready)")
            failureCount = 0
            backoff = 1.0
            onStateChange?(.connected)
        default:
            // "pong" / anything unrecognised — ignore.
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
        let diagnostics: GroupMediaDiagnostics?
        // voice-cost fields (pnc_micros — same unit/amount as the WalletDO debit)
        let session_id: String?
        let delta_pnc_micros: Int?
        let cumulative_pnc_micros: Int?
        let at_ms: Double?
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

/// Group voice-call media diagnostics carried on a `voice_call` hub frame.
/// Pure data (no UIKit/WebRTC) — lives here with the other hub wire types so
/// `RealtimeSocket` can stay cross-platform. The iOS-only call UI
/// (`CallDiagnostics.swift`) renders it; macOS never subscribes to voice frames
/// but the type must exist for the shared socket to compile.
struct GroupMediaDiagnostics: Sendable, Equatable, Decodable {
    let atMs: Double?
    let participants: [Participant]

    struct Participant: Sendable, Equatable, Decodable {
        let kind: String
        let id: String
        let speaking: Bool
        let audioLevel: Double?
        let source: String?
        let playoutDepthMs: Int?
        let underruns: Int?
        let maxGapMs: Int?
        let droppedOutputMs: Int?
        let inputLevel: Double?
        let inputFrames: Int?
        let quietFrames: Int?
        let realtimeKitConnected: Bool?
        let modelSessionReady: Bool?
    }
}
