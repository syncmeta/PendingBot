import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Spec v2 §6/§7/§11 endpoints (`/v1/crews`, `/v1/share-changes`)
//
// These wrap the Phase 2 endpoints F agent shipped in `crews.ts` +
// `share-changes.ts`. The legacy `/v1/crew` (singular) surface further
// down still exists for the old dashboard view — leave it untouched
// until cutover is complete; CrewTabV2View / CrewDetailV2View only
// consume the V2 types below.
// ─────────────────────────────────────────────────────────────────────

/// `GET /v1/crews` list row. Field shape mirrors edge response:
/// `id / title / responsibleSubjectId / runtimeLocation / tag /
/// captainBotId / status / createdAt / updatedAt`.
///
/// `runtimeLocation` is a string (not an enum) so we never reject
/// unknown values from the wire — spec v2 §6.2 reserves room for v1.1
/// runner locations; clients should fall back to displaying the raw
/// string rather than failing to decode.
struct CrewSummaryV2: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let responsibleSubjectId: String
    let runtimeLocation: String
    let tag: String?
    let captainBotId: String?
    let status: String?
    let createdAt: String
    let updatedAt: String

    enum RuntimeLocationV2: String {
        case localHost = "local_host"
        case peerDevice = "peer_device"
        case flyMachine = "fly_machine"

        var sfSymbol: String {
            switch self {
            case .localHost: return "desktopcomputer"
            case .peerDevice: return "personalhotspot"
            case .flyMachine: return "cloud"
            }
        }

        var shortLabel: String {
            switch self {
            case .localHost: return "本机"
            case .peerDevice: return "peer 设备"
            case .flyMachine: return "Fly machine"
            }
        }
    }

    var runtimeLocationKind: RuntimeLocationV2? {
        RuntimeLocationV2(rawValue: runtimeLocation)
    }
}

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
// MARK: - Legacy `/v1/crew` (singular) types — kept until cutover lands
// ─────────────────────────────────────────────────────────────────────

struct CrewListResponse<Item: Decodable>: Decodable {
    let items: [Item]
}

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

struct CrewSummary: Decodable, Identifiable, Hashable {
    var id: String { conversation_id }
    let conversation_id: String
    let responsible_subject_id: String
    let status: String
    let title: String
    let runtime_kind: String?
    let created_at: String
    let updated_at: String
}

struct CrewRunnerHost: Decodable, Identifiable, Hashable {
    let id: String
    let responsible_subject_id: String
    let platform: String
    let display_name: String
    let allowed_runner_kinds: [String]
    let status: String
    let last_seen_at: String?
}

struct DeviceLoginApprovalResponse: Decodable, Hashable {
    let ok: Bool
    let status: String
}

struct CrewSessionSummary: Decodable, Identifiable, Hashable {
    let id: String
    let crew_conversation_id: String
    let responsible_subject_id: String
    let runner_kind: String
    let status: String
    let task_brief: String
    let progress_summary: String?
    let created_at: String
    let started_at: String?
    let finished_at: String?
}

struct CrewLinkSummary: Decodable, Identifiable, Hashable {
    var id: String { crew_conversation_id }
    let crew_conversation_id: String
    let title: String
    let status: String
    let runtime_kind: String
    let captain_bot_id: String?
    let captain_member_id: String?
    let created_at: String
}

struct CrewResponsibilityShareSummary: Decodable, Identifiable, Hashable {
    var id: String { subject_id }
    let subject_id: String
    let share_bps: Int
    let source: String
}

struct CrewLinksResponse: Decodable, Hashable {
    let parents: [CrewLinkSummary]
    let children: [CrewLinkSummary]
    let responsibilityShares: [CrewResponsibilityShareSummary]
}

struct CrewMemberSummary: Decodable, Identifiable, Hashable {
    let id: String
    let conversation_id: String
    let member_kind: String
    let user_id: String?
    let bot_id: String?
    let code_session_id: String?
    let display_name: String
    let role: String?
    let status: String
    let created_at: String
}

struct CrewAnnouncementMentionSummary: Decodable, Identifiable, Hashable {
    let id: String
    let announcement_id: String
    let target_kind: String
    let target_session_id: String?
    let target_member_id: String?
    let created_at: String
}

struct CrewAnnouncementSummary: Decodable, Identifiable, Hashable {
    let id: String
    let crew_conversation_id: String
    let responsible_subject_id: String
    let sender_kind: String
    let sender_member_id: String?
    let sender_session_id: String?
    let recipient_mode: String
    let message_kind: String
    let board_visible: Bool
    let summary: String
    let created_at: String
    let mentions: [CrewAnnouncementMentionSummary]
}

