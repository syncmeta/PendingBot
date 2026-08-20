import Foundation

/// Decoded shape of a `log_kind='permission_request'` row's `log_payload`
/// jsonb. Mirrors the writer in 20260528151836_permission_request_mode.sql.
struct PermissionRequestPayload: Decodable, Hashable {
    /// The permission_requests.id — the decide endpoint takes this as
    /// its path param.
    let permission_request_id: String?
    /// Short action description the agent passed in.
    let action: String?
    /// 'low' | 'medium' | 'high'. Falls back to 'medium' visually if
    /// missing / unknown.
    let risk_level: String?
    /// Free-form structured detail the agent provided (commands, paths,
    /// reasoning). Rendered as a JSON-flavoured preview if non-empty.
    let detail: PermissionRequestDetailValue?
    /// 'pending' | 'approved' | 'denied' (the DB enum). Missing → pending.
    let status: String?
    /// ISO 8601 timestamp the server stamps on decide.
    let decided_at: String?

    var statusKind: Status {
        switch (status ?? "pending").lowercased() {
        case "approved": return .approved
        case "denied", "rejected": return .denied
        case "expired": return .expired
        case "cancelled": return .cancelled
        default: return .pending
        }
    }

    var riskKind: Risk {
        switch (risk_level ?? "medium").lowercased() {
        case "low": return .low
        case "high": return .high
        default: return .medium
        }
    }

    enum Status: Hashable {
        case pending
        case approved
        case denied
        case expired
        case cancelled
    }

    enum Risk: Hashable {
        case low
        case medium
        case high
    }
}
