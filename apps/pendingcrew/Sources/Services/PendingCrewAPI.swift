import Foundation

/// 精简 PendingBot Edge client。
///
/// 当前覆盖端点：
/// - device-login（创建 challenge + poll）
/// - crew read/write（list / detail / create / attach-parent）
/// - me（subjects 列表）
///
/// 后续 share-change / runner / config 端点等到真正需要时再加，避免重蹈老
/// PendingCrew "提前抽象 → 不匹配实际需求" 的覆辙。
struct PendingCrewAPI {
    let baseURL: URL
    let session: URLSession
    /// 当前登录 grant token（`pdg_*`）。device-login 端点不需要；其它
    /// `/v1/*` 端点都通过 `Authorization: Bearer <token>` 鉴权。
    let bearerToken: String?

    init(baseURL: URL, bearerToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.bearerToken = bearerToken
    }

    // MARK: - Device-login

    /// `POST /v1/device-login/challenges`。
    ///
    /// `subjectId` 可选 — 不传 = 让 PendingBot 端选 subject（默认本人
    /// user_account）。传了相当于 "我希望以这个 subject 登录"，PendingBot
    /// 用户 approve 时必须用同一个 subject 否则 409 subject_mismatch
    /// （edge 端反欺骗）。
    func createDeviceLoginChallenge(
        subjectId: String? = nil,
        deviceName: String = currentDeviceName(),
        devicePublicKey: String = "scaffold-placeholder-key-0123456789abcdef"
    ) async throws -> DeviceLoginChallenge {
        struct Body: Encodable {
            let appKind: String
            let deviceName: String
            let devicePublicKey: String
            let scopes: [String]
            let subjectId: String?
        }
        let body = Body(
            appKind: "pendingcrew_macos",
            deviceName: deviceName,
            devicePublicKey: devicePublicKey,
            scopes: ["subject:read", "crew:read", "crew:write", "runner:read", "runner:write"],
            subjectId: subjectId
        )
        return try await post(path: "v1/device-login/challenges", body: body, authenticated: false)
    }

