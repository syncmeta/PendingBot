#if os(iOS)
import Foundation

/// State container for a single OpenAI Realtime voice call. `CallView`
/// owns one of these and binds its UI to the @Observable state. The
/// underlying transport (OpenAICallTransport) handles WebRTC, audio
/// session, and SDP exchange, publishing events back through the
/// CallTransportDelegate protocol below.
///
/// All callbacks must hop to MainActor before mutating state since the UI
/// observes these via SwiftUI. Implementations should use `@MainActor`
/// on the class itself so the compiler enforces it.

import AVFoundation
import Combine
import Supabase

@MainActor
@Observable
final class CallSession {

    // MARK: - State

    /// Call lifecycle phases. UI maps these to the connect-/in-call-/hangup
    /// screens. `terminated` is a sink state — once entered, a new
    /// CallSession instance is required to start another call.
    enum Phase: Equatable, Sendable {
        case idle
        case connecting        // worker /session done, WebRTC/SDK opening
        case connected         // remote audio reached the device, UI flips to "in call"
        case hangingUp         // user tapped hang up, cleanup in flight
        case terminated(TerminateReason)
    }

    enum TerminateReason: Equatable, Sendable {
        case user              // user tapped hang up
        case botEnded          // the bot ended the call via its hang_up tool
        case noBalance         // pre-call balance gate (402 on /session)
        case network           // transport-level failure mid-call
        case remoteError(String)
        case regionUnsupported(country: String?, supportedURL: URL?)
        case startupError(String)
    }

    var phase: Phase = .idle

    /// Wall-clock seconds since the call connected (transport sets
    /// `connectedAt` when it sees first remote audio, CallView's timer
    /// formats this for the "通话 02:34" line). nil while connecting.
    var connectedAt: Date?

    /// Whether call audio is routed to the loudspeaker. Starts false —
    /// the call opens on the earpiece so the proximity sensor can blank
    /// the screen. CallView's speaker button toggles it.
    var isSpeakerOn: Bool = false

    /// Running spend for this call in **pnc_micros**, fed by `voice_cost`
    /// frames the edge meter publishes after every model turn. Same unit and
    /// amount (no markup) as the WalletDO debit, so it reconciles with the
    /// wallet drain. 0 until the first turn settles — the view hides the
    /// figure while it's still 0 so a stale "0" doesn't sit next to the timer.
    var cumulativePncMicros: Int = 0

    /// Best-effort live transport diagnostics shown behind the gauge
    /// button on the call screen.
    var diagnostics = CallDiagnosticsSnapshot()

    // MARK: - Inputs

    let conversationId: String
    let botId: String
    let botDisplayName: String

    // MARK: - Dependencies

    private let api: VoiceCallAPI

    /// Concrete transport, picked by provider on `start()`.
    private var transport: CallTransport?

    /// Region-specific ringback tone played while we negotiate. Stays
    /// silent past `.connected` and tears down on terminate. nil before
    /// the first start() — keeps the unit tests from spinning the audio
    /// engine for nothing.
    private var ringback: RingbackPlayer?

    /// Conv-hub subscription that feeds `cumulativePncMicros` from server-side
    /// per-turn voice_cost events. Held so terminate() can drop it.
    private var costSubscription: ConvSubscriptionToken?

    /// CallKit handle for this call — set once at start(), cleared on
    /// terminate. nil means CallKit either declined the request or the
    /// call hasn't started yet. Tracked here so we can both call
    /// endCall() on the manager and ignore the manager's own system-end
    /// callback once we initiated the teardown ourselves.
    private var callKitUUID: UUID?

    /// Returned by the worker on /session. Stored so /attach and
    /// /summary can correlate against the same call.
    private(set) var sessionId: String?

    /// WebRTC only — the ephemeral client_secret from /session. Forwarded
    /// to /attach so the server-side sideband can authenticate with it.
    private var webrtcClientSecret: String?

    init(
        conversationId: String,
        botId: String,
        botDisplayName: String,
        api: VoiceCallAPI,
    ) {
        self.conversationId = conversationId
        self.botId = botId
        self.botDisplayName = botDisplayName
        self.api = api
    }

    // MARK: - Lifecycle

