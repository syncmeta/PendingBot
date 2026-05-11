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

    /// Tap on the phone button enters here. Mints the OpenAI Realtime
    /// session via the worker, then spins up OpenAICallTransport. Errors
    /// surface through `phase = .terminated(...)` so UI can listen via
    /// the @Observable contract rather than try/catch.
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

        let transport = OpenAICallTransport(
            clientSecret: resp.client_secret.value,
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
    /// One turn's usage delta is ready to report. Transport builds the
    /// per-turn UsageDelta from the response.done.usage event; CallSession
    /// fills in session_id / conversation_id / alias_id / provider_id
    /// and POSTs to /v1/realtime/usage.
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
    /// Subset of the input tokens that came from a cache hit. Worker
    /// prices them via alias.cached_input_price (GA cached-audio rate
    /// is ~80× cheaper than full input). Sum of cached_text +
    /// cached_audio per response.done.usage.input_token_details.cached_tokens.
    let cachedInputTokens: Int?
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
        guard let sid = sessionId, let pid = providerId else { return }
        do {
            let resp = try await api.reportUsage(
                .init(
                    session_id: sid,
                    conversation_id: conversationId,
                    alias_id: aliasId,
                    provider_id: pid,
                    audio_input_tokens: delta.audioInputTokens,
                    audio_output_tokens: delta.audioOutputTokens,
                    text_input_tokens: delta.textInputTokens,
                    text_output_tokens: delta.textOutputTokens,
                    cached_input_tokens: delta.cachedInputTokens,
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
