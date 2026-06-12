import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Spec v2 §6/§7/§11 endpoints (`/v1/crews`, `/v1/share-changes`)
//
// These wrap the Phase 2 endpoints F agent shipped in `crews.ts` +
// `share-changes.ts`. The codex-era `/v1/crew` (singular) dashboard
// surface was retired in the T4.6 multiplatform cutover; only the
// subject + device-login support types remain below.
// ─────────────────────────────────────────────────────────────────────

// `CrewSummaryV2` moved to the cross-platform `CrewSessionAPI.swift` so the
// macOS viewer can list crews too. iOS UI still references it unchanged
// (same module).

/// `GET /v1/crews/:crewId` detail. Crew body + parents/children/shares
/// + (optional) captain bot.
struct CrewDetailV2: Decodable, Equatable, Hashable {
    let crew: CrewBodyV2
    let parents: [CrewLinkV2]
    let children: [CrewLinkV2]
    let shares: [CrewShareV2]
    let captain: CrewCaptainV2?
}

struct CrewBodyV2: Decodable, Equatable, Hashable {
    let id: String
    let title: String
    let responsibleSubjectId: String
    let runtimeLocation: String
    let workingDirectory: String?
    let tag: String?
    let captainBotId: String?
    let status: String?
    let createdAt: String
    let updatedAt: String

    var runtimeLocationKind: CrewSummaryV2.RuntimeLocationV2? {
        CrewSummaryV2.RuntimeLocationV2(rawValue: runtimeLocation)
    }
}

struct CrewLinkV2: Decodable, Equatable, Hashable, Identifiable {
    var id: String { crewId }
    let crewId: String
    let title: String
    /// child 在这条 parent-child 边上保留的责任份额 (bps, 0-10000)。
    let childShareBps: Int
}

struct CrewShareV2: Decodable, Equatable, Hashable, Identifiable {
    var id: String { subjectId }
    let subjectId: String
    let shareBps: Int
    let isTiebreaker: Bool
    let displayName: String
    /// `subjects.subject_type` —— 一般是 `user_account` / `group_account`。
    let kind: String
}

struct CrewCaptainV2: Decodable, Equatable, Hashable {
    let botId: String
    let displayName: String
}

/// `POST /v1/crews` body. Mirrors edge `CreateCrewBody` (zod schema in
/// `apps/edge/src/routes/crews.ts`). `runtimeLocation` MVP only accepts
/// `local_host`; peer/fly need a peer device / fly machine pick first
/// (Phase 4+).
struct CreateCrewRequestV2: Encodable {
    let responsibleSubjectId: String
    let title: String
    let runtimeLocation: String
    let workingDirectory: String?
    let tag: String?
    let captain: CaptainBody
    let peerDeviceId: String?
    let flyMachineId: String?

    enum CaptainBody: Encodable, Equatable {
        case systemGenerated(templateName: String?)
        case reuseBot(botId: String)

        enum CodingKeys: String, CodingKey {
            case source
            case templateName
            case botId
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .systemGenerated(let name):
                try container.encode("system_generated", forKey: .source)
                if let name { try container.encode(name, forKey: .templateName) }
            case .reuseBot(let botId):
                try container.encode("reuse_bot", forKey: .source)
                try container.encode(botId, forKey: .botId)
            }
        }
    }

    static func localHost(
        responsibleSubjectId: String,
        title: String,
        workingDirectory: String?,
        tag: String?,
        captain: CaptainBody
    ) -> CreateCrewRequestV2 {
        CreateCrewRequestV2(
            responsibleSubjectId: responsibleSubjectId,
            title: title,
            runtimeLocation: "local_host",
            workingDirectory: workingDirectory,
            tag: tag,
            captain: captain,
            peerDeviceId: nil,
            flyMachineId: nil
        )
    }
}

