import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Permission Request decide endpoint (spec v2 §10)
//
// The `request_permission` agent tool drops a `role='log'` row with
// `log_kind='permission_request'` into the conversation. PendingBot
// renders it as a card (PermissionRequestCardView); tapping 批准 / 拒绝
// hits this endpoint to bind the decision. The decide handler lives in
// `ConversationView+Permission.swift`.
//
// (Extracted from the former `CrewAPI.swift` when the iOS crew surface
// was removed — the permission-request card is a standalone conversation
// feature, not part of the crew collaboration UI.)
// ─────────────────────────────────────────────────────────────────────

extension APIClient {
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
}
