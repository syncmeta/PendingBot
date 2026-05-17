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
///      for the bot transcript only. Token usage is metered server-side
///      by RealtimeMeterDO over its sideband, not reported by the client.
///
/// `#if canImport(WebRTC)` guards the file so it still compiles on a
/// fresh checkout before the WebRTC SwiftPM package has resolved. The
/// fallback shim publishes a startup error so the UI surface still
/// works during project setup.

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
            let (answerSDP, callId) = try await exchangeSDP(offerSDP: offer.sdp)
            let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
            try await peerConnection.setRemoteDescription(answer)
            // Hand the call_id to the worker so its RealtimeMeterDO can
            // open the server-side sideband and meter this call.
            if let callId {
                await delegate?.transport(self, didObtainCallId: callId)
            }
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

    private func exchangeSDP(offerSDP: String) async throws -> (sdp: String, callId: String?) {
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
        // The Location header carries the call id (.../v1/realtime/calls/<id>);
        // works whether it's a path or an absolute URL.
        let callId = http.value(forHTTPHeaderField: "Location")
            .flatMap { $0.split(separator: "/").last.map(String.init) }
        return (sdp, callId)
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
        // We only extract the bot transcript here. Token usage is metered
        // server-side by RealtimeMeterDO over its sideband connection —
        // the client no longer reports usage (it could be forged).
        //
        // Transcript: response.output[].content[].transcript (aggregated).
        // Keep parsing defensive so a renamed field doesn't crash the call.
        let response = (obj["response"] as? [String: Any]) ?? [:]
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
        guard !botTranscript.isEmpty else { return }
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
            "WebRTC SDK 未集成（请在 Xcode 中 resolve SwiftPM 依赖后重新构建）",
        ))
    }
    func hangUp() async {}
}

#endif

// =============================================================================
// MARK: - WebSocket transport
// =============================================================================

/// WebSocket transport for OpenAI Realtime, relayed through the worker.
///
/// Picked when the user chooses the "websocket" transport — the
/// geo-fallback. It egresses from Cloudflare rather than the device, so
/// it works from regions where a direct iOS<->OpenAI WebRTC connection is
/// geo-blocked. iOS holds a WebSocket to the worker's `/v1/realtime/ws`;
/// `RealtimeMeterDO` bridges it to OpenAI and meters the call server-side.
///
/// Unlike `OpenAICallTransport`, the OS media stack does NOT carry the
/// audio here — this class captures the mic with `AVAudioEngine`, frames
/// PCM16 as base64 inside `input_audio_buffer.append` events, and plays
/// the `response.audio.delta` events it receives. The realtime audio
/// format is fixed at 24 kHz mono signed-16-bit (the worker's
/// `session.update` pins it). No WebRTC dependency — lives outside the
/// `#if canImport(WebRTC)` guard above.
///
/// NOTE: the audio capture/playback path needs on-device verification —
/// sample-rate conversion and engine wiring are easy to get subtly wrong
/// without a real device in the loop.
@MainActor
final class OpenAIWebSocketTransport: NSObject, CallTransport {

    private let wsURL: URL
    private let jwt: String
    weak var delegate: CallTransportDelegate?

    init(wsURL: URL, jwt: String, delegate: CallTransportDelegate) {
        self.wsURL = wsURL
        self.jwt = jwt
        self.delegate = delegate
        super.init()
    }

    private var task: URLSessionWebSocketTask?
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var didSignalConnected = false
    private var stopped = false