struct CreateCrewResponseV2: Decodable {
    let crewId: String
    let captainBotId: String?
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Subject + device-login support types (shared by V2 + scan-login)
// ─────────────────────────────────────────────────────────────────────

struct CrewSubjectEnvelope: Decodable {
    let subject: CrewSubject
}

struct CrewSubject: Decodable, Identifiable, Hashable {
    let id: String
    let subject_type: String
    let display_name: String
    let status: String
}

/// 一个 user 能 "代表登录" 的 subject。返回自
/// `GET /v1/me/subjects` (apps/edge/src/routes/me.ts) — 个人
/// user_account + 自己 owner/admin 的所有 group_account。member
/// 没法代表群登录到 PendingCrew 跑本机 agent (spec v2 §4.3)。
struct SubjectListItem: Decodable, Identifiable, Hashable {
    let id: String
    /// `"user_account"` 或 `"group_account"`
    let kind: String
    let displayName: String
    /// 仅 group_account 有；`"owner"` / `"admin"`
    let role: String?

    var isGroupAccount: Bool { kind == "group_account" }
}

struct SubjectListResponse: Decodable {
    let subjects: [SubjectListItem]
}

struct DeviceLoginApprovalResponse: Decodable, Hashable {
    let ok: Bool
    let status: String
}

enum DeviceLoginGrantApproval: Equatable {
    case pendingCrewControl
    case pendingBotClient

    var grantKind: String {
        switch self {
        case .pendingCrewControl: "pendingcrew_control"
        case .pendingBotClient: "pendingbot_client"
        }
    }

    var scopes: [String] {
        switch self {
        case .pendingCrewControl:
            ["subject:read", "crew:read", "crew:write", "runner:read", "runner:write"]
        case .pendingBotClient:
            ["subject:read", "crew:read", "crew:write"]
        }
    }

