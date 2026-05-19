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

    // MARK: - Inputs

    let conversationId: String
    let botId: String
    let botDisplayName: String

    // MARK: - Dependencies

    private let api: VoiceCallAPI

    /// Concrete transport, picked by provider on `start()`.
    private var transport: CallTransport?

    /// Returned by the worker on /session. Stored so /attach and
    /// /summary can correlate against the same call.
    private(set) var sessionId: String?
    private(set) var providerId: String?
    private(set) var aliasId: String?

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

        // User-selected transport. "auto" (default) walks the chain
        // direct WebRTC → Cloudflare TURN relay → WebSocket; the
        // explicit prefs pin to one transport.
        let transportPref =
            UserDefaults.standard.string(forKey: Self.transportDefaultsKey) ?? "auto"
        // User-selected voice model (cost vs quality).
        let modelPref =
            UserDefaults.standard.string(forKey: Self.modelDefaultsKey)
            ?? "gpt-realtime-2"

        let chain = Self.attemptChain(for: transportPref)
        for (idx, transportName) in chain.enumerated() {
            // The user can hang up mid-chain — bail before/after each
            // attempt rather than racing the next mint.
            if isTerminal(phase) { return }
            let isLast = idx == chain.count - 1
            let outcome = await attemptConnect(transportName: transportName, model: modelPref)
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
    private func attemptConnect(transportName: String, model: String) async -> AttemptOutcome {
        let resp: VoiceCallAPI.SessionResponse
        do {
            resp = try await api.createSession(
                conversationId: conversationId,
                transport: transportName,
                model: model,
            )
        } catch let err as VoiceCallError {
            return .failed(translate(err))
        } catch {
            return .failed(.startupError(error.localizedDescription))
        }
        sessionId = resp.session_id
        providerId = resp.provider_id
        aliasId = resp.alias_id

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

    /// UserDefaults key for the user's voice-model preference.
    /// An OpenAI realtime model id; absent → "gpt-realtime-2".
    static let modelDefaultsKey = "voice_model"

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

    func hangUp() async {
        await terminate(reason: .user)
    }

    private func terminate(reason: TerminateReason) async {
        guard !isTerminal(phase) else { return }
        let wasConnected = connectedAt != nil
        phase = .hangingUp
        // Unblock any in-flight connection attempt so start()'s chain
        // loop sees the terminal phase and stops minting transports.
        resolveAttempt(.failed(reason))

        // Closing-summary + teardown run in a background task so the UI
        // dismisses immediately. The task keeps `self` alive past the
        // CallView dismissal until the teardown finishes.
        let transport = self.transport
        let sid = sessionId
        Task { @MainActor in
            // Ask the realtime model for a short recap while the transport
            // is still open and the session still active. Only for a
            // voluntary hang up of a call that actually connected — a
            // failed/dead transport would just time out.
            var summary: String?
            if wasConnected, reason == .user, let transport {
                summary = await transport.requestSummary()
            }
            // Upload the recap before tearing down: closing the transport
            // can trip the server-side meter into ending the session,
            // which would 410 a later /summary.
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
            if let sid {
                try? await self.api.endSession(
                    sessionId: sid,
                    conversationId: self.conversationId,
                )
            }
        }
        phase = .terminated(reason)
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
}

// MARK: - CallSession as delegate

extension CallSession: CallTransportDelegate {
    func transportDidConnect(_ t: CallTransport) {
        // Ignore callbacks from a transport we've already abandoned
        // mid-chain — only the current attempt's transport may connect.
        guard t === transport else { return }
        connectedAt = Date()
        phase = .connected
        resolveAttempt(.connected)
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
}
