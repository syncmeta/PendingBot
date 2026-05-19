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

    /// Bots whose tracks we've already subscribed to — guards against a
    /// re-subscribe (after add-bot) double-pulling an existing track.
    private var subscribedBotIds: Set<String> = []

    private var didSignalConnected = false

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
            print("[group-voice] start: configuring audio session")
            try configureAudioSession()
            attachLocalAudio()
            let offer = try await createOffer()
            try await peerConnection.setLocalDescription(offer)
            let offerSDP = await gatheredOfferSDP()
            print("[group-voice] offer ready — \(Self.sdpSummary(offerSDP))")

            let join = try await api.groupVoiceJoin(
                conversationId: conversationId,
                sdp: offerSDP,
            )
            sfuSessionId = join.session_id
            print("[group-voice] join ok — session=\(join.session_id) "
                + "bots=\(join.bots.count) — answer \(Self.sdpSummary(join.answer))")
            let answer = RTCSessionDescription(type: .answer, sdp: join.answer)
            try await peerConnection.setRemoteDescription(answer)
            print("[group-voice] applied SFU answer")
            delegate?.transport(self, didUpdateRoster: join.bots)
            if !join.bots.isEmpty {
                try await subscribe(to: join.bots)
            }
        } catch {
            print("[group-voice] start FAILED: \(error)")
            await delegate?.transport(
                self, didFailWith: .startupError(error.localizedDescription))
        }
    }

    /// One-line digest of an SDP for the device-console debug pass —
    /// audio m-line direction + ICE candidate count are what matter for
    /// "is this peer actually going to send/receive media".
    private static func sdpSummary(_ sdp: String) -> String {
        let lines = sdp.split(separator: "\n")
        let audio = lines.contains { $0.hasPrefix("m=audio") }
        let dir = ["sendrecv", "sendonly", "recvonly", "inactive"]
            .first { d in lines.contains { $0.contains("a=\(d)") } } ?? "?"
        let candidates = lines.filter { $0.contains("a=candidate") }.count
        return "audio=\(audio) dir=\(dir) candidates=\(candidates) bytes=\(sdp.count)"
    }

    /// Pull tracks for any bots not yet subscribed (used after add-bot).
    /// Re-fetches the roster from the worker so the new bot's SFU track
    /// info is known, then subscribes + renegotiates.
    func resyncRoster() async {
        do {
            let roster = try await api.groupVoiceRoster(conversationId: conversationId)
            delegate?.transport(self, didUpdateRoster: roster.bots)
            let fresh = roster.bots.filter { !subscribedBotIds.contains($0.botId) }
            if !fresh.isEmpty {
                try await subscribe(to: fresh)
            }
        } catch {
            // Non-fatal — the call keeps running; the new bot just isn't
            // audible until a successful re-sync.
        }
    }

    func hangUp() {
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

    private func subscribe(to bots: [GroupBotRosterEntry]) async throws {
        guard let sessionId = sfuSessionId, !bots.isEmpty else { return }
        let sub = try await api.groupVoiceSubscribe(
            conversationId: conversationId,
            sessionId: sessionId,
            tracks: bots,
        )
        for b in bots { subscribedBotIds.insert(b.botId) }

        // The SFU hands back an offer for the freshly-added recv tracks;
        // answer it on the same peer connection (BUNDLE — no new ICE).
        guard sub.requires_renegotiation, let offerSDP = sub.offer else {
            print("[group-voice] subscribe ok — no renegotiation needed")
            return
        }
        print("[group-voice] subscribe — renegotiating \(bots.count) bot track(s)")
        let offer = RTCSessionDescription(type: .offer, sdp: offerSDP)
        try await peerConnection.setRemoteDescription(offer)
        let answer = try await createAnswer()
        try await peerConnection.setLocalDescription(answer)
        try await api.groupVoiceRenegotiate(
            conversationId: conversationId,
            sessionId: sessionId,
            sdp: answer.sdp,
        )
        print("[group-voice] renegotiation answered")
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
        print("[group-voice] ICE connection state = \(newState.rawValue) "
            + "(2=connected 3=completed 4=failed 5=disconnected 6=closed)")
        switch newState {
        case .connected, .completed:
            Task { @MainActor [weak self] in
                guard let self, !self.didSignalConnected else { return }
                self.didSignalConnected = true
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
        print("[group-voice] ICE gathering state = \(newState.rawValue) "
            + "(0=new 1=gathering 2=complete)")
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
        conversationId: String,
        api: VoiceCallAPI,
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

/// Callback surface the transport feeds events back through.
/// `GroupCallSession` adopts it.
@MainActor
protocol GroupCallTransportDelegate: AnyObject {
    /// ICE connected — the human's mic + any subscribed bot audio is live.
    func transportDidConnect(_ t: GroupCallTransport)
    /// The bot roster changed (initial join, or a re-sync after add-bot).
    func transport(_ t: GroupCallTransport, didUpdateRoster bots: [GroupBotRosterEntry])
    /// The transport failed — startup error or a mid-call drop.
    func transport(
        _ t: GroupCallTransport,
        didFailWith reason: GroupCallSession.TerminateReason,
    ) async
}
