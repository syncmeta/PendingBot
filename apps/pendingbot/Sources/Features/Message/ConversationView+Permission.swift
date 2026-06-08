import Foundation
import SwiftUI

// Permission-request decide handler for spec v2 §10's manual mode.
// Sister of ConversationView+CrewProposal — same shape, different
// vocabulary. Lives alongside ConversationView state via an extension;
// the card view is rendered in ConversationView.swift's main timeline
// loop, which calls into here when the user taps a button.

extension ConversationView {

    /// Decision payload mirrors the edge enum exactly so the iOS user of
    /// this method doesn't need to know about CrewAPI's nested enum.
    enum PermissionRequestDecisionKind {
        case approve
        case reject

        // APIClient.PermissionRequestDecision lives in the iOS-only Crew
        // slice (Features/Crew/CrewAPI.swift). iOS-only until that migrates.
        #if os(iOS)
        fileprivate var apiValue: APIClient.PermissionRequestDecision {
            switch self {
            case .approve: return .approve
            case .reject:  return .reject
            }
        }
        #endif
    }

    /// Approve or reject a pending permission_request card. The card
    /// view disables both buttons while this is in flight (via
    /// `permissionRequestBusy`), and the local payload's status is
    /// optimistically updated on success so the card flips to its
    /// "已批准 / 已拒绝" badge state immediately.
    ///
    /// `messageId` is the messages.id of the synthesised log row; the
    /// underlying permission_requests.id is read from the payload.
    ///
    /// iOS-only: the decide endpoint (`api.decidePermissionRequest`) is part
    /// of the iOS-only Crew slice. On macOS the card still renders but the
    /// decision round-trip is unavailable (tech-debt until Crew migrates).
    #if os(iOS)
    func decidePermissionRequest(_ messageId: String, decision: PermissionRequestDecisionKind) async {
        guard let api else { return }
        guard let payload = permissionRequestsByMsgId[messageId],
              payload.statusKind == .pending else {
            return
        }
        guard let requestId = payload.permission_request_id else {
            self.error = "Permission request 缺少 id,无法决定"
            return
        }

        permissionRequestBusy.insert(messageId)
        defer { permissionRequestBusy.remove(messageId) }

        do {
            let response = try await api.decidePermissionRequest(
                id: requestId,
                decision: decision.apiValue
            )
            // Patch the local copy so the card re-renders without
            // waiting for the next loadHistory. The server has already
            // stamped the messages row's log_payload (the RPC writes
            // both) — next load picks up the same state.
            var patched = payload
            switch response.permissionRequest.status {
            case "approved":
                patched = PermissionRequestPayload(
                    permission_request_id: payload.permission_request_id,
                    action: payload.action,
                    risk_level: payload.risk_level,
                    detail: payload.detail,
                    status: "approved",
                    decided_at: response.permissionRequest.decided_at
                        ?? ISO8601DateFormatter().string(from: Date())
                )
                Haptics.success()
            case "denied", "rejected":
                patched = PermissionRequestPayload(
                    permission_request_id: payload.permission_request_id,
                    action: payload.action,
                    risk_level: payload.risk_level,
                    detail: payload.detail,
                    status: "denied",
                    decided_at: response.permissionRequest.decided_at
                        ?? ISO8601DateFormatter().string(from: Date())
                )
                Haptics.tap()
            default:
                // Unknown status — refresh from server.
                await loadHistory()
                return
            }
            permissionRequestsByMsgId[messageId] = patched
        } catch {
            // 409 permission_request_already_decided is the expected
            // "someone else acted on this card from a different
            // device" path. Reload history so we pick up the
            // authoritative decision.
            if case let APIError.http(status, code, _, _) = error,
               status == 409,
               code == "permission_request_already_decided" {
                await loadHistory()
                return
            }
            self.error = error.localizedDescription
        }
    }
    #else
    func decidePermissionRequest(_ messageId: String, decision: PermissionRequestDecisionKind) async {
        // No-op on macOS — the permission decide endpoint isn't available yet.
    }
    #endif
}