    /// Tap on the phone button enters here. Walks the transport chain
    /// for the user's preference, minting a fresh OpenAI Realtime
    /// session per attempt and falling through to the next transport
    /// when one fails to connect. Errors surface through
    /// `phase = .terminated(...)` so UI can listen via the @Observable
    /// contract rather than try/catch.
    func start() async {
        guard phase == .idle else { return }
        phase = .connecting

        // Register the call with CallKit before anything else — gives
        // iOS the system-call surface (Control Center indicator,
        // lock-screen UI, call-history row) for the rest of this call.
        // We keep audio-session ownership in CallSession; CallKit's
        // didActivate is a no-op for us. If CallKit declines (rare —
        // user already on a real phone call), the in-app UI still
        // works; we just won't have system controls.
        callKitUUID = CallKitManager.shared.startOutgoingCall(
            displayName: botDisplayName,
            onSystemEnd: { [weak self] in
                // CallKit-driven hang up (lock-screen end button etc).
                // Drop our UUID first so terminate() doesn't try to
                // call back into CallKit and trip the request that
                // just resolved.
                guard let self else { return }
                self.callKitUUID = nil
                Task { @MainActor in await self.terminate(reason: .user) }
            },
        )

        // Prime the audio session and start the regional ringback tone
        // before the network round-trip — the user just tapped "phone",
        // dead silence for 1–2 s while SDP exchanges feels broken. The
        // transport's own configureAudioSession is idempotent on these
        // same parameters; calling it twice is harmless.
        //
        // When CallKit accepted the outgoing call it owns audio-session
        // activation: AVAudioEngine output started before
        // `provider(_:didActivate:)` lands gets silently suppressed by
        // the system, so wait for that callback before kicking the
        // ringback engine. If CallKit declined (rare — user on a real
        // PSTN call), activate the session ourselves and start ringback
        // immediately like before.
        primeAudioSessionCategoryForRingback()
        let player = RingbackPlayer()
        ringback = player
        if let uuid = callKitUUID {
            CallKitManager.shared.onAudioSessionActivated(uuid) { [weak self] in
                guard let self else { return }
                // Bail if start() already moved past .connecting (user
                // hung up, or transport beat us to it).
                guard self.phase == .connecting else { return }
                self.ringback?.start()
            }
        } else {
            activatePrimedAudioSession()
            player.start()
        }

        // Subscribe to the conv hub for `voice_cost` previews. The edge
        // meter publishes one of these after every turn's settleTurn,
        // and the UI reads `cumulativePncMicros` off this observer.
        await subscribeToCost()

        // User-selected transport. "auto" (default) walks the chain
        // direct WebRTC → Cloudflare TURN relay → WebSocket; the
        // explicit prefs pin to one transport. The voice model is no
        // longer a client choice — the worker resolves it from the
        // conversation / bot settings.
        let transportPref =
            UserDefaults.standard.string(forKey: Self.transportDefaultsKey) ?? "auto"

        let chain = Self.attemptChain(for: transportPref)
        for (idx, transportName) in chain.enumerated() {
            // The user can hang up mid-chain — bail before/after each
            // attempt rather than racing the next mint.
            if isTerminal(phase) { return }
            let isLast = idx == chain.count - 1
            let outcome = await attemptConnect(transportName: transportName)
            if isTerminal(phase) { return }
            switch outcome {
            case .connected:
                // transportDidConnect already flipped phase; transport retained.
                return
            case .failed(let reason):
                // A balance shortfall won't be cured by another
                // transport — stop the chain immediately.
                if case .noBalance = reason {
                    phase = .terminated(reason)
                    return
                }
                if isLast {
                    phase = .terminated(reason)
                    return
                }
                // else: fall through to the next transport in the chain
            }
        }
    }

    /// Ordered list of `/session` transport values to try for a given
    /// user preference. "auto" walks direct WebRTC → Cloudflare TURN
    /// relay → WebSocket; explicit prefs pin to a single transport.
    private static func attemptChain(for pref: String) -> [String] {
        switch pref {
        case "webrtc": return ["webrtc"]
        case "turn": return ["webrtc_turn"]
        case "websocket": return ["websocket"]
        default: return ["webrtc", "webrtc_turn", "websocket"]   // "auto"
        }
    }

    /// Outcome of one connection attempt within the transport chain.
    private enum AttemptOutcome {
        case connected
        case failed(TerminateReason)
    }

    /// Continuation for the in-flight attempt. Resolved exactly once by
    /// transportDidConnect (success), the first transport failure, or
    /// the connect timeout. nil outside the connecting window — a
    /// failure with no pending continuation and phase == .connected is
    /// a real mid-call drop, not a chain fall-through.
    private var attemptContinuation: CheckedContinuation<AttemptOutcome, Never>?

    /// How long to wait for a transport to reach `connected` before
    /// abandoning the attempt and trying the next (nanoseconds).
    private static let attemptTimeoutNanos: UInt64 = 15_000_000_000

