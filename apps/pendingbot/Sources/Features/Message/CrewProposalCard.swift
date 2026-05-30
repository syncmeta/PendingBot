#if os(iOS)
import SwiftUI

// PendingBot rendering for a bot's `start_crew` proposal (spec v2 §6.4).
//
// Backend story:
//   • A bot calls the `start_crew` tool (apps/edge/src/lib/bot-reply/
//     tools/start-crew.ts) during a turn.
//   • The tool writes a special log row into `messages` with
//     role='log', log_kind='crew_proposal', log_payload = { proposed_*,
//     status: 'pending', ... }. No crew is created yet.
//   • A human in the conv approves or rejects via
//     POST /v1/messages/:id/crew-proposal/decide — only then does the
//     edge worker call create_crew_with_captain.
//
// Rendering:
//   ConversationView+Loading synthesises a ChatMessage with
//   sender_type='crew_proposal_log' for each crew_proposal row, and
//   ConversationView's main loop swaps this card in instead of a
//   bubble. The card pulls the live payload from a sibling dict
//   keyed by message id (see ConversationView.crewProposalsByMsgId).
//
// Mac / iPad PendingCrew don't render this — Mac PendingBot timeline
// rendering is out of v1.0 scope. The card lives in PendingBot only.

#if os(iOS)
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

/// Centered confirmation card rendered inline in the conv timeline.
/// `onApprove` / `onReject` fire only when the proposal is still
/// `pending`; the buttons render as a status badge once the proposal
/// has been decided.
struct CrewProposalCardView: View {
    let proposingBotName: String
    let payload: CrewProposalPayload
    let busy: Bool
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.3.fill")
                .foregroundStyle(Color.accentColor)
            Text("\(proposingBotName) 提议创建 crew")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch payload.statusKind {
        case .pending:
            EmptyView()
        case .approved:
            Label("已确认", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        case .rejected:
            Label("已拒绝", systemImage: "xmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.12))
                .foregroundStyle(.red)
                .clipShape(Capsule())
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(payload.proposed_name ?? "未命名 crew")
                .font(.title3.weight(.semibold))
            if let tag = payload.proposed_tag?.trimmingCharacters(in: .whitespaces),
               !tag.isEmpty {
                Label(tag, systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let wd = payload.proposed_working_directory?.trimmingCharacters(in: .whitespaces),
               !wd.isEmpty {
                Label(wd, systemImage: "folder")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let parent = payload.proposed_parent_crew_id?.trimmingCharacters(in: .whitespaces),
               !parent.isEmpty {
                Label("作为子 crew 挂到 \(parent.prefix(8))…", systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let brief = payload.proposed_initial_brief?.trimmingCharacters(in: .whitespaces),
               !brief.isEmpty {
                Text(brief)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.top, 2)
            }
            if let err = payload.parent_attach_error, !err.isEmpty {
                // Crew was created but couldn't be attached to the
                // proposed parent — surface so the user knows to retry
                // the link manually. The card stays in "approved" state
                // because the crew itself exists.
                Label("挂父 crew 失败:\(err)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch payload.statusKind {
        case .pending:
            HStack(spacing: 10) {
                Button(role: .destructive, action: onReject) {
                    Label("拒绝", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(busy)

                Button(action: onApprove) {
                    Label("确认创建", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        case .approved, .rejected:
            EmptyView()
        }
    }
}
#endif
#endif