    /// `GET /v1/device-login/challenges/:id?secret=...`。
    ///
    /// PendingCrew 周期 poll；approve 那一刻这个调用会返回
    /// `deviceGrantToken`（之后再 poll 同一个 challenge 会 410 expired）。
    func pollDeviceLoginChallenge(
        challengeId: String,
        secret: String
    ) async throws -> DeviceLoginPollResponse {
        let url = baseURL
            .appendingPathComponent("v1/device-login/challenges")
            .appendingPathComponent(challengeId)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "secret", value: secret)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        // device-login poll 端点本身就是 unauthenticated（secret 在 query
        // 里），不要塞 bearer。
        return try await perform(request)
    }

    // MARK: - Subjects

    /// 返回 caller 能代表/登录的 subject(目前固定 1 个,即 grant 绑定的那个)。
    ///
    /// 历史:**PendingCrew 用 device grant token 鉴权**(`pdg_*`),不是 supabase
    /// user JWT。`/v1/me/subjects`(复数)走 `requireSession()`,只接受 user JWT,
    /// 调起来 401 → CreateCrewSheet picker 空 → "没有可代表的 subject"。
    ///
    /// 正确路径:`/v1/me/subject`(单数)走 `requireSubjectAuth(['subject:read'])`,
    /// device grant 兼容,返回 **grant 当前代表的 subject + wallet**。
    /// PendingCrew grant 颁发时 iOS 那边已经选过 subject(spec v2 §4.4),所以单数足够。
    /// 复数 endpoint 留给 iOS PendingBot 的"选 subject 批准 Mac 扫码"picker 用。
    ///
    /// 包成 `[UserSubject]` 单元素 array 是为了不改 UI 层 picker 形状 ——
    /// 后续 phase 加"已登录态切换 subject"时这里改成调真正的多 subject endpoint。
    func listMySubjects() async throws -> [UserSubject] {
        struct Response: Decodable {
            let subject: Row
            // 登录这台机的 PendingCrew 用户(auth.users.id) —— device grant
            // 路径是 grant 的 granted_by_user_id,user-JWT 路径是 caller 自己。
            // 群聊用它区分"自己的消息"。subject row 之外的顶层字段。
            let userId: String?
            struct Row: Decodable {
                let id: String
                let subjectType: String
                let displayName: String
                // `/v1/me/subject` 直接回 supabase row(snake_case),
                // 不像 crews 路由那样手动 map camelCase,所以这里要显式
                // CodingKeys。perform() 用裸 JSONDecoder(crews 端返回的
                // 已是 camelCase),不能加全局 convertFromSnakeCase 否则
                // 反过来破坏 crews 解码。
                enum CodingKeys: String, CodingKey {
                    case id
                    case subjectType = "subject_type"
                    case displayName = "display_name"
                }
            }
            enum CodingKeys: String, CodingKey {
                case subject
                case userId = "user_id"
            }
        }
        let resp: Response = try await get(path: "v1/me/subject")
        return [UserSubject(
            id: resp.subject.id,
            kind: resp.subject.subjectType,
            displayName: resp.subject.displayName,
            role: nil,
            userId: resp.userId
        )]
    }

    // MARK: - Crews

    /// `GET /v1/crews`。
    func listCrews() async throws -> [CrewSummary] {
        struct Response: Decodable { let crews: [CrewSummary] }
        let resp: Response = try await get(path: "v1/crews")
        return resp.crews
    }

    /// `GET /v1/crews/:crewId`。
    func getCrew(_ crewId: String) async throws -> CrewDetail {
        try await get(path: "v1/crews/\(crewId)")
    }

    /// `POST /v1/crews`。返回新建 crew + 自动创建的 captain bot id。
    func createCrew(_ request: CreateCrewRequest) async throws -> CreateCrewResponse {
        try await post(path: "v1/crews", body: request)
    }

    // MARK: - Models

    /// `GET /v1/models` — 拉模型目录给 CreateSessionSheet 的 picker。
    ///
    /// edge 端返回的是裸 array(不是 `{ models: [...] }` envelope),所以这里
    /// 直接解 `[ModelCatalogEntry]`。
    func listModels() async throws -> [ModelCatalogEntry] {
        try await get(path: "v1/models")
    }

    /// `POST /v1/crews/:crewId/attach-parent`。
    func attachParent(crewId: String, parentCrewId: String, childKeepsBps: Int) async throws {
        struct Body: Encodable {
            let parentCrewId: String
            let childKeepsBps: Int
        }
        struct Response: Decodable { let ok: Bool }
        let _: Response = try await post(
            path: "v1/crews/\(crewId)/attach-parent",
            body: Body(parentCrewId: parentCrewId, childKeepsBps: childKeepsBps)
        )
    }

    // MARK: - Crew sessions (T4.5 runner lifecycle)
    //
    // The HTTP client surface for cross-device remote control. These mirror
    // the shipped server routes (apps/edge/src/routes/{crew,runner-hosts}.ts);
    // the runner-loop slice consumes them next. All but `createSession`
    // require a **device-grant** bearer with `runner:write` scope. `payload`
    // isn't plumbed yet — `summary`/`progressSummary` cover the human-readable
    // bits and the server fills `payload` with its `{}` default; structured
    // payloads wait for a cross-platform JSON value (JSONValue is Mac-only,
    // this file compiles for iOS too).

    /// `POST /v1/crew/:crewId/sessions` — open a crew session (status
    /// 'queued'). Returns the server session id. `runnerKind` ∈
    /// local_claude_code / local_codex / local_opencode / local_kilo /
    /// cloud_sandbox. Needs `crew:write`.
    ///
    /// **Path is singular `/v1/crew`** — `routes/crew.ts` (sessions / links /
    /// mailbox) mounts at `/v1/crew`, while `routes/crews.ts` (list / get /
    /// create crew) mounts at the plural `/v1/crews`. Easy to mix up.
    func createSession(crewId: String, runnerKind: String, taskBrief: String) async throws -> String {
        struct Body: Encodable { let runnerKind: String; let taskBrief: String }
        struct Response: Decodable { let sessionId: String }
        let resp: Response = try await post(
            path: "v1/crew/\(crewId)/sessions",
            body: Body(runnerKind: runnerKind, taskBrief: taskBrief)
        )
        return resp.sessionId
    }

    /// `POST /v1/runner-hosts` — register this machine as a runner host.
    /// Returns the runner host id used for claim/events/finish. The
    /// `responsibleSubjectId` must equal the device grant's subject.
    func registerRunnerHost(
        responsibleSubjectId: String,
        displayName: String?,
        allowedRunnerKinds: [String]
    ) async throws -> String {
        struct Body: Encodable {
            let responsibleSubjectId: String
            let displayName: String?
            let allowedRunnerKinds: [String]
        }
        struct Response: Decodable { let runnerHostId: String }
        let resp: Response = try await post(
            path: "v1/runner-hosts",
            body: Body(
                responsibleSubjectId: responsibleSubjectId,
                displayName: displayName,
                allowedRunnerKinds: allowedRunnerKinds
            )
        )
        return resp.runnerHostId
    }

    /// `POST /v1/runner-hosts/:hostId/sessions/:sessionId/claim` — claim a
    /// specific session for this host (assigns a runner lease, status →
    /// running). `leaseId` is nil when there was nothing claimable.
    func claimSession(
        runnerHostId: String,
        sessionId: String,
        runnerKinds: [String]? = nil
    ) async throws -> SessionClaim {
        struct Body: Encodable { let runnerKinds: [String]? }
        return try await post(
            path: "v1/runner-hosts/\(runnerHostId)/sessions/\(sessionId)/claim",
            body: Body(runnerKinds: runnerKinds)
        )
    }

    /// `POST /v1/runner-hosts/:hostId/sessions/:sessionId/events` — append a
    /// runner event. `eventType` ∈ started / context_injected / status /
    /// tool_call / tool_result / permission_requested / permission_resolved /
    /// artifact_created / posted_to_crew / blocked. `visibility` ∈ controllers
    /// / crew_members / private_system. Returns the new event id.
    func appendSessionEvent(
        runnerHostId: String,
        sessionId: String,
        eventType: String,
        visibility: String = "crew_members",
        summary: String?,
        progressSummary: String? = nil
    ) async throws -> String {
        struct Body: Encodable {
            let eventType: String
            let visibility: String
            let summary: String?
            let progressSummary: String?
        }
        struct Response: Decodable { let eventId: String }
        let resp: Response = try await post(
            path: "v1/runner-hosts/\(runnerHostId)/sessions/\(sessionId)/events",
            body: Body(
                eventType: eventType,
                visibility: visibility,
                summary: summary,
                progressSummary: progressSummary
            )
        )
        return resp.eventId
    }

    /// `GET /v1/crew/:crewId/sessions` — list a crew's server sessions (most
    /// recent first). The viewer side reads this to watch sessions running on
    /// another host. Needs `crew:read`.
    func listCrewSessions(crewId: String) async throws -> [CrewSessionSummary] {
        struct Response: Decodable { let items: [CrewSessionSummary] }
        let resp: Response = try await get(path: "v1/crew/\(crewId)/sessions")
        return resp.items
    }

    /// `GET /v1/crew/sessions/:sessionId/events` — the durable transcript log
    /// for one session (oldest first). What a viewer renders to follow a
    /// session without being its runner. Needs `crew:read`.
    func getSessionEvents(sessionId: String) async throws -> [CrewSessionEvent] {
        struct Response: Decodable { let items: [CrewSessionEvent] }
        let resp: Response = try await get(path: "v1/crew/sessions/\(sessionId)/events")
        return resp.items
    }

    /// `POST /v1/runner-hosts/:hostId/sessions/:sessionId/finish` — close out
    /// the session. `status` ∈ completed / failed / cancelled.
    @discardableResult
    func finishSession(
        runnerHostId: String,
        sessionId: String,
        status: String,
        summary: String? = nil,
        progressSummary: String? = nil
    ) async throws -> Bool {
        struct Body: Encodable {
            let status: String
            let summary: String?
            let progressSummary: String?
        }
        struct Response: Decodable { let ok: Bool }
        let resp: Response = try await post(
            path: "v1/runner-hosts/\(runnerHostId)/sessions/\(sessionId)/finish",
            body: Body(status: status, summary: summary, progressSummary: progressSummary)
        )
        return resp.ok
    }

    // MARK: - Crew interactions (T4.5 ask_human / 人在回路)

    /// `GET /v1/sessions/:sessionId/interactions` — list this session's pending
    /// `ask_human` interactions awaiting a human reply. The operator's viewer
    /// polls this to surface "the agent is asking you something".
    func listSessionInteractions(sessionId: String) async throws -> [CrewInteraction] {
        struct Response: Decodable { let items: [CrewInteraction] }
        let resp: Response = try await get(path: "v1/sessions/\(sessionId)/interactions")
        return resp.items
    }

    /// `POST /v1/interactions/:reqId/answer` — answer an interaction with free
    /// text. The session's blocked `ask_human` tool picks it up and continues.
    @discardableResult
    func answerInteraction(reqId: String, reply: String) async throws -> Bool {
        struct Body: Encodable { let reply: String }
        struct Response: Decodable { let ok: Bool }
        let resp: Response = try await post(path: "v1/interactions/\(reqId)/answer", body: Body(reply: reply))
        return resp.ok
    }

    // MARK: - Crew group chat / whiteboard (spec §9 中栏)

    /// `GET /v1/crews/:crewId/messages` — the crew's whiteboard (group chat
    /// timeline) for the middle pane. crewId == crew_conversation_id. Oldest
    /// first. Needs `crew:read`.
    func listCrewWhiteboard(crewId: String) async throws -> [CrewWhiteboardEntry] {
        struct Response: Decodable { let whiteboard: [CrewWhiteboardEntry] }
        let resp: Response = try await get(path: "v1/crews/\(crewId)/messages")
        return resp.whiteboard
    }

    /// `POST /v1/crews/:crewId/messages` — drop a message on the crew
    /// whiteboard. `mentions` routes it: `@session <id>` → that session's
    /// mailbox; `@captain`; empty/`@broadcast` → all sessions. Needs `crew:write`.
    @discardableResult
    func postCrewMessage(crewId: String, text: String, mentions: [CrewMention] = []) async throws -> String? {
        struct Body: Encodable { let content: String; let mentions: [CrewMention] }
        struct Response: Decodable { let announcementId: String? }
        let resp: Response = try await post(
            path: "v1/crews/\(crewId)/messages",
            body: Body(content: text, mentions: mentions)
        )
        return resp.announcementId
    }

    /// `GET /v1/crews/:crewId/members` — the crew roster (spec §9: everyone is a
    /// member — human / captain / code_session / temp bot). Needs `crew:read`.
    func listCrewMembers(crewId: String) async throws -> CrewRoster {
        try await get(path: "v1/crews/\(crewId)/members")
    }

    // MARK: - Session inbox (runner per-turn context: whiteboard + mailbox)

    /// `GET /v1/sessions/:sessionId/inbox` — the per-turn context bundle the
    /// runner injects into the agent's prompt (spec §9.2/§9.5): the crew
    /// whiteboard + this session's unread mailbox. Needs `crew:read`.
    func getSessionInbox(sessionId: String) async throws -> CrewSessionInbox {
        try await get(path: "v1/sessions/\(sessionId)/inbox")
    }

    /// `POST /v1/sessions/:sessionId/inbox/mark-delivered` — mark mailbox items
    /// as delivered once they've been folded into a prompt turn, so they don't
    /// re-inject next turn. Needs `crew:write`.
    @discardableResult
    func markInboxDelivered(sessionId: String, itemIds: [String]) async throws -> Bool {
        guard !itemIds.isEmpty else { return true }
        struct Body: Encodable { let itemIds: [String]; enum CodingKeys: String, CodingKey { case itemIds = "item_ids" } }
        struct Response: Decodable { let ok: Bool? }
        let resp: Response = try await post(
            path: "v1/sessions/\(sessionId)/inbox/mark-delivered",
            body: Body(itemIds: itemIds)
        )
        return resp.ok ?? true
    }

    // MARK: - Internals

    private func get<Response: Decodable>(path: String) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        attachAuth(to: &request)
        return try await perform(request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        authenticated: Bool = true
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        if authenticated { attachAuth(to: &request) }
        return try await perform(request)
    }

    private func attachAuth(to request: inout URLRequest) {
        guard let token = bearerToken else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PendingCrewAPIError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode) {
            // edge 用 { error: { code, message?, detail? } } envelope
            // (apps/edge/src/lib/http-error.ts)，直接解出来给上层。
            let envelope = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error
            throw PendingCrewAPIError.http(
                status: http.statusCode,
                code: envelope?.code,
                message: envelope?.message
            )
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

// MARK: - Crew session models (T4.5)

/// Result of `claimSession`. The claimed crew_session row is free-form on the
/// wire and not modeled yet (the runner already holds the sessionId it
/// claimed); only the lease id is decoded. `leaseId` nil = nothing claimable.
struct SessionClaim: Decodable {
    let leaseId: String?
}

/// One server crew session row (from `listCrewSessions`). Mirrors the
/// `crew_sessions` columns the list endpoint returns.
struct CrewSessionSummary: Decodable, Identifiable, Equatable {
    let id: String
    let runnerKind: String
    let status: String
    let taskBrief: String
    let progressSummary: String?
    let createdAt: String
    let startedAt: String?
    let finishedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case runnerKind = "runner_kind"
        case status
        case taskBrief = "task_brief"
        case progressSummary = "progress_summary"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

/// One transcript event from a session's durable log (`getSessionEvents`).
struct CrewSessionEvent: Decodable, Identifiable, Equatable {
    let id: String
    let eventType: String
    let visibility: String
    let summary: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case eventType = "event_type"
        case visibility
        case summary
        case createdAt = "created_at"
    }
}

/// One pending `ask_human` interaction (T4.5). The agent is blocked waiting on
/// `question`; the operator answers with free text.
struct CrewInteraction: Decodable, Identifiable, Equatable {
    let id: String
    let question: String
    let requestedAt: String?
}

// MARK: - Crew whiteboard / group chat models (spec §9)

/// A mention target for a crew message. `@session <id>` routes to that
/// session's mailbox; `@captain` to the captain's session; empty list or
/// `broadcast` fans out to all sessions.
struct CrewMention: Encodable, Equatable {
    let kind: String          // 'session' | 'captain' | 'broadcast' | 'human'
    let targetId: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case targetId = "target_id"
    }

    static func session(_ id: String) -> CrewMention { .init(kind: "session", targetId: id) }
    static let captain = CrewMention(kind: "captain", targetId: nil)
    static let broadcast = CrewMention(kind: "broadcast", targetId: nil)
}