    /// Mint a session for `transportName` and drive that transport until
    /// it connects or fails. On failure the transport + worker session
    /// are torn down so the chain can cleanly try the next one.
    private func attemptConnect(transportName: String) async -> AttemptOutcome {
        let resp: VoiceCallAPI.SessionResponse
        do {
            resp = try await api.createSession(
                conversationId: conversationId,
                transport: transportName,
            )
        } catch let err as VoiceCallError {
            return .failed(translate(err))
        } catch {
            return .failed(.startupError(error.localizedDescription))
        }
        sessionId = resp.session_id

        let transport: CallTransport
        if resp.transport == "websocket" {
            guard let wsURL = Self.websocketURL(path: resp.ws_path) else {
                return .failed(.startupError("session response missing ws_path"))
            }
            let jwt: String
            do {
                jwt = try await SupabaseStack.shared.auth.session.accessToken
            } catch {
                return .failed(.startupError("auth token unavailable"))
            }
            webrtcClientSecret = nil
            transport = OpenAIWebSocketTransport(wsURL: wsURL, jwt: jwt, delegate: self)
        } else {
            // "webrtc" and "webrtc_turn" both ride OpenAICallTransport;
            // the only difference is the ICE servers (empty → direct,
            // populated → relay through Cloudflare TURN).
            guard let clientSecret = resp.client_secret?.value else {
                return .failed(.startupError("session response missing client_secret"))
            }
            webrtcClientSecret = clientSecret
            transport = OpenAICallTransport(
                clientSecret: clientSecret,
                model: resp.model,
                iceServers: resp.ice_servers ?? [],
                delegate: self,
            )
        }
        self.transport = transport

        let outcome: AttemptOutcome = await withCheckedContinuation { cont in
            attemptContinuation = cont
            Task { @MainActor in
                await transport.start()
            }
            // Guard against a transport that neither connects nor reports
            // a failure (e.g. ICE silently stalls).
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.attemptTimeoutNanos)
                self?.resolveAttempt(.failed(.network))
            }
        }

        if case .failed = outcome {
            // Abandon this attempt before the next: drop the transport
            // reference first so its teardown callbacks (delivered via
            // the delegate) are recognised as stale and ignored.
            if self.transport === transport { self.transport = nil }
            await transport.hangUp()
            if let sid = sessionId {
                try? await api.endSession(sessionId: sid, conversationId: conversationId)
            }
            sessionId = nil
            webrtcClientSecret = nil
        }
        return outcome
    }

    /// Resume the in-flight attempt continuation exactly once.
    private func resolveAttempt(_ outcome: AttemptOutcome) {
        guard let cont = attemptContinuation else { return }
        attemptContinuation = nil
        cont.resume(returning: outcome)
    }

    /// UserDefaults key for the user's voice-transport preference.
    /// "auto" | "webrtc" | "turn" | "websocket"; absent → "auto".
    static let transportDefaultsKey = "voice_transport"

    /// Build the wss:// URL for the WebSocket transport from the worker
    /// base + the relative ws_path the /session response handed back.
    private static func websocketURL(path: String?) -> URL? {
        guard
            let path,
            var comps = URLComponents(
                url: HostedConfig.environment.workerURL,
                resolvingAgainstBaseURL: false)
        else { return nil }
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        if let q = path.firstIndex(of: "?") {
            comps.path = String(path[..<q])
            comps.percentEncodedQuery = String(path[path.index(after: q)...])
        } else {
            comps.path = path
        }
        return comps.url
    }

    /// Configure the AVAudioSession in the same `.playAndRecord` /
    /// `.voiceChat` shape the transport will use, so the ringback tone
    /// and the call audio share one session without a category flip
    /// (which would briefly cut audio when the transport takes over).
    /// Bluetooth options match transport's; speaker route is left at
    /// the default (earpiece) so the proximity sensor can blank the
    /// screen. **Does not** call `setActive(true)` — when CallKit
    /// accepted the call, the system owns activation and an early
    /// setActive races CallKit and gets the engine muted.
    private func primeAudioSessionCategoryForRingback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP],
            )
        } catch {
            // Swallow — a missing ringback is a degraded experience,
            // not a fatal one; the transport will re-attempt session
            // setup and surface its own error if that also fails.
        }
    }

    /// Activate the audio session ourselves. Only called when CallKit
    /// declined the outgoing-call request; under CallKit the system
    /// activates via `provider(_:didActivate:)` and us doing it first
    /// silently suppresses the AVAudioEngine output.
    private func activatePrimedAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
    }

    /// Stop and release the ringback player if it's still running.
    /// Called when the transport reaches `.connected` (the bot's audio
    /// is the new "ringing stopped, talking now" cue) and on terminate.
    private func stopRingback() {
        ringback?.stop()
        ringback = nil
    }

    /// Subscribe to the conversation hub so `voice_cost` frames feed
    /// `cumulativePncMicros`. We only need the cost slot — leave the other
    /// callbacks as the no-op defaults so this subscriber doesn't get
    /// woken up for every message in the conv.
    private func subscribeToCost() async {
        let token = await RealtimeManager.shared.startConvChannel(
            conversationId: conversationId,
            onMessage: { _ in },
            onVoiceCost: { [weak self] cost in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // The server sends a monotonically growing cumulative
                    // for the session; clamp regressions out so a stale
                    // late-arriving frame can't make the number drop.
                    if cost.cumulativePncMicros > self.cumulativePncMicros {
                        self.cumulativePncMicros = cost.cumulativePncMicros
                    }
                }
            },
        )
        costSubscription = token
    }

    private func unsubscribeFromCost() async {
        if let token = costSubscription {
            costSubscription = nil
            await RealtimeManager.shared.stopConvChannel(token)
        }
    }

    /// Flip the audio route between the earpiece and the loudspeaker.
    /// `overrideOutputAudioPort` acts on the shared AVAudioSession, so it
    /// works regardless of which transport (WebRTC / WebSocket) is live.
    func toggleSpeaker() {
        let on = !isSpeakerOn
        do {
            try AVAudioSession.sharedInstance()
                .overrideOutputAudioPort(on ? .speaker : .none)
            isSpeakerOn = on
        } catch {
            // Non-fatal — leave the route and the flag as they were.
        }
    }

    func hangUp() async {
        await terminate(reason: .user)
    }

    private func terminate(reason: TerminateReason) async {
        guard !isTerminal(phase) else { return }
        let wasConnected = connectedAt != nil
        phase = .hangingUp
        // The ringback is normally cleared on transportDidConnect; if we
        // never connected (startup error, region-blocked, balance gate)
        // it's still spinning here, so stop it before the teardown
        // races the audio session.
        stopRingback()
        // Drop the cost subscription so we stop holding the conv socket
        // for a session that's over.
        await unsubscribeFromCost()
        // Unblock any in-flight connection attempt so start()'s chain
        // loop sees the terminal phase and stops minting transports.
        resolveAttempt(.failed(reason))

        let transport = self.transport
        let sid = sessionId
        // Hold the CallKit handle for the deferred end below; clear our
        // copy now so a re-entrant terminate can't double-end it. nil when
        // CallKit drove the teardown (onSystemEnd already cleared it).
        let uuid = callKitUUID
        callKitUUID = nil

        // Failed / never-connected ends (startup error, region-blocked,
        // balance gate, network drop) skip the disconnect tone and
        // dismiss immediately; their teardown runs in the background.
        guard wasConnected, reason == .user || reason == .botEnded else {
            phase = .terminated(reason)
            Task { @MainActor in
                await transport?.hangUp()
                if let uuid { CallKitManager.shared.endCall(uuid: uuid) }
                if let sid {
                    try? await self.api.endSession(
                        sessionId: sid,
                        conversationId: self.conversationId,
                    )
                }
            }
            return
        }

        // Genuine hang up of a connected call (user tapped end, or the bot
        // ended via its hang_up tool). Play the regional disconnect tone
        // now, on the still-active call audio session, and keep the call
        // screen up (hang-up button dimmed) for the tone's full duration
        // before dismissing — like the system phone app. Teardown follows
        // dismissal, so neither the transport nor CallKit deactivates the
        // session out from under the tone.
        let tone = HangupTonePlayer()
        tone.start()
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(HangupTonePlayer.playbackSeconds * 1_000_000_000),
            )
            tone.stop()
            phase = .terminated(reason)

            // Recap over the still-open transport, then tear down. Upload
            // before closing the transport: closing it can trip the
            // server-side meter into ending the session, which would 410
            // a later /summary.
            let summary = await transport?.requestSummary()
            if let sid, let summary, !summary.isEmpty {
                _ = try? await self.api.uploadSummary(
                    .init(
                        session_id: sid,
                        conversation_id: self.conversationId,
                        summary: summary,
                    ),
                )
            }
            await transport?.hangUp()
            if let uuid { CallKitManager.shared.endCall(uuid: uuid) }
            if let sid {
                try? await self.api.endSession(
                    sessionId: sid,
                    conversationId: self.conversationId,
                )
            }
        }
    }

    private func isTerminal(_ p: Phase) -> Bool {
        switch p {
        case .terminated, .hangingUp: return true
        default: return false
        }
    }

    /// Map a network-layer VoiceCallError to a TerminateReason the UI
    /// can pattern-match on.
    private func translate(_ err: VoiceCallError) -> TerminateReason {
        switch err {
        case .regionUnsupported(let country, _, let url):
            return .regionUnsupported(country: country, supportedURL: url)
        case .insufficientBalance:
            return .noBalance
        case .routeUnavailable(let m), .other(_, _, let m):
            return .remoteError(m)
        case .sessionExpired:
            return .remoteError("session expired")
        }
    }
}

