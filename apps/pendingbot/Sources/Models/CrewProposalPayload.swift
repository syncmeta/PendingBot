import Foundation

/// Decoded shape of a `log_kind='crew_proposal'` row's `log_payload`
/// jsonb. Mirrors the writer in start-crew.ts + the stamp side in
/// `messages.ts /crew-proposal/decide`.
struct CrewProposalPayload: Decodable, Hashable {
    let proposed_by_bot_id: String?
    let proposed_name: String?
    let proposed_tag: String?
    let proposed_working_directory: String?
    let proposed_parent_crew_id: String?
    let proposed_initial_brief: String?
    /// One of "pending" / "approved" / "rejected". A missing field
    /// (very old / malformed row) is treated as "pending" by the UI.
    let status: String?
    /// Set after a decide call. `decided_by` is the user id that
    /// approved or rejected; `crew_id` is the new crew row id (approve
    /// only). All ISO 8601 timestamps.
    let crew_id: String?
    let decided_by: String?
    let decided_at: String?
    /// Set when `decide` failed to attach the new crew to its proposed
    /// parent (e.g. cross-subject parent rejected the share). Surfaced
    /// in the card as a follow-up nudge.
    let parent_attach_error: String?

    var statusKind: Status {
        switch (status ?? "pending").lowercased() {
        case "approved": return .approved
        case "rejected": return .rejected
        default: return .pending
        }
    }

    enum Status: Hashable {
        case pending
        case approved
        case rejected
    }
}