/// One image / file attachment on a whiteboard message. Mirror of PendingBot
/// iOS `Attachment` — the server hydrates these from `messages.attachments`
/// `{ ids: [...] }` into full objects, so the wire already carries mime / size /
/// url / filename (PendingCrew has no direct Supabase access to resolve ids).
/// `url` is the auth-gated `/v1/uploads/<id>` path, fetched with the
/// device-grant bearer token.
struct CrewAttachment: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let kind: String?
    let mime: String
    let size: Int?
    let width: Int?
    let height: Int?
    let url: String
    let filename: String?

    /// True when this attachment renders as an inline image (vs a file chip).
    var isImage: Bool { mime.lowercased().hasPrefix("image/") }
}

/// One whiteboard entry (a crew_announcements row) rendered in the middle-pane
/// group chat. `summary` is the display line; `payload.kind == "interaction"`
/// marks an ask_human card (T4.5) so the timeline can render it specially.
struct CrewWhiteboardEntry: Decodable, Identifiable, Equatable {
    let id: String
    let senderKind: String          // 'session' | 'user' | 'bot' | ...
    let senderSessionId: String?
    let senderUserId: String?       // 新增：user 作者
    let senderBotId: String?        // 新增：bot 作者
    let messageKind: String         // 'instruction' | 'announcement' | 'permission_request' | ...
    let summary: String?
    let createdAt: String
    let payload: Payload?
    /// Image / file attachments on this message. Optional → entries without
    /// attachments (and older server builds) decode fine. Server hydrates
    /// these from `messages.attachments` `{ ids: [...] }` into full objects;
    /// `url` is the auth-gated `/v1/uploads/<id>` path `CrewRemoteImage`
    /// fetches with the device-grant bearer token.
    let attachments: [CrewAttachment]?