// MARK: - Transport interface

/// Implemented by OpenAICallTransport. Holds the audio plumbing (WebRTC
/// peer + AVAudioSession) and reports back through CallTransportDelegate.
/// Pulled out as a protocol so the call session and tests don't bind to
/// the WebRTC type directly.
@MainActor
protocol CallTransport: AnyObject {
    func start() async
    /// Ask the realtime model for a short text recap of the call, then
    /// return it. Sends a final text-only `response.create` and waits
    /// (bounded) for the model's reply. nil if the transport isn't in a
    /// state to produce one. Call before `hangUp()`.
    func requestSummary() async -> String?
    func hangUp() async
}

/// Callback surface implementations use to feed events back into the
/// session. CallSession itself adopts this protocol.
@MainActor
protocol CallTransportDelegate: AnyObject {
    /// Transport connected and remote audio is flowing.
    func transportDidConnect(_ t: CallTransport)
    /// WebRTC transport: the iOS<->OpenAI SDP exchange produced a call_id.
    /// CallSession forwards it to the worker (POST /v1/realtime/attach) so
    /// the server-side meter (RealtimeMeterDO) can open its sideband.
    func transport(_ t: CallTransport, didObtainCallId callId: String) async
    /// Transport says we're done — either an error, remote close, or the
    /// upstream telling us the session is over.
    func transport(_ t: CallTransport, didFailWith reason: CallSession.TerminateReason) async
    /// Best-effort live stats from the active transport.
    func transport(_ t: CallTransport, didUpdateDiagnostics snapshot: CallDiagnosticsSnapshot)
    /// The bot invoked its `hang_up` tool — end the call as if the user
    /// had tapped hang up (the closing recap still runs).
    func transportRequestsHangUp(_ t: CallTransport) async
}

