import Foundation
import AVFoundation
#if canImport(SpeechEngineToB)
import SpeechEngineToB
#endif

/// WebSocket-based transport for Doubao 端到端实时语音 (火山 SpeechEngineToB).
///
/// Architecture:
///   - The SDK opens its own WebSocket to wss://openspeech.bytedance.com.
///     The worker is not in the audio path — it only mints the static
///     console-issued AppId/AppKey/AccessToken triplet and ships them to
///     the device alongside the persona string.
///   - System prompt is passed via the SE_DIRECTIVE_START_ENGINE directive
///     in the `dialog` object. The exact field name (`system_role` vs
///     `prompt` vs `extra.system_prompt`) is documented in
///     https://www.volcengine.com/docs/6561/1594356 — verify on first run
///     by checking whether the bot uses the correct persona.
///   - Server events (SEDialogASRResponse, SEDialogChatResponse, ...) are
///     parsed for transcript text; no usage event is exposed by the SDK,
///     so we tick every 10s and POST `audio_seconds_billed` to /usage.
///
/// `#if canImport(SpeechEngineToB)` lets the file compile on a fresh
/// checkout before `pod install`. The fallback shim makes start() fail
/// with a clear "未运行 pod install" message.

#if canImport(SpeechEngineToB)

@MainActor
final class DoubaoCallTransport: NSObject, CallTransport, SpeechEngineDelegate {

    private let config: VoiceCallAPI.SessionResponse.DoubaoConfig
    weak var delegate: CallTransportDelegate?

    private var engine: SpeechEngine?
    private var tickerTask: Task<Void, Never>?
    private var lastTickAt: Date?
    private var turnIndex: Int = 0

    // Transcript assembly. The SDK emits partial-then-final segments via
    // SEDialogASRResponse / SEDialogChatResponse; we buffer the in-flight
    // text in these and flush on the corresponding *Ended event.
    private var pendingUserText: String = ""
    private var pendingBotText: String = ""

    init(
        config: VoiceCallAPI.SessionResponse.DoubaoConfig,
        delegate: CallTransportDelegate,
    ) {
        self.config = config
        self.delegate = delegate
        super.init()
    }

    // MARK: - CallTransport

    func start() async {
        do {
            try configureAudioSession()

            // App-lifecycle init. SDK docs say to call prepareEnvironment
            // once per process; doing it here is safe — it's idempotent.
            _ = SpeechEngine.prepareEnvironment()

            let engine = SpeechEngine()
            engine.createEngine(delegate: self)

            // Per 1597646: required configuration block. All literal keys
            // are SDK-exported constants; if SE_PARAMS_KEY_* identifiers
            // don't compile against your installed SDK version, the field
            // names may have rotated — check the version pinned in Podfile.
            engine.setStringParam(SE_DIALOG_ENGINE, forKey: SE_PARAMS_KEY_ENGINE_NAME_STRING)
            engine.setStringParam(config.app_id, forKey: SE_PARAMS_KEY_APP_ID_STRING)
            engine.setStringParam(config.app_key, forKey: SE_PARAMS_KEY_APP_KEY_STRING)
            engine.setStringParam(config.access_token, forKey: SE_PARAMS_KEY_APP_TOKEN_STRING)
            engine.setStringParam(config.resource_id, forKey: SE_PARAMS_KEY_RESOURCE_ID_STRING)
            engine.setStringParam(config.uid, forKey: SE_PARAMS_KEY_UID_STRING)
            engine.setStringParam(config.dialog_address, forKey: SE_PARAMS_KEY_DIALOG_ADDRESS_STRING)
            engine.setStringParam(config.dialog_uri, forKey: SE_PARAMS_KEY_DIALOG_URI_STRING)

            engine.setBoolParam(true, forKey: SE_PARAMS_KEY_ENABLE_AEC_BOOL)
            if let aecPath = Bundle.main.path(forResource: "aec", ofType: "model") {
                engine.setStringParam(aecPath, forKey: SE_PARAMS_KEY_AEC_MODEL_PATH_STRING)
            }

            let initRC = engine.initEngine()
            if initRC != SENoError {
                await delegate?.transport(self, didFailWith: .startupError("SDK initEngine \(initRC)"))
                return
            }
            self.engine = engine

            // StartSession payload. `bot_name` and the system prompt go
            // under `dialog`. Field name for the prompt is the open
            // question — see file header. Update here when confirmed.
            let payload: [String: Any] = [
                "dialog": [
                    "bot_name": config.bot_name,
                    "system_role": config.system_prompt,
                ]
            ]
            let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"
            let startRC = engine.sendDirective(SEDirectiveStartEngine, data: payloadString)
            if startRC != SENoError {
                await delegate?.transport(self, didFailWith: .startupError("StartEngine \(startRC)"))
                return
            }
            // The SDK will emit SEEngineStart on a callback thread when the
            // WebSocket is open — transportDidConnect fires there.
        } catch {
            await delegate?.transport(self, didFailWith: .startupError(error.localizedDescription))
        }
    }

