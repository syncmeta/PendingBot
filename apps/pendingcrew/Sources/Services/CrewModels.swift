// Crew wire-model types extracted from PendingCrewAPI.swift so they can be
// compiled into Foundation-only contexts (test bundles, etc.) without dragging
// in the full `PendingCrewAPI` class and its `URLSession` / Auth dependencies.
//
// PendingCrewAPI.swift imports this file implicitly (same module).
import Foundation

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
    /// Mac relay 上行的来源标注（接合 v2 block 3）。非 nil 且 `origin ==
    /// "mac_relay"` = 这条是 Mac 自己推上去的 —— 拉取侧据此过滤防回环。
    /// edge 老消息 / 非 relay 消息为 nil。
    let relay: Relay?
    /// 发送者显示名。**edge 不下发这个字段**（恒 nil）；`LocalBackend` 把
    /// relay 搬进本地白板的消息映射成 entry 时回填 edge 侧名字，
    /// `CrewSenderResolver` 优先用它。
    let senderDisplayName: String?

    struct Relay: Decodable, Equatable {
        let origin: String
        let senderLabel: String?
        let localSessionId: String?
    }

    struct Payload: Decodable, Equatable {
        let text: String?
        let kind: String?                // 'interaction' for ask_human cards
        let question: String?
        let status: String?
        let permissionRequestId: String?
        // #242 遥控 v1 — messageKind == "task_request" 的结构化指令体
        // ({ action:'run_session', runner_kind?, task_brief })。全 optional →
        // 老消息 / 非指令消息照常解码。
        let action: String?
        let taskBrief: String?
        let runnerKind: String?

        enum CodingKeys: String, CodingKey {
            case text, kind, question, status, action
            case permissionRequestId = "permission_request_id"
            case taskBrief = "task_brief"
            case runnerKind = "runner_kind"
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
        case relay
        case senderDisplayName = "sender_display_name"
    }

    /// Best display text: explicit payload text → summary → empty.
    var displayText: String { payload?.text ?? summary ?? "" }
    /// True if this row is an ask_human interaction card.
    var isInteraction: Bool { payload?.kind == "interaction" }
}

/// `listCrewWhiteboardPage` 的响应：白板条目 + 续传游标（接合 v2 block 3）。
/// `lastCursor` = 本批最大 created_at；空批为 nil（游标原地不动）。
struct CrewWhiteboardPage: Decodable {
    let whiteboard: [CrewWhiteboardEntry]
    let lastCursor: String?
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

/// `POST /v1/device-grant/mint` 的响应（家族凭据静默换 grant）。形状对齐
/// device-login consume：grant token + 元数据。字段全 optional 解耦 edge 端
/// 演进，调用方只硬依赖 `deviceGrantToken`。
struct MintGrantResponse: Decodable {
    let deviceGrantToken: String?
    let grantId: String?
    let subjectId: String?
    let grantKind: String?
    let scopes: [String]?
}

// MARK: - Error type

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