    struct Payload: Decodable, Equatable {
        let text: String?
        let kind: String?                // 'interaction' for ask_human cards
        let question: String?
        let status: String?
        let permissionRequestId: String?

        enum CodingKeys: String, CodingKey {
            case text, kind, question, status
            case permissionRequestId = "permission_request_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case senderKind = "sender_kind"
        case senderSessionId = "sender_session_id"
        case senderUserId = "sender_user_id"
        case senderBotId = "sender_bot_id"
        case messageKind = "message_kind"
        case summary
        case createdAt = "created_at"
        case payload
        case attachments
    }

    /// Best display text: explicit payload text → summary → empty.
    var displayText: String { payload?.text ?? summary ?? "" }
    /// True if this row is an ask_human interaction card.
    var isInteraction: Bool { payload?.kind == "interaction" }
}

/// The crew roster (`listCrewMembers`). `captainBotId` lets the UI tag which
/// bot member is the captain.
struct CrewRoster: Decodable {
    let captainBotId: String?
    let members: [CrewMember]

    enum CodingKeys: String, CodingKey {
        case captainBotId = "captainBotId"
        case members
    }
}

/// One crew member (a row of `temporary_group_members`). `memberKind` ∈
/// human / bot / captain / code_session.
struct CrewMember: Decodable, Identifiable, Equatable {
    let id: String
    let memberKind: String
    let userId: String?
    let botId: String?
    let codeSessionId: String?
    let displayName: String?
    let role: String?
    let status: String
    let representsCrewId: String?
    /// For code_session members: the live crew_session status (running/queued/…).
    /// nil for non-session members. Terminal sessions are already filtered out
    /// server-side, so a present value here is non-terminal.
    let sessionStatus: String?