    static func retryPlan(after error: Error) -> DeviceLoginGrantApproval? {
        guard case let APIError.http(status, code, message, body) = error,
              status == 400,
              code == "invalid_body"
        else { return nil }

        let text = [message, body].compactMap { $0?.lowercased() }.joined(separator: "\n")
        if text.contains("grant kind does not match app kind")
            || text.contains("requested scopes exceed grant kind") {
            return .pendingBotClient
        }
        return nil
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - T4.6 P1 crew chat — read feed + human-post + session/member rows
//
// **Casing split is per-route, and this client uses a bare JSONDecoder
// with NO keyDecodingStrategy.** The read endpoints below
// (`crew.ts` GET announcements/sessions/members) return RAW snake_case
// rows from supabase, so every property here is literal snake_case. The
// human-post response (`crew-comms.ts` POST messages) is hand-shaped
// camelCase, so `CrewPostMessageResponse` stays camelCase. Mixing these
// up silently decodes to nil — each field is confirmed against the route.
// ─────────────────────────────────────────────────────────────────────

/// One row from `GET /v1/crew/:id/announcements` — the crew whiteboard /
/// group-chat feed. `summary` is the human-visible text (NOT `content`).
/// `created_at` is an ISO-8601 string on this snake_case route.
struct CrewAnnouncementRow: Decodable, Identifiable, Hashable {
    let id: String
    let crew_conversation_id: String
    let responsible_subject_id: String?
    /// DB CHECK vocab: `'human' | 'session' | 'master_bot' | 'system'`
    /// (NOT `captain`). The bubble-side mapping keys off
    /// `sender_session_id != nil` rather than this string so an unknown
    /// future value never lands a human post on the wrong side.
    let sender_kind: String
    let sender_member_id: String?
    let sender_session_id: String?
    let recipient_mode: String?
    let message_kind: String
    let board_visible: Bool
    /// The human-visible message text.
    let summary: String
    /// Free-form JSON payload. For `message_kind == 'permission_request'`
    /// rows this is the permission card body
    /// (`{ permission_request_id, action, risk_level, detail, status }`),
    /// read via `payload?.value` (the adapter only consults it for
    /// permission rows). Wrapped in `LenientPermissionPayload` so a
    /// non-permission row's arbitrary payload (object/array/scalar) can
    /// never *throw* and abort the whole announcements array decode — it
    /// just decodes to nil. Keeps the cold HTTP path symmetric with the
    /// live realtime path (which is already tolerant via decodeLogPayload).
    let payload: LenientPermissionPayload?
    let created_at: String
    let mentions: [CrewAnnouncementMention]
}

/// Tolerant wrapper for the announcement `payload` cell: decodes to a
/// `PermissionRequestPayload` when the JSON is a matching object, else nil,
/// and crucially never throws on a shape mismatch — so one odd payload
/// can't blank the entire crew chat on cold load.
struct LenientPermissionPayload: Decodable, Hashable {
    let value: PermissionRequestPayload?
    /// #242 遥控 v1 — the same payload cell, leniently decoded as a
    /// task-request body. Only consulted for `message_kind=='task_request'`
    /// rows (both structs share an optional-everything shape, so a decode
    /// "success" on the wrong kind is harmless).
    let task: CrewTaskRequestPayload?
    init(value: PermissionRequestPayload?, task: CrewTaskRequestPayload? = nil) {
        self.value = value
        self.task = task
    }
    init(from decoder: Decoder) throws {
        self.value = try? PermissionRequestPayload(from: decoder)
        self.task = try? CrewTaskRequestPayload(from: decoder)
    }
}

/// #242 遥控 v1 — the `payload` body of a `message_kind=='task_request'`
/// crew message: `{ action: 'run_session', task_brief, runner_kind? }`.
/// Encodable for the send path (property names == wire keys, no key
/// strategy) and Decodable for rendering the task card on read.
struct CrewTaskRequestPayload: Codable, Hashable {
    let action: String?
    let task_brief: String?
    /// `'claude_code' | 'codex'` — which local runner the Mac should use.
    let runner_kind: String?

    var runnerLabel: String {
        switch runner_kind {
        case "codex": return "Codex"
        default:      return "Claude Code"
        }
    }
}

/// Read-side mention row attached to an announcement. NOTE: no
/// `target_user_id`, and no bare `kind` — it's `target_kind` plus
/// `target_session_id` / `target_member_id`.
struct CrewAnnouncementMention: Decodable, Hashable, Identifiable {
    let id: String
    let announcement_id: String
    let target_kind: String
    let target_session_id: String?
    let target_member_id: String?
    let created_at: String
}

// `CrewSessionRow` + `CrewSessionLogEvent` moved to the cross-platform
// `CrewSessionAPI.swift` (shared with the macOS viewer). iOS references them
// unchanged (same module).

/// One row from `GET /v1/crew/:id/members` (snake_case, wrapper `{items}`).
/// Resolves human / captain sender display names + powers the @mention
/// picker.
struct CrewMemberRow: Decodable, Identifiable, Hashable {
    let id: String
    let conversation_id: String
    /// `'human' | 'bot' | 'session'` (mirrors temporary_group_members).
    let member_kind: String
    let user_id: String?
    let bot_id: String?
    let code_session_id: String?
    let display_name: String?
    let role: String?
    /// Free-form JSON capability bag — kept lenient, unused in P1.
    let capabilities: JSONScalar?
    let status: String
    let created_at: String
}

/// Structured mention sent with a human post. `target_id` is the wire key
/// (no key-encoding strategy → property name == JSON key). `kind` vocab:
/// `'human' | 'session' | 'captain' | 'broadcast'`.
struct CrewMentionInput: Encodable, Hashable {
    let kind: String
    let target_id: String?
}

/// `POST /v1/crews/:crewId/messages` response (camelCase, hand-mapped).
struct CrewPostMessageResponse: Decodable, Hashable {
    let announcementId: String
    let recipientSessionIds: [String]
}

extension APIClient {
    /// `GET /v1/crew/:id/announcements` — the crew chat feed (board_visible
    /// rows, created_at ASC, limit 200). `id` is the crew conversation id.
    func getCrewAnnouncements(_ crewId: String) async throws -> [CrewAnnouncementRow] {
        struct Response: Decodable { let items: [CrewAnnouncementRow] }
        let r: Response = try await get("v1/crew/\(crewId)/announcements")
        return r.items
    }

    // `getCrewSessions` moved to the cross-platform `CrewSessionAPI.swift`.

    /// `GET /v1/crew/:id/members` — active crew members (humans / bots /
    /// sessions). Resolves sender display names + mention candidates.
    func getCrewMembers(_ crewId: String) async throws -> [CrewMemberRow] {
        struct Response: Decodable { let items: [CrewMemberRow] }
        let r: Response = try await get("v1/crew/\(crewId)/members")
        return r.items
    }

    // `getCrewSessionEvents` moved to the cross-platform `CrewSessionAPI.swift`.

    /// `POST /v1/crews/:crewId/messages` — the mention-aware human-post path.
    /// Empty `mentions` (or any `broadcast`) fans out to everyone.
    /// `message_kind` is omitted (server defaults to `text`).
    func postCrewMessage(
        crewId: String,
        content: String,
        mentions: [CrewMentionInput] = [],
        messageKind: String? = nil,
        payload: CrewTaskRequestPayload? = nil
    ) async throws -> CrewPostMessageResponse {
        struct Body: Encodable {
            let content: String
            let mentions: [CrewMentionInput]
            // Optionals are encodeIfPresent under synthesized Encodable, so
            // a plain text post sends neither key (server defaults apply).
            let message_kind: String?
            let payload: CrewTaskRequestPayload?
        }
        return try await post(
            "v1/crews/\(crewId)/messages",
            body: Body(content: content, mentions: mentions,
                       message_kind: messageKind, payload: payload)
        )
    }
}

extension APIClient {
    func crewCurrentSubject() async throws -> CrewSubject {
        let envelope: CrewSubjectEnvelope = try await get("v1/me/subject")
        return envelope.subject
    }

    /// Subjects the caller can act on (personal + owner/admin group
    /// accounts). Powers the "approve device-login → which subject" picker.
    func meSubjects() async throws -> [SubjectListItem] {
        let response: SubjectListResponse = try await get("v1/me/subjects")
        return response.subjects
    }

    func approvePendingCrewDeviceLogin(
        challengeId: String,
        secret: String,
        subjectId: String,
        approval: DeviceLoginGrantApproval = .pendingCrewControl
    ) async throws -> DeviceLoginApprovalResponse {
        struct Body: Encodable {
            let secret: String
            let subjectId: String
            let grantKind: String
            let scopes: [String]
        }
        return try await post(
            "v1/device-login/challenges/\(challengeId)/approve",
            body: Body(secret: secret, subjectId: subjectId, grantKind: approval.grantKind, scopes: approval.scopes)
        )
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Spec v2 §6/§7/§11 — Phase 2 crew endpoints (`/v1/crews`)
    //
    // These call F agent's new `crews.ts` route surface. CrewTabV2View /
    // CrewDetailV2View consume these across all three sizes; the codex-era
    // singular `/v1/crew` dashboard methods were removed in the T4.6 cutover.
    // ─────────────────────────────────────────────────────────────

    // `listCrewsV2` moved to the cross-platform `CrewSessionAPI.swift`.

    /// `GET /v1/crews/:crewId` — crew detail (parents/children/shares/captain).
    func getCrewV2(_ crewId: String) async throws -> CrewDetailV2 {
        try await get("v1/crews/\(crewId)")
    }

    /// `POST /v1/crews` — create a crew + choose a captain.
    func createCrewV2(_ request: CreateCrewRequestV2) async throws -> CreateCrewResponseV2 {
        try await post("v1/crews", body: request)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Spec v2 §6.4 — bot-initiated crew (start_crew tool)
    //
    // The `start_crew` bot tool drops a `role='log'` row with
    // `log_kind='crew_proposal'` into the conversation. PendingBot
    // renders it as a confirmation card; tapping 确认创建 / 拒绝
    // hits this endpoint to make the decision binding.
    // ─────────────────────────────────────────────────────────────

    /// Approve or reject decision for a `start_crew` proposal.
    enum CrewProposalDecision: String, Encodable {
        case approve
        case reject
    }

    /// Response from `POST /v1/messages/:id/crew-proposal/decide`.
    /// `crewId` is set on approve only; `parentAttachError` is set
    /// when the proposal had `proposed_parent_crew_id` and the
    /// follow-up crew_attach_as_child call failed — the crew itself
    /// is still live, just standalone.
    struct CrewProposalDecisionResponse: Decodable {
        let ok: Bool
        let status: String
        let crewId: String?
        let parentAttachError: String?
    }

    /// POST /v1/messages/:messageId/crew-proposal/decide.
    ///
    /// Returns the server's view of the resulting status (always
    /// `approved` or `rejected` on 200). A 409 from the server with
    /// code `crew_proposal_already_decided` surfaces here as
    /// `APIError.http` — the caller refreshes conversation history to
    /// pick up the existing decision.
    func decideCrewProposal(
        messageId: String,
        decision: CrewProposalDecision
    ) async throws -> CrewProposalDecisionResponse {
        struct Body: Encodable { let decision: CrewProposalDecision }
        return try await post(
            "v1/messages/\(messageId)/crew-proposal/decide",
            body: Body(decision: decision)
        )
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Spec v2 §10 — Permission Request
    //
    // The `request_permission` agent tool drops a `role='log'` row with
    // `log_kind='permission_request'` into the crew conversation
    // (mirrors a parallel `crew_announcements` whiteboard card; both
    // are written by `create_permission_request` RPC). PendingBot
    // renders it as a card; tapping 批准 / 拒绝 hits this endpoint to
    // bind the decision.
    // ─────────────────────────────────────────────────────────────

    /// Approve or reject decision for a `request_permission` card.
    /// `reject` maps to status='denied' server-side.
    enum PermissionRequestDecision: String, Encodable {
        case approve
        case reject
    }

    /// Server-shaped row returned by the decide endpoint. Only the
    /// fields the iOS card needs are decoded; extra columns the server
    /// may add later are ignored.
    struct PermissionRequestRow: Decodable {
        let id: String
        let status: String
        let decided_at: String?
        let decided_by_user_id: String?
    }

    /// Response from `POST /v1/permission-requests/:id/decide`.
    struct PermissionRequestDecisionResponse: Decodable {
        let permissionRequest: PermissionRequestRow
    }

    /// POST /v1/permission-requests/:id/decide.
    ///
    /// `id` is the permission_requests.id (read from the card's
    /// payload, not the host message_id). A 409 from the server with
    /// code `permission_request_already_decided` surfaces as
    /// `APIError.http` — the caller refreshes conversation history.
    func decidePermissionRequest(
        id: String,
        decision: PermissionRequestDecision
    ) async throws -> PermissionRequestDecisionResponse {
        struct Body: Encodable { let decision: PermissionRequestDecision }
        return try await post(
            "v1/permission-requests/\(id)/decide",
            body: Body(decision: decision)
        )
    }

    /// PATCH /v1/crews/:crewId/permission-mode.
    /// Body { mode: 'auto'|'manual' }. Caller must own / admin the
    /// crew's responsible subject.
    struct CrewPermissionModeResponse: Decodable {
        let crewId: String
        let permissionMode: String
    }
    func setCrewPermissionMode(
        crewId: String,
        mode: String
    ) async throws -> CrewPermissionModeResponse {
        struct Body: Encodable { let mode: String }
        return try await patch(
            "v1/crews/\(crewId)/permission-mode",
            body: Body(mode: mode)
        )
    }

    /// PATCH /v1/sessions/:sessionId/permission-mode.
    /// Body { mode: 'auto'|'manual'|null }. null clears the override
    /// (inherit crew default).
    struct SessionPermissionModeResponse: Decodable {
        let sessionId: String
        let permissionModeOverride: String?
    }
    func setSessionPermissionMode(
        sessionId: String,
        mode: String?
    ) async throws -> SessionPermissionModeResponse {
        struct Body: Encodable { let mode: String? }
        return try await patch(
            "v1/sessions/\(sessionId)/permission-mode",
            body: Body(mode: mode)
        )
    }
}
