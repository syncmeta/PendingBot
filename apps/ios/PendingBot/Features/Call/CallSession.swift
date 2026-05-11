import Foundation

/// Provider-agnostic shape for a single voice call. `CallView` owns one
/// of these and binds its UI to the @Observable state. Each provider
/// (OpenAI Realtime, Doubao SpeechEngineToB) implements the lifecycle —
/// start / hangUp / transcript collection / per-turn usage report — and
/// publishes state changes through the published properties.
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
        case noBalance         // worker /usage returned can_continue=false
        case network           // transport-level failure mid-call
        case remoteError(String)
        case regionUnsupported(country: String?, supportedURL: URL?)
        case startupError(String)
    }

    var phase: Phase = .idle

    /// Cumulative PND drained from the user's balance for this call.
    /// Updated optimistically by the transport on each turn, then
    /// reconciled with worker authoritative value on the /usage response.
    var sessionCostPND: Int = 0

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
    private(set) var provider: VoiceCallAPI.Provider?

    init(
        conversationId: String,
        botId: String,
        botDisplayName: String,
        api: VoiceCallAPI = VoiceCallAPI(),
    ) {
        self.conversationId = conversationId
        self.botId = botId
        self.botDisplayName = botDisplayName
        self.api = api
    }

    // MARK: - Lifecycle

    /// Tap on the phone button enters here. Mints credentials via the
    /// worker, then picks the matching transport. Throws via terminating
    /// the session (UI listens via phase rather than try/catch propagation
    /// — keeps the call buttons free of error-throwing initializers).
    func start() async {
        guard phase == .idle else { return }
        phase = .connecting

        let resp: VoiceCallAPI.SessionResponse
        do {
            resp = try await api.createSession(conversationId: conversationId)
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
        provider = resp.provider

        let transport: CallTransport
        switch resp.provider {
        case .openai:
            guard let cs = resp.client_secret else {
                phase = .terminated(.startupError("missing client_secret"))
                return
            }
            transport = OpenAICallTransport(
                clientSecret: cs.value,
                model: resp.model,
                delegate: self,
            )
        case .doubao:
            guard let cfg = resp.doubao else {
                phase = .terminated(.startupError("missing doubao config"))
                return
            }
            transport = DoubaoCallTransport(
                config: cfg,
                delegate: self,
            )
        }
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

/// Implemented by OpenAICallTransport + DoubaoCallTransport. Holds the
/// audio plumbing (WebRTC peer, AVAudioSession, or SDK engine) and
/// reports back through the CallTransportDelegate protocol.
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
    /// One turn's usage delta is ready to report. Implementations build
    /// the UsageRequest skeleton and call this; CallSession fills in
    /// session_id / conversation_id / alias_id / provider_id and POSTs.
    func transport(_ t: CallTransport, didProduceUsageDelta delta: UsageDelta) async
    /// Append a transcript turn to the post-call upload buffer.
    func transport(_ t: CallTransport, didAppendTranscript turn: VoiceCallAPI.TranscriptTurn)
    /// Transport says we're done — either an error, remote close, or the
    /// upstream telling us the session is over.
    func transport(_ t: CallTransport, didFailWith reason: CallSession.TerminateReason) async
}

/// Slice of a UsageRequest the transport knows about. CallSession adds
/// the identifiers before POSTing.
struct UsageDelta: Sendable {
    let audioInputTokens: Int?
    let audioOutputTokens: Int?
    let textInputTokens: Int?
    let textOutputTokens: Int?
    let audioSecondsBilled: Double?
    let latencyMs: Int?
    let turnIndex: Int
}

// MARK: - CallSession as delegate

extension CallSession: CallTransportDelegate {
    func transportDidConnect(_ t: CallTransport) {
        connectedAt = Date()
        phase = .connected
    }

    func transport(_ t: CallTransport, didProduceUsageDelta delta: UsageDelta) async {
        guard
            let sid = sessionId,
            let pid = providerId,
            let provider
        else { return }
        do {
            let resp = try await api.reportUsage(
                .init(
                    session_id: sid,
                    conversation_id: conversationId,
                    alias_id: aliasId,
                    provider_id: pid,
                    provider: provider,
                    audio_input_tokens: delta.audioInputTokens,
                    audio_output_tokens: delta.audioOutputTokens,
                    text_input_tokens: delta.textInputTokens,
                    text_output_tokens: delta.textOutputTokens,
                    audio_seconds_billed: delta.audioSecondsBilled,
                    latency_ms: delta.latencyMs,
                    turn_index: delta.turnIndex,
                ),
            )
            sessionCostPND = resp.session_cost_credits
            // Silent balance refresh so the user sees the new value as
            // soon as they leave the call screen — without flashing it
            // on the call UI itself.
            await BillingService.applySilentUpdate(balance: resp.balance_credits)
            if !resp.can_continue {
                await terminate(reason: .noBalance)
            }
        } catch {
            // Usage report failure is non-fatal — the call keeps going.
            // We accept the small accounting drift; the next tick will
            // try again, and the user can hang up manually.
        }
    }

    func transport(_ t: CallTransport, didAppendTranscript turn: VoiceCallAPI.TranscriptTurn) {
        transcriptBuffer.append(turn)
    }

    func transport(_ t: CallTransport, didFailWith reason: CallSession.TerminateReason) async {
        await terminate(reason: reason)
    }
}