// MARK: - CallSession as delegate

extension CallSession: CallTransportDelegate {
    func transportDidConnect(_ t: CallTransport) {
        // Ignore callbacks from a transport we've already abandoned
        // mid-chain — only the current attempt's transport may connect.
        guard t === transport else { return }
        // Bot audio is about to start — silence the ringback first so
        // the two don't briefly overlap.
        stopRingback()
        connectedAt = Date()
        phase = .connected
        resolveAttempt(.connected)
        // Flip the CallKit state from "dialing" to "in call" so the
        // lock-screen timer starts and Control Center shows green.
        if let uuid = callKitUUID {
            CallKitManager.shared.reportCallConnected(uuid: uuid)
        }
    }

    func transport(_ t: CallTransport, didObtainCallId callId: String) async {
        guard t === transport else { return }
        guard let sid = sessionId, let secret = webrtcClientSecret else { return }
        do {
            try await api.attach(
                sessionId: sid,
                conversationId: conversationId,
                callId: callId,
                clientSecret: secret,
            )
        } catch {
            // Non-fatal — the call still works; only server-side metering
            // is lost for this call. The worker's 30-minute session cap
            // still bounds it. Nothing the user can act on, so swallow.
        }
    }

    func transportRequestsHangUp(_ t: CallTransport) async {
        guard t === transport else { return }
        // Only meaningful for a live call — a hang_up during the connect
        // chain (no pending attempt, not yet connected) is ignored.
        guard phase == .connected else { return }
        await terminate(reason: .botEnded)
    }

    func transport(_ t: CallTransport, didFailWith reason: CallSession.TerminateReason) async {
        guard t === transport else { return }
        if attemptContinuation != nil {
            // Failure inside the connecting window — let the transport
            // chain decide whether to fall through to the next one.
            resolveAttempt(.failed(reason))
            return
        }
        // No pending attempt: only a genuinely connected call drops here.
        // A stray callback during fallback teardown (phase still
        // .connecting) is ignored.
        guard phase == .connected else { return }
        await terminate(reason: reason)
    }

    func transport(_ t: CallTransport, didUpdateDiagnostics snapshot: CallDiagnosticsSnapshot) {
        guard t === transport else { return }
        diagnostics = snapshot
    }
}
#endif
