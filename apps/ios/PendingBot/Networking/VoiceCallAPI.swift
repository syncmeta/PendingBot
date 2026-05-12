import Foundation

/// Wire-types + thin HTTP wrapper for `/v1/realtime/*` on the worker.
///
/// Lives alongside APIClient (not on top) so the structured error cases
/// — 451 region_unsupported, 402 insufficient_balance, 503 route_unavailable
/// — surface to CallSession as discriminated `VoiceCallError` rather than
/// the opaque `APIError.http(status, body)`. CallSession reacts to each
/// case differently: 451 pops the OpenAI region sheet, 402 disables the
/// phone button, 503 retries once before giving up.
@MainActor
struct VoiceCallAPI {
    let api: APIClient

    init(api: APIClient = APIClient()) {
        self.api = api
    }

    // MARK: - Wire types

    /// Response payload for POST /v1/realtime/session. Worker mints an
    /// ephemeral client_secret against OpenAI's /v1/realtime/client_secrets,
    /// pre-baking the system prompt — iOS only carries the 60s token to
    /// the WebRTC SDP exchange.
    struct SessionResponse: Decodable, Sendable {
        let session_id: String
        let model: String
        let alias_id: String?
        let provider_id: String
        let min_threshold: Int
        let balance_credits: Int
        let client_secret: ClientSecret

        struct ClientSecret: Decodable, Sendable {
            let value: String
            let expires_at: Int?
        }
    }

    struct UsageRequest: Encodable {
        let session_id: String
        let conversation_id: String
        let alias_id: String?
        let provider_id: String
        // Per-turn deltas from response.done.usage. cached_input_tokens
        // is a SUBSET of the audio/text input tokens above (already
        // counted there) — the worker uses it to apply the alias's
        // cached_input_price discount on that portion.
        let audio_input_tokens: Int?
        let audio_output_tokens: Int?
        let text_input_tokens: Int?
        let text_output_tokens: Int?
        let cached_input_tokens: Int?
        let latency_ms: Int?
        let turn_index: Int
    }

    struct UsageResponse: Decodable, Sendable {
        let balance_credits: Int
        let turn_cost_credits: Int
        let session_cost_credits: Int
        let can_continue: Bool
    }

    struct TranscriptTurn: Codable, Sendable {
        let role: String   // "user" | "bot"
        let content: String
        let ts: String     // ISO8601
    }

    struct TranscriptsRequest: Encodable {
        let session_id: String
        let conversation_id: String
        let turns: [TranscriptTurn]
    }

    struct TranscriptsResponse: Decodable, Sendable {
        let inserted: Int
    }

    /// Structured error payload that the realtime routes emit. Matches
    /// the typed envelope from apps/edge/src/lib/http-error.ts:
    ///   { error: { code, message?, detail? } }
    ///
    /// `detail` carries voice-specific fields (country, supported_url,
    /// balance_credits, min_threshold). We also keep flat aliases at
    /// the top level for forward-compat with any legacy response shape
    /// that might still surface from a non-migrated layer.
    struct ErrorPayload: Decodable, Sendable {
        let error: String           // legacy flat shape: error string
        let message: String?
        let country: String?
        let supported_url: String?
        let balance_credits: Int?
        let min_threshold: Int?
        let detail: Detail?

        struct Detail: Decodable, Sendable {
            let country: String?
            let supported_url: String?
            let balance_credits: Int?
            let min_threshold: Int?
        }

        // Custom decoder: tolerate both
        //   { error: "code", country, ... }            (legacy flat)
        //   { error: { code, message, detail: { … } } } (new envelope)
        // by trying the envelope first and falling back to flat fields.
        enum CodingKeys: String, CodingKey {
            case error, message, country, supported_url, balance_credits, min_threshold, detail
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // The new envelope nests the code inside an object under `error`.
            // Try that first; if `error` is a string, treat it as flat.
            if let envelope = try? c.decode(EnvelopeError.self, forKey: .error) {
                self.error = envelope.code
                self.message = envelope.message
                self.detail = envelope.detail
                // Flat fields don't exist in the envelope shape.
                self.country = nil
                self.supported_url = nil
                self.balance_credits = nil
                self.min_threshold = nil
            } else {
                // Legacy flat shape.
                self.error = try c.decode(String.self, forKey: .error)
                self.message = try c.decodeIfPresent(String.self, forKey: .message)
                self.country = try c.decodeIfPresent(String.self, forKey: .country)
                self.supported_url = try c.decodeIfPresent(String.self, forKey: .supported_url)
                self.balance_credits = try c.decodeIfPresent(Int.self, forKey: .balance_credits)
                self.min_threshold = try c.decodeIfPresent(Int.self, forKey: .min_threshold)
                self.detail = try c.decodeIfPresent(Detail.self, forKey: .detail)
            }
        }

