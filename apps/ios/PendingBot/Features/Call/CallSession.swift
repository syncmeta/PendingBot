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

    /// Buffered transcript turns. Flushed to /transcripts on hangUp.
    /// Voice-call writes them as normal `messages` rows (metadata.source
    /// = 'voice_call'), so they participate in next-turn LLM context
    /// and Honcho sync via maybeRefreshMemory.
    var transcriptBuffer: [VoiceCallAPI.TranscriptTurn] = []

    // MARK: - Inputs

    let conversationId: String
    let botId: String
    let botDisplayName: String

    // MARK: - Dependencies

    private let api: VoiceCallAPI

    /// Concrete transport, picked by provider on `start()`.
    private var transport: CallTransport?

    /// Returned by the worker on /session. Stored so /usage and
    /// /transcripts can correlate against the same call.
    private(set) var sessionId: String?
    private(set) var providerId: String?
    private(set) var aliasId: String?

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

    /// Tap on the phone button enters here. Mints the OpenAI Realtime
    /// session via the worker, then spins up OpenAICallTransport. Errors
    /// surface through `phase = .terminated(...)` so UI can listen via
    /// the @Observable contract rather than try/catch.
    func start() async {
        guard phase == .idle else { return }
        phase = .connecting

        let resp: VoiceCallAPI.SessionResponse
        do {
            resp = try await api.createSession(
                conversationId: conversationId,
                transport: "webrtc",
            )
        } catch let err as VoiceCallError {
            phase = .terminated(translate(err))
            return
        } catch {
            phase = .terminated(.startupError(error.localizedDescription))
            return
        }
        sessionId = resp.session_id
        providerId = resp.provider_id
        aliasId = resp.alias_id

        guard let clientSecret = resp.client_secret?.value else {
            phase = .terminated(.startupError("session response missing client_secret"))
            return
        }
        let transport = OpenAICallTransport(
            clientSecret: clientSecret,
            model: resp.model,
            delegate: self,
        )
        self.transport = transport
        await transport.start()
    }

    func hangUp() async {
        await terminate(reason: .user)
    }

    private func terminate(reason: TerminateReason) async {
        guard !isTerminal(phase) else { return }
        phase = .hangingUp
        await transport?.hangUp()
        // Flush transcripts + audit end marker — fire-and-forget.
        if let sid = sessionId, !transcriptBuffer.isEmpty {
            let buffered = transcriptBuffer
            Task.detached { [api, conversationId] in
                _ = try? await api.uploadTranscripts(
                    .init(
                        session_id: sid,
                        conversation_id: conversationId,
                        turns: buffered,
                    ),
                )
            }
        }
        if let sid = sessionId {
            Task.detached { [api, conversationId] in
                try? await api.endSession(
                    sessionId: sid,
                    conversationId: conversationId,
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
    /// Append a transcript turn to the post-call upload buffer.
    func transport(_ t: CallTransport, didAppendTranscript turn: VoiceCallAPI.TranscriptTurn)
    /// Transport says we're done — either an error, remote close, or the
    /// upstream telling us the session is over.
    func transport(_ t: CallTransport, didFailWith reason: CallSession.TerminateReason) async
}

// MARK: - CallSession as delegate

extension CallSession: CallTransportDelegate {
    func transportDidConnect(_ t: CallTransport) {
        connectedAt = Date()
        phase = .connected
    }

    func transport(_ t: CallTransport, didObtainCallId callId: String) async {
        guard let sid = sessionId else { return }
        do {
            try await api.attach(
                sessionId: sid,
                conversationId: conversationId,
                callId: callId,
            )
        } catch {
            // Non-fatal — the call still works; only server-side metering
            // is lost for this call. The worker's 30-minute session cap
            // still bounds it. Nothing the user can act on, so swallow.
        }
    }

    func transport(_ t: CallTransport, didAppendTranscript turn: VoiceCallAPI.TranscriptTurn) {
        transcriptBuffer.append(turn)
    }

    func transport(_ t: CallTransport, didFailWith reason: CallSession.TerminateReason) async {
        await terminate(reason: reason)
    }
}