    /// OpenAI realtime PCM: 24 kHz, mono, signed 16-bit little-endian.
    private let openAIFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true,
    )!

    // MARK: CallTransport

    func start() async {
        do {
            print("[ws-voice] start: configuring audio session")
            try configureAudioSession()
            print("[ws-voice] start: opening socket", wsURL.absoluteString)
            openSocket()
            receiveNext()
            print("[ws-voice] start: starting audio engine")
            try startAudio()
            print("[ws-voice] start: done")
        } catch {
            print("[ws-voice] start FAILED:", error)
            await delegate?.transport(
                self, didFailWith: .startupError(error.localizedDescription))
        }
    }

    func hangUp() async {
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Non-fatal — usually deactivates once the engine stops.
        }
    }

    // MARK: Audio session

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,            // built-in AEC + noise suppression
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker],
        )
        try session.setActive(true, options: [])
        print("[ws-voice] audio session active; inputAvailable=",
              session.isInputAvailable,
              "recordPermission=", AVAudioApplication.shared.recordPermission.rawValue)
    }

    // MARK: WebSocket

    private func openSocket() {
        var req = URLRequest(url: wsURL)
        // The worker's requireSession middleware validates this JWT — same
        // gate as every other realtime route. No provider/CF credential
        // ever reaches the device.
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        let t = URLSession.shared.webSocketTask(with: req)
        task = t
        t.resume()
    }

    /// One-shot receive that re-arms itself — URLSessionWebSocketTask has
    /// no streaming API, you call `receive` again after each message.
    private func receiveNext() {
        task?.receive { [weak self] result in
            switch result {
            case .failure:
                Task { @MainActor [weak self] in
                    await self?.handleSocketClosed()
                }
            case .success(let message):
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    if case .string(let text) = message {
                        self.handleServerEvent(text)
                    }
                    self.receiveNext()
                }
            }
        }
    }

    private func handleSocketClosed() async {
        guard !stopped else { return }
        await delegate?.transport(self, didFailWith: .network)
    }

    // MARK: Audio capture (mic -> OpenAI)

    private func startAudio() throws {
        let input = engine.inputNode
        // Built-in voice processing (AEC/AGC) — the bot must not hear its
        // own playback looped back through the mic.
        try? input.setVoiceProcessingEnabled(true)

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: openAIFormat)

        // Tap with format: nil — the engine delivers buffers in the input
        // node's real native format. Building one converter up-front from
        // a pre-read format risked a zero/invalid format (engine not yet
        // started) → nil converter → silently zero audio sent. Build the
        // converter per buffer from that buffer's own format instead.
        let outFmt = openAIFormat
        input.installTap(onBus: 0, bufferSize: 4_096, format: nil) {
            [weak self] buffer, _ in
            let conv = AVAudioConverter(from: buffer.format, to: outFmt)
            let base64 = conv.flatMap { Self.encodeForOpenAI(buffer, using: $0) }
            print("[ws-voice] tap fired: frames=\(buffer.frameLength)",
                  "conv=\(conv != nil) encoded=\(base64 != nil)")
            guard let base64 else { return }
            Task { @MainActor [weak self] in
                self?.sendAudioFrame(base64)
            }
        }

        engine.prepare()
        try engine.start()
        playerNode.play()
        print("[ws-voice] engine started; mic input format =",
              input.inputFormat(forBus: 0))
    }

    /// Resample one mic buffer to 24 kHz mono PCM16, base64-encode it.
    /// `nonisolated static` so it runs on the audio tap thread without
    /// touching actor-isolated state.
    private nonisolated static func encodeForOpenAI(
        _ source: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
    ) -> String? {
        let outFormat = converter.outputFormat
        let ratio = outFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1
        guard
            let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
        else { return nil }

        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return source
        }
        guard err == nil, out.frameLength > 0, let channel = out.int16ChannelData
        else { return nil }
        let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: channel[0], count: byteCount).base64EncodedString()
    }

    private var sentFrameCount = 0

    private func sendAudioFrame(_ base64: String) {
        guard let task, !stopped else {
            print("[ws-voice] sendAudioFrame SKIPPED task=\(self.task != nil) stopped=\(stopped)")
            return
        }
        let payload = #"{"type":"input_audio_buffer.append","audio":""# + base64 + #""}"#
        task.send(.string(payload)) { err in
            if let err { print("[ws-voice] WS send error:", err) }
        }
        sentFrameCount += 1
        if sentFrameCount == 1 || sentFrameCount % 50 == 0 {
            print("[ws-voice] audio frames sent:", sentFrameCount)
        }
    }

    // MARK: Server events

    private func handleServerEvent(_ text: String) {
        guard
            let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else { return }

        switch type {
        case "session.created", "session.updated":
            if !didSignalConnected {
                didSignalConnected = true
                delegate?.transportDidConnect(self)
            }
        case "response.audio.delta":
            if let b64 = obj["delta"] as? String { enqueuePlayback(b64) }
        case "response.done":
            handleWSResponseDone(obj)
        case "conversation.item.input_audio_transcription.completed":
            handleWSUserTranscript(obj)
        case "error":
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String)
                ?? "realtime error"
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.delegate?.transport(self, didFailWith: .remoteError(msg))
            }
        default:
            break
        }
    }

    // MARK: Audio playback (OpenAI -> speaker)

    private func enqueuePlayback(_ base64: String) {
        guard
            let pcm = Data(base64Encoded: base64), !pcm.isEmpty,
            let buffer = Self.makeBuffer(pcm, format: openAIFormat)
        else { return }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        if !playerNode.isPlaying { playerNode.play() }
    }

    private nonisolated static func makeBuffer(
        _ pcm: Data,
        format: AVAudioFormat,
    ) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
        guard
            frames > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
            let channel = buffer.int16ChannelData
        else { return nil }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                channel[0].update(
                    from: base.assumingMemoryBound(to: Int16.self),
                    count: Int(frames))
            }
        }
        return buffer
    }

    // MARK: Transcript parsing

    private func handleWSResponseDone(_ obj: [String: Any]) {
        let response = (obj["response"] as? [String: Any]) ?? [:]
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
        guard !botTranscript.isEmpty else { return }
        delegate?.transport(
            self,
            didAppendTranscript: VoiceCallAPI.TranscriptTurn(
                role: "bot",
                content: botTranscript,
                ts: ISO8601DateFormatter().string(from: Date()),
            ),
        )
    }

    private func handleWSUserTranscript(_ obj: [String: Any]) {
        guard let transcript = obj["transcript"] as? String, !transcript.isEmpty else {
            return
        }
        delegate?.transport(
            self,
            didAppendTranscript: VoiceCallAPI.TranscriptTurn(
                role: "user",
                content: transcript,
                ts: ISO8601DateFormatter().string(from: Date()),
            ),
        )
    }
}