        struct EnvelopeError: Decodable, Sendable {
            let code: String
            let message: String?
            let detail: Detail?
        }
    }

    // MARK: - Calls

    func createSession(conversationId: String) async throws -> SessionResponse {
        struct Body: Encodable { let conversation_id: String }
        return try await callDecoding(
            path: "/v1/realtime/session",
            body: Body(conversation_id: conversationId),
        )
    }

    func reportUsage(_ req: UsageRequest) async throws -> UsageResponse {
        try await callDecoding(path: "/v1/realtime/usage", body: req)
    }

    func uploadTranscripts(_ req: TranscriptsRequest) async throws -> TranscriptsResponse {
        try await callDecoding(path: "/v1/realtime/transcripts", body: req)
    }

    func endSession(sessionId: String, conversationId: String) async throws {
        struct Body: Encodable { let session_id: String; let conversation_id: String }
        struct OK: Decodable { let ok: Bool }
        _ = try await callDecoding(
            path: "/v1/realtime/end",
            body: Body(session_id: sessionId, conversation_id: conversationId),
        ) as OK
    }

    // MARK: - Internals

    /// Wrap APIClient.post so 4xx/5xx bodies that look like ErrorPayload get
    /// promoted to typed VoiceCallError before the generic APIError path
    /// fires. We re-parse the body string carried by APIError.http for
    /// any error we recognize.
    private func callDecoding<Body: Encodable, R: Decodable>(
        path: String,
        body: Body,
    ) async throws -> R {
        do {
            return try await api.post(path, body: body)
        } catch let err as APIError {
            if let mapped = mapAPIError(err) { throw mapped }
            throw err
        }
    }


    private func mapAPIError(_ err: APIError) -> VoiceCallError? {
        guard case let .http(status, code, message, body) = err else { return nil }
        // Detail payload (country, balance_credits, etc.) still lives in
        // the JSON body — APIClient only lifts code+message into the
        // typed enum. Re-parse the body when we need those fields.
        let payload: ErrorPayload? = body.data(using: .utf8).flatMap {
            try? JSONDecoder().decode(ErrorPayload.self, from: $0)
        }
        switch code {
        case "voice_region_unsupported", "region_unsupported":
            return .regionUnsupported(
                country: payload?.detail?.country,
                message: message ?? "",
                supportedURL: payload?.detail?.supported_url.flatMap(URL.init(string:)),
            )
        case "insufficient_balance":
            return .insufficientBalance(
                message: message ?? "",
                balance: payload?.balance_credits ?? payload?.detail?.balance_credits ?? 0,
                threshold: payload?.min_threshold ?? payload?.detail?.min_threshold ?? 0,
            )
        case "voice_upstream_failed", "upstream_unavailable", "upstream_error", "route_unavailable":
            return .routeUnavailable(message: message ?? "")
        case "session_not_found", "session_forbidden", "session_ended", "session_expired":
            return .sessionExpired
        case .some(let raw):
            return .other(status: status, error: raw, message: message ?? "")
        case .none:
            return .other(status: status, error: payload?.error ?? "", message: message ?? "")
        }
    }
}

/// Typed errors callers branch on. `other` is the fallback for shapes we
/// haven't promoted yet (forward-compat with backend additions).
enum VoiceCallError: LocalizedError, Sendable {
    case regionUnsupported(country: String?, message: String, supportedURL: URL?)
    case insufficientBalance(message: String, balance: Int, threshold: Int)
    case routeUnavailable(message: String)
    case sessionExpired
    case other(status: Int, error: String, message: String)

    var errorDescription: String? {
        switch self {
        case .regionUnsupported(_, let m, _),
             .insufficientBalance(let m, _, _),
             .routeUnavailable(let m):
            return m.isEmpty ? "通话失败" : m
        case .sessionExpired:
            return "通话会话已过期"
        case .other(_, _, let m):
            return m.isEmpty ? "通话失败" : m
        }
    }
}
