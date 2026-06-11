import Foundation
import SwiftUI

// Crew-proposal decide handler for the bot-initiated crew flow (spec
// v2 §6.4). Lives alongside ConversationView state via an extension —
// the card view itself is rendered in ConversationView.swift's main
// timeline loop, which calls into here when the user taps a button.

extension ConversationView {

    /// Decision payload mirrors the edge enum exactly so the iOS user
    /// of this method doesn't need to know about CrewAPI's nested
    /// enum.
    enum CrewProposalDecisionKind {
        case approve
        case reject

        // APIClient.CrewProposalDecision lives in the now-cross-platform Crew
        // slice (Features/Crew/CrewAPI.swift), so this bridge compiles on both
        // iOS and macOS.
        fileprivate var apiValue: APIClient.CrewProposalDecision {
            switch self {
            case .approve: return .approve
            case .reject:  return .reject
            }
        }
    }

    /// Approve or reject a pending crew_proposal card. The card view
    /// disables both buttons while this is in flight (via
    /// `crewProposalBusy`), and the local payload's status is
    /// optimistically updated on success so the card flips to its
    /// "已确认 / 已拒绝" badge state immediately.
    ///
    /// Cross-platform: the decide endpoint (`api.decideCrewProposal`) now lives
    /// in the cross-platform Crew slice, so crew-proposal approve/reject works
    /// on both iOS and macOS.
    func decideCrewProposal(_ messageId: String, decision: CrewProposalDecisionKind) async {
        guard let api else { return }
        // Sanity gate — must have a payload to act on, and it must
        // still be 'pending'. The button is disabled in the
        // non-pending state, but defend against a stale tap.
        guard let payload = crewProposalsByMsgId[messageId],
              payload.statusKind == .pending else {
            return
        }

        crewProposalBusy.insert(messageId)
        defer { crewProposalBusy.remove(messageId) }

        do {
            let response = try await api.decideCrewProposal(
                messageId: messageId,
                decision: decision.apiValue
            )
            // Server is authoritative — but the response only carries
            // ok/status/crewId, not the full payload. Patch the local
            // copy so the card re-renders without waiting for the
            // next loadHistory. The full row will be reconciled
            // server-side on next conversation open.
            var patched = payload
            switch response.status {
            case "approved":
                patched = CrewProposalPayload(
                    proposed_by_bot_id: payload.proposed_by_bot_id,
                    proposed_name: payload.proposed_name,
                    proposed_tag: payload.proposed_tag,
                    proposed_working_directory: payload.proposed_working_directory,
                    proposed_parent_crew_id: payload.proposed_parent_crew_id,
                    proposed_initial_brief: payload.proposed_initial_brief,
                    status: "approved",
                    crew_id: response.crewId,
                    decided_by: AccountStore.shared.current?.id,
                    decided_at: ISO8601DateFormatter().string(from: Date()),
                    parent_attach_error: response.parentAttachError
                )
                Haptics.success()
            case "rejected":
                patched = CrewProposalPayload(
                    proposed_by_bot_id: payload.proposed_by_bot_id,
                    proposed_name: payload.proposed_name,
                    proposed_tag: payload.proposed_tag,
                    proposed_working_directory: payload.proposed_working_directory,
                    proposed_parent_crew_id: payload.proposed_parent_crew_id,
                    proposed_initial_brief: payload.proposed_initial_brief,
                    status: "rejected",
                    crew_id: nil,
                    decided_by: AccountStore.shared.current?.id,
                    decided_at: ISO8601DateFormatter().string(from: Date()),
                    parent_attach_error: nil
                )
                Haptics.tap()
            default:
                // Unknown status — refresh from server.
                await loadHistory()
                return
            }
            crewProposalsByMsgId[messageId] = patched
        } catch {
            // Edge 409 crew_proposal_already_decided is the expected
            // "someone else acted on this card from a different
            // device" path. Reload history so we pick up the
            // authoritative decision and surface the resulting
            // status. Other errors get the standard error banner.
            if case let APIError.http(status, code, _, _) = error,
               status == 409,
               code == "crew_proposal_already_decided" {
                await loadHistory()
                return
            }
            self.error = error.localizedDescription
        }
    }
}