struct CrewAnnouncementCreateResponse: Decodable, Hashable {
    let announcementId: String
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

enum CrewRunnerKind: String, CaseIterable, Identifiable, Hashable {
    case cloudSandbox = "cloud_sandbox"
    case localClaudeCode = "local_claude_code"
    case localCodex = "local_codex"
    case localOpencode = "local_opencode"
    case localKilo = "local_kilo"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cloudSandbox: "云端 Sandbox"
        case .localClaudeCode: "Mac Claude Code"
        case .localCodex: "Mac Codex"
        case .localOpencode: "Mac opencode"
        case .localKilo: "Mac Kilo"
        }
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

    func crewList() async throws -> [CrewSummary] {
        let response: CrewListResponse<CrewSummary> = try await get("v1/crew")
        return response.items
    }

    func crewCreate(responsibleSubjectId: String, title: String) async throws -> String {
        struct Body: Encodable {
            let responsibleSubjectId: String
            let title: String
        }
        struct Response: Decodable {
            let conversationId: String
        }
        let response: Response = try await post(
            "v1/crew",
            body: Body(responsibleSubjectId: responsibleSubjectId, title: title)
        )
        return response.conversationId
    }

    func crewCreateChild(crewId: String, title: String) async throws -> String {
        struct Body: Encodable {
            let title: String
        }
        struct Response: Decodable {
            let conversationId: String
        }
        let response: Response = try await post(
            "v1/crew/\(crewId)/children",
            body: Body(title: title)
        )
        return response.conversationId
    }

    func crewLinks(crewId: String) async throws -> CrewLinksResponse {
        try await get("v1/crew/\(crewId)/links")
    }

    func crewMembers(crewId: String) async throws -> [CrewMemberSummary] {
        let response: CrewListResponse<CrewMemberSummary> = try await get("v1/crew/\(crewId)/members")
        return response.items
    }

    func crewAnnouncements(crewId: String) async throws -> [CrewAnnouncementSummary] {
        let response: CrewListResponse<CrewAnnouncementSummary> = try await get("v1/crew/\(crewId)/announcements")
        return response.items
    }

    func crewCreateAnnouncement(
        crewId: String,
        summary: String,
        recipientSessionIds: [String] = [],
        recipientMemberIds: [String] = []
    ) async throws -> CrewAnnouncementCreateResponse {
        struct Body: Encodable {
            let recipientSessionIds: [String]
            let recipientMemberIds: [String]
            let messageKind: String
            let summary: String
            let payload: [String: String]
            let boardVisible: Bool
        }
        return try await post(
            "v1/crew/\(crewId)/announcements",
            body: Body(
                recipientSessionIds: recipientSessionIds,
                recipientMemberIds: recipientMemberIds,
                messageKind: "announcement",
                summary: summary,
                payload: [:],
                boardVisible: true
            )
        )
    }

    func crewSessions(crewId: String) async throws -> [CrewSessionSummary] {
        let response: CrewListResponse<CrewSessionSummary> = try await get("v1/crew/\(crewId)/sessions")
        return response.items
    }

    func crewCreateSession(
        crewId: String,
        runnerKind: CrewRunnerKind,
        taskBrief: String
    ) async throws -> String {
        struct Body: Encodable {
            let runnerKind: String
            let taskBrief: String
        }
        struct Response: Decodable {
            let sessionId: String
        }
        let response: Response = try await post(
            "v1/crew/\(crewId)/sessions",
            body: Body(runnerKind: runnerKind.rawValue, taskBrief: taskBrief)
        )
        return response.sessionId
    }

    func crewRunnerHosts() async throws -> [CrewRunnerHost] {
        let response: CrewListResponse<CrewRunnerHost> = try await get("v1/runner-hosts")
        return response.items
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
    // These call F agent's new `crews.ts` route surface. CrewTabV2View
    // / CrewDetailV2View only consume these; the older singular
    // `/v1/crew` methods further up stay live for `CrewTabView` until
    // the dashboard is removed in a follow-up cutover.
    // ─────────────────────────────────────────────────────────────

    /// `GET /v1/crews` — list crews caller can see.
    func listCrewsV2() async throws -> [CrewSummaryV2] {
        struct Response: Decodable { let crews: [CrewSummaryV2] }
        let response: Response = try await get("v1/crews")
        return response.crews
    }

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
