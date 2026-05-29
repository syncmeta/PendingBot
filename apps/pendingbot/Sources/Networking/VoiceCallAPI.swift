#if os(iOS)
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

    /// Response payload for POST /v1/realtime/session. Shape depends on
    /// the requested transport:
    ///   webrtc    — carries `client_secret` (ephemeral key for the
    ///               iOS<->OpenAI WebRTC SDP exchange). `transport` is
    ///               absent; treat a missing value as "webrtc".
    ///   websocket — carries `ws_path`; iOS opens that WebSocket on the
    ///               worker and the server-side meter DO bridges it.
    struct SessionResponse: Decodable, Sendable {
        let session_id: String
        let model: String
        let min_threshold: Int
        let balance_credits: Int
        /// "webrtc" (absent), "webrtc_turn", or "websocket".
        let transport: String?
        /// WebRTC transport only — the ephemeral key for the SDP exchange.
        let client_secret: ClientSecret?
        /// WebSocket transport only — relative path iOS opens the WS to.
        let ws_path: String?
        /// 'webrtc_turn' transport only — Cloudflare TURN ICE servers the
        /// WebRTC peer connection routes its media through.
        let ice_servers: [IceServer]?

        struct ClientSecret: Decodable, Sendable {
            let value: String
            let expires_at: Int?
        }

        /// One RTCIceServer entry, as minted by Cloudflare TURN.
        struct IceServer: Decodable, Sendable {
            let urls: [String]
            let username: String?
            let credential: String?
        }
    }

    /// Closing recap of a call. The realtime model writes a short text
    /// summary at hang-up; the worker stores it as a memory-only message
    /// row (metadata.source='voice_call_summary'), never rendered.
    struct SummaryRequest: Encodable {
        let session_id: String
        let conversation_id: String
        let summary: String
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

    func createSession(
        conversationId: String,
        transport: String,
    ) async throws -> SessionResponse {
        struct Body: Encodable {
            let conversation_id: String
            let transport: String
        }
        return try await callDecoding(
            path: "/v1/realtime/session",
            body: Body(
                conversation_id: conversationId,
                transport: transport,
            ),
        )
    }

    /// WebRTC transport only. After the iOS<->OpenAI SDP exchange yields a
    /// call_id, hand it — plus the ephemeral client_secret the call was
    /// created with — to the worker so RealtimeMeterDO can open its
    /// server-side sideband and meter the call. The sideband must auth
    /// with the ephemeral secret, not the standard key, or OpenAI returns
    /// call_id_not_found. Usage is no longer self-reported by the client.
    func attach(
        sessionId: String,
        conversationId: String,
        callId: String,
        clientSecret: String,
    ) async throws {
        struct Body: Encodable {
            let session_id: String
            let conversation_id: String
            let call_id: String
            let client_secret: String
        }
        struct OK: Decodable { let ok: Bool }
        _ = try await callDecoding(
            path: "/v1/realtime/attach",
            body: Body(
                session_id: sessionId,
                conversation_id: conversationId,
                call_id: callId,
                client_secret: clientSecret,
            ),
        ) as OK
    }

    /// Post the model's closing recap of the call. Fire-and-forget from
    /// the caller's side — a missing summary just costs the bot a memory.
    func uploadSummary(_ req: SummaryRequest) async throws {
        struct OK: Decodable { let ok: Bool }
        _ = try await callDecoding(path: "/v1/realtime/summary", body: req) as OK
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

// =============================================================================
// MARK: - Group voice
// =============================================================================
//
// Wire-types + methods for the group-voice control surface on the worker
// (`/v1/groups/:id/voice/*`). Distinct from the 1:1 realtime endpoints
// above: a group call is a Cloudflare RealtimeKit meeting. iOS joins as
// a WebRTC participant through the embedded RealtimeKit client; bots join
// as headless RealtimeKit participants in the media container.

/// One bot in the call's roster.
struct GroupBotRosterEntry: Decodable, Sendable, Equatable {
    let botId: String
}

/// One human in the call's roster.
struct GroupHumanRosterEntry: Decodable, Sendable, Equatable {
    let humanId: String
}

/// A participant the call invited but hasn't joined yet. Surfaced from
/// roster() so the in-call UI can render a "ringing" group below the
/// joined participants. Cleared automatically when the target joins or
/// when /voice/cancel-invite runs.
struct GroupPendingEntry: Decodable, Sendable, Equatable {
    let id: String
    let kind: String         // "human" | "bot"
    let invitedAt: Double    // ms epoch
    let invitedBy: String
}

/// GET /voice/roster — current roster, for mid-call re-sync.
struct GroupVoiceRosterResponse: Decodable, Sendable {
    let ok: Bool
    let startedAt: Double?
    let initiatorId: String?
    let bots: [GroupBotRosterEntry]
    let humans: [GroupHumanRosterEntry]
    let pending: [GroupPendingEntry]?
    let diagnostics: GroupMediaDiagnostics?
}

/// POST /voice/bootstrap. Returns a RealtimeKit meeting id plus the
/// participant token for this user.
struct GroupVoiceBootstrapResponse: Decodable, Sendable {
    let ok: Bool
    let provider: String
    let initiated: Bool?
    let app_id: String
    let meeting: Meeting
    let human: Participant
    let bot: Participant?
    let bots: [GroupBotRosterEntry]?
    let humans: [GroupHumanRosterEntry]?
    let pending: [GroupPendingEntry]?

    struct Meeting: Decodable, Sendable {
        let id: String
        let title: String?
    }

    struct Participant: Decodable, Sendable {
        let id: String
        let custom_participant_id: String
        let display_name: String?
        let preset_name: String
        let token: String
    }
}

/// GET /v1/voice/active — current active voice calls across the user's
/// groups. Polled by the message list on tab focus to render a phone
/// icon on rows whose conversation has a live call.
struct ActiveVoiceCallsResponse: Decodable, Sendable {
    let ok: Bool
    let active: [ActiveVoiceCall]

    struct ActiveVoiceCall: Decodable, Sendable, Equatable {
        let conversation_id: String
        let started_at: String
        let initiator_id: String
    }
}

extension VoiceCallAPI {

    /// Current bot roster — used to re-sync after add-bot.
    func groupVoiceRoster(
        conversationId: String,
    ) async throws -> GroupVoiceRosterResponse {
        try await api.get("/v1/groups/\(conversationId)/voice/roster")
    }

    /// Bootstrap a Cloudflare RealtimeKit meeting/participant.
    func groupVoiceBootstrap(
        conversationId: String,
        botId: String? = nil,
    ) async throws -> GroupVoiceBootstrapResponse {
        struct Body: Encodable { let bot_id: String? }
        return try await callDecoding(
            path: "/v1/groups/\(conversationId)/voice/bootstrap",
            body: Body(bot_id: botId),
        )
    }

    /// Add one more bot to a live call.
    func groupVoiceAddBot(conversationId: String, botId: String) async throws {
        struct Body: Encodable { let bot_id: String }
        struct OK: Decodable { let ok: Bool }
        _ = try await callDecoding(
            path: "/v1/groups/\(conversationId)/voice/add-bot",
            body: Body(bot_id: botId),
        ) as OK
    }

    /// Remove a bot or a human from the call. Privileged — the worker
    /// returns 403 (surfaced as `VoiceCallError.other`) otherwise.
    func groupVoiceKick(
        conversationId: String,
        targetType: String,
        targetId: String,
    ) async throws {
        struct Body: Encodable { let target_type: String; let target_id: String }
        struct OK: Decodable { let ok: Bool }
        _ = try await callDecoding(
            path: "/v1/groups/\(conversationId)/voice/kick",
            body: Body(target_type: targetType, target_id: targetId),
        ) as OK
    }

    /// Grant call-admin powers to a human or bot. Privileged.
    func groupVoiceDesignateAdmin(
        conversationId: String,
        targetId: String,
    ) async throws {
        struct Body: Encodable { let target_id: String }
        struct OK: Decodable { let ok: Bool }
        _ = try await callDecoding(
            path: "/v1/groups/\(conversationId)/voice/designate-admin",
            body: Body(target_id: targetId),
        ) as OK
    }

    /// The caller leaves the call.
    func groupVoiceLeave(conversationId: String) async throws {
        struct Body: Encodable {}
        struct OK: Decodable { let ok: Bool }
        _ = try await callDecoding(
            path: "/v1/groups/\(conversationId)/voice/leave",
            body: Body(),
        ) as OK
    }

    /// Tell the worker we're still here. While the call is up iOS posts
    /// this every ~10s — the DO removes humans whose heartbeat goes
    /// missing for >30s. A 404 means the DO already forgot us (app was
    /// suspended too long, presence audit kicked us); caller should
    /// teardown locally.
    func groupVoiceHeartbeat(conversationId: String) async throws {
        struct Body: Encodable {}
        struct OK: Decodable { let ok: Bool }
        _ = try await callDecoding(
            path: "/v1/groups/\(conversationId)/voice/heartbeat",
            body: Body(),
        ) as OK
    }

    /// End the whole call. Privileged.
    func groupVoiceEnd(conversationId: String) async throws {
        struct Body: Encodable {}
        struct OK: Decodable { let ok: Bool }
        _ = try await callDecoding(
            path: "/v1/groups/\(conversationId)/voice/end",
            body: Body(),
        ) as OK
    }

    /// Ring a human into the call. Stages them in the call's pending
    /// invite set and sends an APNs push so their phone actually rings.
    /// Any participant currently in the call may ring any other group
    /// human — the spec is "如果没有特地拉谁进来, 不要让群内其他人类响铃".
    func groupVoiceRing(conversationId: String, userId: String) async throws {
        struct Body: Encodable { let user_id: String }
        struct OK: Decodable { let ok: Bool; let pushed: Int? }
        _ = try await callDecoding(
            path: "/v1/groups/\(conversationId)/voice/ring",
            body: Body(user_id: userId),
        ) as OK
    }

    /// Drop a pending invite — when the inviter changes their mind, or
    /// when the in-call UI offers a "stop ringing" affordance.
    func groupVoiceCancelInvite(conversationId: String, targetId: String) async throws {
        struct Body: Encodable { let target_id: String }
        struct OK: Decodable { let ok: Bool }
        _ = try await callDecoding(
            path: "/v1/groups/\(conversationId)/voice/cancel-invite",
            body: Body(target_id: targetId),
        ) as OK
    }

    /// Snapshot of active group voice calls for the caller's groups —
    /// one cheap query that backs the message-list phone-icon badge.
    func getActiveVoiceCalls() async throws -> ActiveVoiceCallsResponse {
        try await api.get("/v1/voice/active")
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
#endif
