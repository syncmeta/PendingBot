import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Cross-platform crew-session viewer API (T4.5)
//
// The crew list + server-session read surface shared by **both** PendingBot
// clients: iOS/iPad (`Sources/Features/Crew/*`) and the macOS app
// (`Sources/Mac/*`). Pure data models + network calls, no UI dependency, so
// this file carries NO platform gate — it compiles into the iOS and macOS
// targets alike. The crew *chat / detail / create* surface stays iOS-only in
// `CrewAPI.swift`; only the viewer needs cross-platform reach.
// ─────────────────────────────────────────────────────────────────────

/// `GET /v1/crews` list row. Field shape mirrors edge response:
/// `id / title / responsibleSubjectId / runtimeLocation / tag /
/// captainBotId / status / createdAt / updatedAt`.
///
/// `runtimeLocation` is a string (not an enum) so we never reject unknown
/// values from the wire — spec v2 §6.2 reserves room for v1.1 runner
/// locations; clients fall back to displaying the raw string.
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

/// One row from `GET /v1/crew/:id/sessions` (snake_case, created_at DESC).
struct CrewSessionRow: Decodable, Identifiable, Hashable {
    let id: String
    let crew_conversation_id: String
    let responsible_subject_id: String?
    let runner_kind: String?
    let status: String
    let task_brief: String?
    let progress_summary: String?
    let created_at: String
    let started_at: String?
    let finished_at: String?
}

/// One transcript event from a server crew session's durable log
/// (`GET /v1/crew/sessions/:sessionId/events`, oldest first). This is what the
/// T4.5 read-only viewer renders to follow a session running on **another**
/// host. The runner publishes these via the register→create→claim→events→finish
/// lifecycle.
///
/// Named `CrewSessionLogEvent` (not `CrewSessionEvent`) — the latter already
/// names the realtime-change struct in `RealtimeManager.swift`. snake_case
/// literal keys match this client's bare JSONDecoder (the read route returns
/// raw supabase rows). `payload` is free-form and unused by the viewer for now.
struct CrewSessionLogEvent: Decodable, Identifiable, Hashable {
    let id: String
    let event_type: String
    let visibility: String
    let summary: String?
    let created_at: String
}

extension APIClient {
    /// `GET /v1/crews` — list crews caller can see.
    func listCrewsV2() async throws -> [CrewSummaryV2] {
        struct Response: Decodable { let crews: [CrewSummaryV2] }
        let response: Response = try await get("v1/crews")
        return response.crews
    }

    /// `GET /v1/crew/:id/sessions` — crew session rows (created_at DESC, 100).
    func getCrewSessions(_ crewId: String) async throws -> [CrewSessionRow] {
        struct Response: Decodable { let items: [CrewSessionRow] }
        let r: Response = try await get("v1/crew/\(crewId)/sessions")
        return r.items
    }

    /// `GET /v1/crew/sessions/:sessionId/events` — the durable transcript log
    /// for one session (oldest first). What the T4.5 viewer renders to follow a
    /// session without being its runner. Needs `crew:read`.
    ///
    /// **Path is singular `/v1/crew/sessions/...`** — `routes/crew.ts` (sessions
    /// / events / mailbox) mounts at `/v1/crew`; the plural `/v1/crews` is the
    /// list/get/create-crew surface. Easy to mix up — a past session ate a 404 here.
    func getCrewSessionEvents(sessionId: String) async throws -> [CrewSessionLogEvent] {
        struct Response: Decodable { let items: [CrewSessionLogEvent] }
        let r: Response = try await get("v1/crew/sessions/\(sessionId)/events")
        return r.items
    }
}