    func hangUp() async {
        stopTicker()
        // SyncStop must not run on the SDK callback thread. Hop to a
        // detached task so we don't deadlock when called from inside a
        // delegate callback.
        await Task.detached { [engine] in
            _ = engine?.sendDirective(SEDirectiveSyncStopEngine)
            engine?.destroyEngine()
        }.value
        engine = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Audio session

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker],
        )
        try session.setActive(true, options: [])
    }

    // MARK: - Usage ticker

    private func startTicker() {
        guard tickerTask == nil else { return }
        lastTickAt = Date()
        let interval: UInt64 = 10_000_000_000   // 10s in ns
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self else { return }
                await self.fireTick()
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
        // Final delta — covers the slice from the last tick to now so
        // short calls don't drop the tail end of their accounting.
        if let last = lastTickAt {
            let now = Date()
            let elapsed = now.timeIntervalSince(last)
            if elapsed > 0.5 {
                let idx = turnIndex
                turnIndex += 1
                let delta = UsageDelta(
                    audioInputTokens: nil,
                    audioOutputTokens: nil,
                    textInputTokens: nil,
                    textOutputTokens: nil,
                    audioSecondsBilled: elapsed,
                    latencyMs: nil,
                    turnIndex: idx,
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.delegate?.transport(self, didProduceUsageDelta: delta)
                }
            }
            lastTickAt = nil
        }
    }

    private func fireTick() async {
        let now = Date()
        let last = lastTickAt ?? now
        let elapsed = now.timeIntervalSince(last)
        lastTickAt = now
        let idx = turnIndex
        turnIndex += 1
        let delta = UsageDelta(
            audioInputTokens: nil,
            audioOutputTokens: nil,
            textInputTokens: nil,
            textOutputTokens: nil,
            audioSecondsBilled: elapsed,
            latencyMs: nil,
            turnIndex: idx,
        )
        await delegate?.transport(self, didProduceUsageDelta: delta)
    }

    // MARK: - SpeechEngineDelegate

    nonisolated func onMessage(type: SEMessageType, andData data: Data) {
        let payload = String(data: data, encoding: .utf8) ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handleMessage(type: type, payload: payload)
        }
    }

    private func handleMessage(type: SEMessageType, payload: String) {
        switch type {
        case SEEngineStart:
            // Audio is flowing. Flip UI + kick the usage timer.
            startTicker()
            delegate?.transportDidConnect(self)

        case SEDialogASRResponse:
            // User-side ASR — accumulate partial text. We don't have a
            // clean "final" indicator in the partial stream; treat the
            // *Ended event below as the flush boundary.
            if let text = parseField(payload, key: "text") {
                pendingUserText = text  // SDK pushes the cumulative text
            }

        case SEDialogASREnded:
            if !pendingUserText.isEmpty {
                let turn = VoiceCallAPI.TranscriptTurn(
                    role: "user",
                    content: pendingUserText,
                    ts: ISO8601DateFormatter().string(from: Date()),
                )
                delegate?.transport(self, didAppendTranscript: turn)
                pendingUserText = ""
            }

        case SEDialogChatResponse:
            if let text = parseField(payload, key: "content") ?? parseField(payload, key: "text") {
                pendingBotText += text
            }

        case SEDialogChatEnded:
            if !pendingBotText.isEmpty {
                let turn = VoiceCallAPI.TranscriptTurn(
                    role: "bot",
                    content: pendingBotText,
                    ts: ISO8601DateFormatter().string(from: Date()),
                )
                delegate?.transport(self, didAppendTranscript: turn)
                pendingBotText = ""
            }

        case SEEngineError:
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.delegate?.transport(
                    self,
                    didFailWith: .remoteError(payload.isEmpty ? "豆包 SDK 报错" : payload),
                )
            }

        case SEEngineStop:
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.delegate?.transport(self, didFailWith: .network)
            }

        default:
            break
        }
    }

    /// Tiny JSON-field extractor — the SDK payloads are small JSON objects
    /// like `{"text":"...","is_final":true}`. We don't want to drag in a
    /// full Codable model per event type, so this regex-style snatch is
    /// good enough for the two string fields we care about (text /
    /// content). Returns nil on parse failure rather than throwing.
    private func parseField(_ payload: String, key: String) -> String? {
        guard
            let data = payload.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let v = obj[key] as? String
        else {
            return nil
        }
        return v
    }
}

#else

// SDK missing. Stub keeps the project building before the user runs
// `pod install`; tapping the phone with provider=doubao surfaces a
// dialog that points at the setup steps.
@MainActor
final class DoubaoCallTransport: CallTransport {
    private weak var delegate: CallTransportDelegate?
    init(
        config: VoiceCallAPI.SessionResponse.DoubaoConfig,
        delegate: CallTransportDelegate,
    ) {
        self.delegate = delegate
    }
    func start() async {
        await delegate?.transport(self, didFailWith: .startupError(
            "豆包 SDK 未集成（在 apps/ios 下跑 pod install 后重新打开 PendingBot.xcworkspace）",
        ))
    }
    func hangUp() async {}
}

#endif
