import Foundation
import AVFoundation
#if canImport(WebRTC)
import WebRTC
#endif

/// WebRTC transport for a group voice call, against the Cloudflare
/// Realtime SFU. Parallels `OpenAICallTransport` (1:1) but the peer is
/// the SFU, not OpenAI — and the SDP exchange is brokered by the worker
/// rather than posted to a provider directly.
///
/// Flow (the worker is the SFU's "Backend Server"):
///   1. Create an RTCPeerConnection, attach the mic, build an offer.
///   2. Wait for ICE gathering (the offer is posted whole over HTTP —
///      no trickle), then POST it to `/voice/join`. The worker creates
///      the human's SFU session, publishes the mic, and answers.
///   3. Apply the SFU answer → the mic is live.
///   4. POST `/voice/subscribe` with the bot roster. The SFU adds those
///      remote tracks and replies with a renegotiation offer.
///   5. Answer that offer and POST it to `/voice/renegotiate` → bot
///      audio starts flowing. WebRTC plays remote tracks automatically.
///
/// `#if canImport(WebRTC)` guards the file so a fresh checkout (before
/// the WebRTC SwiftPM package resolves) still compiles; the fallback
/// shim publishes a startup error.

#if canImport(WebRTC)

@MainActor
final class GroupCallTransport: NSObject {

    // MARK: - Inputs

    private let conversationId: String
    private let api: VoiceCallAPI
    weak var delegate: GroupCallTransportDelegate?

    private let peerConnection: RTCPeerConnection
    private let factory: RTCPeerConnectionFactory
    private var audioTrack: RTCAudioTrack?

    /// SFU session id the worker created for this human on /join. Needed
    /// for every later /subscribe and /renegotiate round-trip.
    private(set) var sfuSessionId: String?

    /// SFU tracks (bots + peers) already subscribed to — keyed
    /// "sessionId|trackName" — so a re-sync never double-pulls a track.
    private var subscribedKeys: Set<String> = []

    private var didSignalConnected = false

    /// Periodically re-syncs the roster so peers (and bots) who join
    /// after us still get subscribed — and thus heard.
    private var rosterTimer: Timer?

    /// Resolved when ICE gathering completes (or times out) so the whole
    /// offer SDP — candidates included — can be posted in one HTTP call.
    private var iceGatheringContinuation: CheckedContinuation<Void, Never>?

    /// How long to wait for ICE gathering before posting the offer anyway.
    private static let iceGatherTimeoutNanos: UInt64 = 3_000_000_000