    enum CodingKeys: String, CodingKey {
        case id
        case memberKind = "member_kind"
        case userId = "user_id"
        case botId = "bot_id"
        case codeSessionId = "code_session_id"
        case displayName = "display_name"
        case role
        case status
        case representsCrewId = "represents_crew_id"
        case sessionStatus
    }
}

/// The per-turn context bundle (`getSessionInbox`): crew whiteboard + this
/// session's unread mailbox. Only the two fields the runner injects are
/// decoded; `session` / `crew` in the response are ignored.
struct CrewSessionInbox: Decodable {
    let whiteboard: [CrewWhiteboardEntry]
    let mailbox: [CrewMailboxItem]
}

/// One unread mailbox item targeted at this session (a `@session` / broadcast
/// message someone dropped on the crew, fanned out to this session's mailbox).
struct CrewMailboxItem: Decodable, Identifiable, Equatable {
    let id: String
    let senderKind: String
    let senderSessionId: String?
    let messageKind: String
    let summary: String?
    let status: String
    let createdAt: String
    let payload: CrewWhiteboardEntry.Payload?

    var displayText: String { payload?.text ?? summary ?? "" }

    enum CodingKeys: String, CodingKey {
        case id
        case senderKind = "sender_kind"
        case senderSessionId = "sender_session_id"
        case messageKind = "message_kind"
        case summary
        case status
        case createdAt = "created_at"
        case payload
    }
}

// MARK: - Create crew request/response

/// 对应 edge `POST /v1/crews` 的 body。`runtimeLocation` MVP 只支持
/// `local_host`，peer/fly 两档留下次（需要先选 peer device / fly
/// machine —— Phase 4+）。
struct CreateCrewRequest: Encodable {
    let responsibleSubjectId: String
    let title: String
    let runtimeLocation: String
    let workingDirectory: String?
    let tag: String?
    let captain: Captain
    let peerDeviceId: String?
    let flyMachineId: String?

    enum Captain: Encodable, Equatable {
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
        captain: Captain
    ) -> CreateCrewRequest {
        CreateCrewRequest(
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

struct CreateCrewResponse: Decodable {
    let crewId: String
    let captainBotId: String?
}

// MARK: - Error envelope

private struct ErrorEnvelope: Decodable {
    let error: ErrorBody

    struct ErrorBody: Decodable {
        let code: String?
        let message: String?
    }
}

enum PendingCrewAPIError: LocalizedError {
    case invalidResponse
    case http(status: Int, code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了非 HTTP 响应"
        case let .http(status, code, message):
            let prefix = "HTTP \(status)"
            if let message, !message.isEmpty { return "\(prefix): \(message)" }
            if let code { return "\(prefix) (\(code))" }
            return prefix
        }
    }
}

#if canImport(IOKit)
import IOKit
#endif

private func currentDeviceName() -> String {
    #if os(macOS)
    return Host.current().localizedName ?? "Mac"
    #elseif os(iOS)
    return UIDevice.current.name
    #else
    return "PendingCrew Device"
    #endif
}

#if os(iOS)
import UIKit
#endif
