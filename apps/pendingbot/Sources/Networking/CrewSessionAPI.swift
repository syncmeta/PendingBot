import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - 机组 tab data layer (coding-session remote control)
//
// PendingBot is a remote control + monitor: it lists crew sessions, reads
// their event stream, pulls permission requests, creates queued sessions,
// and steers/cancels via the SessionProxyDO WebSocket (SessionProxyClient).
// Execution always happens on a runner (PendingCrew Mac). See
// docs/superpowers/specs/2026-07-05-pendingbot-crew-tab-remote-design.md.
//
// Reads go through the Worker (not supabase-swift directly) because the
// aggregate endpoints apply RLS-scoped visibility server-side. Row structs
// mirror the edge `select(...)` snake_case columns verbatim.
// ─────────────────────────────────────────────────────────────────────

// MARK: - Wire row shapes

/// A `crew_sessions` row as returned by `GET /v1/crew/sessions` and
/// `GET /v1/crew/:id/sessions`. Only the columns the tab renders.
struct CrewSessionRow: Decodable, Hashable, Identifiable {
    let id: String
    let crew_conversation_id: String
    let responsible_subject_id: String?
    let runner_kind: String
    let status: String
    let task_brief: String
    let progress_summary: String?
    let created_at: String?
    /// Only the aggregate `/v1/crew/sessions` endpoint returns this.
    let updated_at: String?
    let started_at: String?
    let finished_at: String?
}

/// A crew row as returned by `GET /v1/crew`. The row is keyed by
/// `conversation_id` — that's the id `POST /v1/crew/:id/sessions` and the
/// session's `crew_conversation_id` reference.
struct CrewRow: Decodable, Hashable, Identifiable {
    let conversation_id: String
    let responsible_subject_id: String?
    let title: String?
    let status: String?
    let runtime_kind: String?
    let updated_at: String?

    var id: String { conversation_id }
}

/// A `session_events` row as returned by `GET /v1/crew/sessions/:id/events`.
struct SessionEventRow: Decodable, Hashable, Identifiable {
    let id: String
    let crew_session_id: String
    let event_type: String
    let visibility: String?
    let summary: String?
    let payload: PermissionRequestDetailValue?
    let created_at: String?
}

/// A `permission_requests` row as returned by
/// `GET /v1/crew/sessions/:id/permission-requests`.
struct PermissionRequestRowFull: Decodable, Hashable, Identifiable {
    let id: String
    let crew_session_id: String
    let requested_action: String?
    let request_kind: String?
    let risk_level: String?
    let detail: PermissionRequestDetailValue?
    let status: String?
    let reply_text: String?
    let requested_at: String?
    let decided_by_user_id: String?
    let decided_at: String?

    /// Adapt the server row into the shared `PermissionRequestPayload` shape so
    /// `PermissionRequestCardView` can render it unchanged. (The card was built
    /// for a `log_kind='permission_request'` payload; the columns line up.)
    var asPayload: PermissionRequestPayload {
        PermissionRequestPayload(
            permission_request_id: id,
            action: requested_action,
            risk_level: risk_level,
            detail: detail,
            status: status,
            decided_at: decided_at
        )
    }
}

/// A `runner_hosts` row as returned by `GET /v1/runner-hosts`. Only the
/// online-status fields the new-task sheet needs.
struct RunnerHostRow: Decodable, Hashable, Identifiable {
    let id: String
    let responsible_subject_id: String?
    let platform: String?
    let display_name: String?
    let allowed_runner_kinds: PermissionRequestDetailValue?
    let status: String?
    let last_seen_at: String?
}

// MARK: - Endpoint wrappers

extension APIClient {
    private struct ItemsEnvelope<T: Decodable>: Decodable { let items: [T] }

    /// GET /v1/crew — crews visible to the caller (for titles + new-task sheet).
    func listCrews() async throws -> [CrewRow] {
        let env: ItemsEnvelope<CrewRow> = try await get("v1/crew")
        return env.items
    }

    /// GET /v1/crew/sessions — cross-crew aggregate, updated_at desc.
    func listAllSessions() async throws -> [CrewSessionRow] {
        let env: ItemsEnvelope<CrewSessionRow> = try await get("v1/crew/sessions")
        return env.items
    }

    /// GET /v1/crew/:crewConversationId/sessions — one crew's sessions.
    func listSessions(crewConversationId: String) async throws -> [CrewSessionRow] {
        let env: ItemsEnvelope<CrewSessionRow> = try await get("v1/crew/\(crewConversationId)/sessions")
        return env.items
    }

    /// GET /v1/crew/sessions/:id/events — the transcript event stream (asc).
    func getSessionEvents(sessionId: String) async throws -> [SessionEventRow] {
        let env: ItemsEnvelope<SessionEventRow> = try await get("v1/crew/sessions/\(sessionId)/events")
        return env.items
    }

    /// GET /v1/crew/sessions/:id/permission-requests — pending + resolved.
    func listPermissionRequests(sessionId: String) async throws -> [PermissionRequestRowFull] {
        let env: ItemsEnvelope<PermissionRequestRowFull> = try await get("v1/crew/sessions/\(sessionId)/permission-requests")
        return env.items
    }

    /// GET /v1/runner-hosts — runner online status (read-only here).
    func listRunnerHosts() async throws -> [RunnerHostRow] {
        let env: ItemsEnvelope<RunnerHostRow> = try await get("v1/runner-hosts")
        return env.items
    }

    /// POST /v1/crew/:crewConversationId/sessions — create a queued session.
    /// Returns the new session id.
    func createSession(crewConversationId: String, runnerKind: String, taskBrief: String) async throws -> String {
        struct Body: Encodable { let runnerKind: String; let taskBrief: String }
        struct Resp: Decodable { let sessionId: String }
        let resp: Resp = try await post(
            "v1/crew/\(crewConversationId)/sessions",
            body: Body(runnerKind: runnerKind, taskBrief: taskBrief)
        )
        return resp.sessionId
    }

    /// PATCH /v1/sessions/:id/permission-mode — override (nil = inherit crew).
    func setSessionPermissionMode(sessionId: String, mode: String?) async throws {
        struct Body: Encodable { let mode: String? }
        try await patchVoid("v1/sessions/\(sessionId)/permission-mode", body: Body(mode: mode))
    }
}

// MARK: - Runner kind display

/// The `runner_kind` enum values the server accepts, plus display helpers.
enum CrewRunnerKind: String, CaseIterable, Identifiable {
    case claude = "local_claude_code"
    case codex = "local_codex"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        }
    }

    /// Short badge label for the list row subtitle.
    static func shortLabel(_ raw: String) -> String {
        switch raw {
        case "local_claude_code": return "claude"
        case "local_codex":       return "codex"
        case "local_opencode":    return "opencode"
        case "local_kilo":        return "kilo"
        case "cloud_sandbox":     return "cloud"
        default:                  return raw
        }
    }
}