    init(
        conversationId: String,
        api: VoiceCallAPI,
        delegate: GroupCallTransportDelegate,
    ) {
        self.conversationId = conversationId
        self.api = api
        self.delegate = delegate

        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: encoder,
            decoderFactory: decoder,
        )
        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        // The SFU terminates WebRTC server-side and reflects its own
        // candidates in the answer — no STUN/TURN needed client-side.
        cfg.iceServers = []
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil,
        )
        self.peerConnection = factory.peerConnection(
            with: cfg,
            constraints: constraints,
            delegate: nil,
        )!
        super.init()
        peerConnection.delegate = self
    }

    // MARK: - Lifecycle

    func start() async {
        do {
            try configureAudioSession()
            attachLocalAudio()
            let offer = try await createOffer()
            try await peerConnection.setLocalDescription(offer)
            let offerSDP = await gatheredOfferSDP()

            let join = try await api.groupVoiceJoin(
                conversationId: conversationId,
                sdp: offerSDP,
            )
            sfuSessionId = join.session_id
            let answer = RTCSessionDescription(type: .answer, sdp: join.answer)
            try await peerConnection.setRemoteDescription(answer)
            delegate?.transport(
                self,
                didUpdateRoster: GroupRosterSnapshot(
                    bots: join.bots,
                    humans: join.humans,
                    pending: join.pending ?? [],
                ),
            )
            try await subscribeToRoster(bots: join.bots, humans: join.humans)
        } catch {
            await delegate?.transport(
                self, didFailWith: .startupError(error.localizedDescription))
        }
    }

    /// Re-fetch the roster and subscribe to anything new — bots added
    /// mid-call, and peers who joined after us. Runs on a timer (so late
    /// joiners get heard) and on demand after add-bot.
    func resyncRoster() async {
        do {
            let roster = try await api.groupVoiceRoster(conversationId: conversationId)
            delegate?.transport(
                self,
                didUpdateRoster: GroupRosterSnapshot(
                    bots: roster.bots,
                    humans: roster.humans,
                    pending: roster.pending ?? [],
                ),
            )
            try await subscribeToRoster(bots: roster.bots, humans: roster.humans)
        } catch {
            // Non-fatal — the call keeps running; a new participant just
            // isn't audible until a later re-sync succeeds.
        }
    }

    /// Re-sync the roster every few seconds so a peer who joins the call
    /// after us still gets subscribed — otherwise we'd never hear them.
    private func startRosterPolling() {
        rosterTimer?.invalidate()
        rosterTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in await self?.resyncRoster() }
        }
    }

    func hangUp() {
        rosterTimer?.invalidate()
        rosterTimer = nil
        peerConnection.close()
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Non-fatal — usually deactivates when the peer connection
            // tears down its capture units.
        }
    }

    // MARK: - Subscribe / renegotiate

    private func trackKey(_ session: String, _ track: String) -> String {
        "\(session)|\(track)"
    }

    /// Subscribe to every bot + peer-human track we're not already
    /// pulling, so the caller hears the whole room. Our own published
    /// mic track is skipped (a session can't subscribe to itself).
    private func subscribeToRoster(
        bots: [GroupBotRosterEntry],
        humans: [GroupHumanRosterEntry],
    ) async throws {
        guard let sessionId = sfuSessionId else { return }
        var refs: [(session: String, track: String)] = []
        for b in bots
        where !subscribedKeys.contains(trackKey(b.sfuSessionId, b.sfuTrackName)) {
            refs.append((b.sfuSessionId, b.sfuTrackName))
        }
        for h in humans where h.sfuSessionId != sessionId
            && !subscribedKeys.contains(trackKey(h.sfuSessionId, h.sfuTrackName)) {
            refs.append((h.sfuSessionId, h.sfuTrackName))
        }
        guard !refs.isEmpty else { return }

        let sub = try await api.groupVoiceSubscribe(
            conversationId: conversationId,
            sessionId: sessionId,
            tracks: refs,
        )
        for r in refs { subscribedKeys.insert(trackKey(r.session, r.track)) }

        // The SFU hands back an offer for the freshly-added recv tracks;
        // answer it on the same peer connection (BUNDLE — no new ICE).
        guard sub.requires_renegotiation, let offerSDP = sub.offer else { return }
        let offer = RTCSessionDescription(type: .offer, sdp: offerSDP)
        try await peerConnection.setRemoteDescription(offer)
        let answer = try await createAnswer()
        try await peerConnection.setLocalDescription(answer)
        try await api.groupVoiceRenegotiate(
            conversationId: conversationId,
            sessionId: sessionId,
            sdp: answer.sdp,
        )
    }

    // MARK: - Setup

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,            // built-in AEC + noise suppression
            options: [.allowBluetooth, .allowBluetoothA2DP],
        )
        try session.setActive(true, options: [])
    }

    private func attachLocalAudio() {
        let audioSource = factory.audioSource(with: nil)
        let track = factory.audioTrack(with: audioSource, trackId: "pendingbot-group-audio")
        audioTrack = track
        peerConnection.add(track, streamIds: ["pendingbot-group-stream"])
    }

    // MARK: - SDP

    private func createOffer() async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil,
        )
        return try await withCheckedThrowingContinuation { cont in
            peerConnection.offer(for: constraints) { desc, err in
                if let err { cont.resume(throwing: err); return }
                guard let desc else {
                    cont.resume(throwing: NSError(domain: "GroupCallTransport", code: 1))
                    return
                }
                cont.resume(returning: desc)
            }
        }
    }

    private func createAnswer() async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil,
        )
        return try await withCheckedThrowingContinuation { cont in
            peerConnection.answer(for: constraints) { desc, err in
                if let err { cont.resume(throwing: err); return }
                guard let desc else {
                    cont.resume(throwing: NSError(domain: "GroupCallTransport", code: 2))
                    return
                }
                cont.resume(returning: desc)
            }
        }
    }

    /// The local offer SDP once ICE gathering has finished — the offer is
    /// posted whole over HTTP, so the candidates must be in it. Bounded
    /// so a stalled gather doesn't block the join indefinitely.
    private func gatheredOfferSDP() async -> String {
        if peerConnection.iceGatheringState != .complete {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                iceGatheringContinuation = cont
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: Self.iceGatherTimeoutNanos)
                    self?.resolveIceGathering()
                }
            }
        }
        return peerConnection.localDescription?.sdp ?? ""
    }

    private func resolveIceGathering() {
        guard let cont = iceGatheringContinuation else { return }
        iceGatheringContinuation = nil
        cont.resume()
    }
}

