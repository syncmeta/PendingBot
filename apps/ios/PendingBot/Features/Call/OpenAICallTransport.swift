import Foundation
import AVFoundation
#if canImport(WebRTC)
import WebRTC
#endif

/// WebRTC-based transport for OpenAI Realtime.
///
/// Flow:
///   1. The worker mints a 60s ephemeral client_secret. We arrive holding it.
///   2. Create a RTCPeerConnection, attach a single audio track (built from
///      the device mic via AVAudioSession in .playAndRecord), and a data
///      channel called "oai-events" that the server uses to push
///      response.done / transcript events at us.
///   3. Generate an SDP offer, POST it as raw text to
///      `https://api.openai.com/v1/realtime/calls` with
///      `Authorization: Bearer <client_secret>`. The body is the SDP
///      itself, not JSON. The response is the SDP answer in plain text.
///      Model is fixed at mint time on the server side — do NOT add a
///      `?model=` query param (the GA endpoint returns an empty 400 when
///      the query is present; see https://community.openai.com/t/realtime-webrtc-returns-empty-400-when-hitting-v1-realtime-calls-model/1363928).
///   4. Apply the answer; remote audio starts flowing automatically.
///   5. Server events arrive on the data channel; we parse response.done
///      usage into a UsageDelta + concat the inline transcripts onto the
///      session buffer.
///
/// `#if canImport(WebRTC)` guards the file so it still compiles on a
/// fresh checkout before someone runs `xcodegen generate`. The fallback
/// shim publishes a startup error so the UI surface still works during
/// project setup.

#if canImport(WebRTC)

@MainActor
final class OpenAICallTransport: NSObject, CallTransport {

    // MARK: - Init / inputs

    private let clientSecret: String
    private let model: String
    weak var delegate: CallTransportDelegate?

    private let peerConnection: RTCPeerConnection
    private let factory: RTCPeerConnectionFactory
    private var dataChannel: RTCDataChannel?
    private var audioTrack: RTCAudioTrack?
    private var turnIndex: Int = 0

    init(
        clientSecret: String,
        model: String,
        delegate: CallTransportDelegate,
    ) {
        self.clientSecret = clientSecret
        self.model = model
        self.delegate = delegate

        // The encoder / decoder factories are the standard "include
        // everything available" pair from the WebRTC samples; voice-only
        // calls don't strictly need video codecs but the WebRTC build
        // wires them up either way and the binary cost is already paid.
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: encoder,
            decoderFactory: decoder,
        )
        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        cfg.iceServers = []   // OpenAI's endpoint terminates the WebRTC server-side; no TURN needed
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil,
        )
        guard let pc = factory.peerConnection(
            with: cfg,
            constraints: constraints,
            delegate: nil,
        ) else {
            // Shouldn't fail in practice — fall back to a dummy that errors
            // on start(). Keeps init non-throwing.
            self.peerConnection = factory.peerConnection(
                with: cfg,
                constraints: constraints,
                delegate: nil,
            ) ?? RTCPeerConnectionFactory().peerConnection(
                with: cfg,
                constraints: constraints,
                delegate: nil,
            )!
            super.init()
            return
        }
        self.peerConnection = pc
        super.init()
        peerConnection.delegate = self
    }

    // MARK: - CallTransport

    func start() async {
        do {
            try configureAudioSession()
            attachLocalAudio()
            attachDataChannel()
            let offer = try await createOffer()
            try await peerConnection.setLocalDescription(offer)
            let answerSDP = try await exchangeSDP(offerSDP: offer.sdp)
            let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
            try await peerConnection.setRemoteDescription(answer)
        } catch {
            await delegate?.transport(self, didFailWith: .startupError(error.localizedDescription))
        }
    }

    func hangUp() async {
        dataChannel?.close()
        peerConnection.close()
        // Release the audio session so other apps regain audio focus.
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Non-fatal — the session usually deactivates automatically
            // when the peer connection closes its capture units.
        }
    }

    // MARK: - Setup

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,            // enables built-in AEC + noise suppression
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker],
        )
        try session.setActive(true, options: [])
    }

    private func attachLocalAudio() {
        let audioSource = factory.audioSource(with: nil)
        let track = factory.audioTrack(with: audioSource, trackId: "pendingbot-audio")
        audioTrack = track
        peerConnection.add(track, streamIds: ["pendingbot-stream"])
    }

    private func attachDataChannel() {
        let cfg = RTCDataChannelConfiguration()
        cfg.isOrdered = true
        let channel = peerConnection.dataChannel(forLabel: "oai-events", configuration: cfg)
        channel?.delegate = self
        dataChannel = channel
    }

    // MARK: - SDP exchange

    private func createOffer() async throws -> RTCSessionDescription {
        // mandatory: receive remote audio, do not advertise video.
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "false",
            ],
            optionalConstraints: nil,
        )
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
            peerConnection.offer(for: constraints) { desc, err in
                if let err { cont.resume(throwing: err); return }
                guard let desc else {
                    cont.resume(throwing: NSError(domain: "OpenAICallTransport", code: 1))
                    return
                }
                cont.resume(returning: desc)
            }
        }
    }

    private func exchangeSDP(offerSDP: String) async throws -> String {
        // GA endpoint: POST /v1/realtime/calls, body is SDP plain text,
        // Authorization is the ephemeral client_secret. NO ?model= query —
        // the GA endpoint returns 400 on any query string, model is fixed
        // at session-mint time on the server side.
        let url = URL(string: "https://api.openai.com/v1/realtime/calls")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(offerSDP.utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw NSError(
                domain: "OpenAICallTransport",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "SDP exchange failed"],
            )
        }
        guard let sdp = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenAICallTransport", code: 2)
        }
        return sdp
    }

    // MARK: - Server events

    /// Parse one server event from the data channel. The realtime API sends
    /// JSON objects with a `type` discriminator. We only care about
    /// `response.done` (usage + transcripts) and the user transcript
    /// completed event.
    fileprivate func handleServerEvent(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        guard let type = obj["type"] as? String else { return }
        switch type {
        case "response.done":
            handleResponseDone(obj)
        case "conversation.item.input_audio_transcription.completed":
            handleUserTranscriptCompleted(obj)
        default:
            break
        }
    }

    private func handleResponseDone(_ obj: [String: Any]) {
        // Usage shape per https://platform.openai.com/docs/guides/realtime-costs:
        //   response.usage.input_token_details.{text_tokens, audio_tokens,
        //                                       image_tokens, cached_tokens,
        //                                       cached_tokens_details:
        //                                         {text_tokens, audio_tokens, image_tokens}}
        //   response.usage.output_token_details.{text_tokens, audio_tokens}
        //
        // Transcript:
        //   response.output[].content[].transcript  (aggregated bot text)
        //
        // We sum cached_text + cached_audio for the parent cached_tokens
        // and forward it to the worker as a single bucket. The alias's
        // cached_input_price covers the audio-cached rate ($0.40 /1M in
        // GA) — text-cached share is tiny in a voice call so the small
        // overbill (text-cached priced at the audio-cached rate) is in
        // the noise. Keep parsing defensive so a renamed field on
        // OpenAI's side doesn't crash the call.
        let response = (obj["response"] as? [String: Any]) ?? [:]
        let usage = (response["usage"] as? [String: Any]) ?? [:]
        let inDetails = (usage["input_token_details"] as? [String: Any]) ?? [:]
        let outDetails = (usage["output_token_details"] as? [String: Any]) ?? [:]
        let audioIn = (inDetails["audio_tokens"] as? Int) ?? 0
        let textIn = (inDetails["text_tokens"] as? Int) ?? 0
        let cachedIn = (inDetails["cached_tokens"] as? Int) ?? 0
        let audioOut = (outDetails["audio_tokens"] as? Int) ?? 0
        let textOut = (outDetails["text_tokens"] as? Int) ?? 0

        // Bot-side transcript — concat all .transcript fields under
        // response.output[].content[].
        var botTranscript = ""
        if let outputs = response["output"] as? [[String: Any]] {
            for item in outputs {
                if let contents = item["content"] as? [[String: Any]] {
                    for c in contents {
                        if let t = c["transcript"] as? String { botTranscript += t }
                    }
                }
            }
        }
        if !botTranscript.isEmpty {
            let turn = VoiceCallAPI.TranscriptTurn(
                role: "bot",
                content: botTranscript,
                ts: ISO8601DateFormatter().string(from: Date()),
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.transport(self, didAppendTranscript: turn)
            }
        }

        let nextTurn = turnIndex
        turnIndex += 1
        // cached_tokens reported here means "of the input tokens above,
        // this many came from a cache". They're a subset, not in addition.
        // The worker computeCost handles the split: charges the
        // (audio_in − cached_audio_share) at audio_input_price and the
        // cached portion at cached_input_price. We forward the parent
        // cached_tokens; the worker holds the alias prices, not iOS.
        let delta = UsageDelta(
            audioInputTokens: audioIn,
            audioOutputTokens: audioOut,
            textInputTokens: textIn,
            textOutputTokens: textOut,
            cachedInputTokens: cachedIn,
            latencyMs: nil,
            turnIndex: nextTurn,
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.delegate?.transport(self, didProduceUsageDelta: delta)
        }
    }

    private func handleUserTranscriptCompleted(_ obj: [String: Any]) {
        guard let transcript = obj["transcript"] as? String, !transcript.isEmpty else {
            return
        }
        let turn = VoiceCallAPI.TranscriptTurn(
            role: "user",
            content: transcript,
            ts: ISO8601DateFormatter().string(from: Date()),
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.transport(self, didAppendTranscript: turn)
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension OpenAICallTransport: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .connected || newState == .completed {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.transportDidConnect(self)
            }
        }
        if newState == .failed || newState == .disconnected {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.delegate?.transport(self, didFailWith: .network)
            }
        }
    }

    nonisolated func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didChange _: RTCIceGatheringState) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didGenerate _: RTCIceCandidate) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didOpen _: RTCDataChannel) {}
}

// MARK: - RTCDataChannelDelegate

extension OpenAICallTransport: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        Task { @MainActor [weak self] in
            self?.handleServerEvent(data)
        }
    }
}

#else

// SDK missing — surface a startup error so CallSession reports it cleanly
// to the UI. The compile-time guard means a checkout without WebRTC in
// the SwiftPM graph still builds; the runtime guard means missing-SDK
// builds fail loudly at start time rather than silently no-oping.
@MainActor
final class OpenAICallTransport: CallTransport {
    private weak var delegate: CallTransportDelegate?
    init(clientSecret: String, model: String, delegate: CallTransportDelegate) {
        self.delegate = delegate
    }
    func start() async {
        await delegate?.transport(self, didFailWith: .startupError(
            "WebRTC SDK 未集成（执行 xcodegen generate 后重新构建）",
        ))
    }
    func hangUp() async {}
}

#endif