// MARK: - RTCPeerConnectionDelegate

extension GroupCallTransport: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState,
    ) {
        switch newState {
        case .connected, .completed:
            Task { @MainActor [weak self] in
                guard let self, !self.didSignalConnected else { return }
                self.didSignalConnected = true
                self.startRosterPolling()
                self.delegate?.transportDidConnect(self)
            }
        case .failed, .closed:
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.delegate?.transport(self, didFailWith: .network)
            }
        case .disconnected:
            // Transient on a flaky link — but when it's the SFU tearing
            // the room down (someone ended the call) it never recovers.
            // Treat a sustained disconnect as the call having ended.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self else { return }
                switch self.peerConnection.iceConnectionState {
                case .disconnected, .failed, .closed:
                    await self.delegate?.transport(self, didFailWith: .network)
                default:
                    break
                }
            }
        default:
            break
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState,
    ) {
        if newState == .complete {
            Task { @MainActor [weak self] in
                self?.resolveIceGathering()
            }
        }
    }

    nonisolated func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didGenerate _: RTCIceCandidate) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didOpen _: RTCDataChannel) {}
}

#else

// SDK missing — surface a startup error so GroupCallSession reports it
// cleanly. The compile-time guard keeps a WebRTC-less checkout building.
@MainActor
final class GroupCallTransport {
    private weak var delegate: GroupCallTransportDelegate?
    private(set) var sfuSessionId: String?
    init(
        conversationId _: String,
        api _: VoiceCallAPI,
        delegate: GroupCallTransportDelegate,
    ) {
        self.delegate = delegate
    }
    func start() async {
        await delegate?.transport(self, didFailWith: .startupError(
            "WebRTC SDK 未集成（请在 Xcode 中 resolve SwiftPM 依赖后重新构建）",
        ))
    }
    func resyncRoster() async {}
    func hangUp() {}
}

#endif

// MARK: - Transport delegate

/// Full snapshot the transport hands back on roster updates — joined
/// bots and humans, plus participants invited but not yet joined.
struct GroupRosterSnapshot: Sendable, Equatable {
    let bots: [GroupBotRosterEntry]
    let humans: [GroupHumanRosterEntry]
    let pending: [GroupPendingEntry]
}

/// Callback surface the transport feeds events back through.
/// `GroupCallSession` adopts it.
@MainActor
protocol GroupCallTransportDelegate: AnyObject {
    /// ICE connected — the human's mic + any subscribed bot audio is live.
    func transportDidConnect(_ t: GroupCallTransport)
    /// The roster (joined + pending) changed.
    func transport(_ t: GroupCallTransport, didUpdateRoster snapshot: GroupRosterSnapshot)
    /// The transport failed — startup error or a mid-call drop.
    func transport(
        _ t: GroupCallTransport,
        didFailWith reason: GroupCallSession.TerminateReason,
    ) async
}
