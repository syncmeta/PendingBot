#if os(iOS)
import SwiftUI

// PendingBot rendering for a session's `request_permission` card
// (spec v2 §10). Sister card to CrewProposalCard — mostly the same
// shape, just a different vocabulary.
//
// Backend story:
//   • A session (agent in Claude Code / Codex) calls the
//     `request_permission` tool. PendingCrew runner translates that
//     into POST /v1/sessions/:sessionId/request-permission.
//   • The edge route hits `create_permission_request` RPC, which
//     records a row in `permission_requests` AND writes a parallel
//     `crew_announcements` whiteboard card AND a `messages` log row
//     (role='log', log_kind='permission_request', log_payload =
//     { permission_request_id, action, risk_level, detail, status,
//       decided_at? }).
//   • A human with owner/admin authority on the responsible subject
//     approves / rejects via POST /v1/permission-requests/:id/decide.
//     The edge route updates `permission_requests.status` and stamps
//     the same status onto both the announcement and the messages row's
//     payloads so the card re-renders without a refetch.
//
// v1 caveat (T4.5): the underlying high-risk action is NOT actually
// paused when the agent calls request_permission — the prompt-side note
// tells the model to wait, but the runner doesn't enforce it yet. That
// enforcement lands with peer_device communication in T4.5.

// Payload + enum types live outside `#if os(iOS)` so the
// multiplatform target's emit-module pass on macOS still sees them when
// ConversationView (iOS-only logic, but compiled into the shared
// module) references them in its state-dict types. The card View itself
// stays inside `#if os(iOS)` further below.

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

/// Type-erased holder for `detail` — agents may pass arbitrary JSON,
/// and we just want to surface a one-shot preview, not parse a schema.
/// We coerce non-string values into their JSON-encoded representation
/// so the preview stays readable without forcing a strong schema.
enum PermissionRequestDetailValue: Hashable {
    case object([String: String])
    case raw(String)
}

extension PermissionRequestDetailValue: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let dict = try? c.decode([String: String].self) {
            self = .object(dict)
            return
        }
        // Try object-of-anything → coerce each value to a short string.
        if let dictAny = try? c.decode([String: JSONScalar].self) {
            var coerced: [String: String] = [:]
            for (k, v) in dictAny { coerced[k] = v.asString }
            self = .object(coerced)
            return
        }
        if let s = try? c.decode(String.self) {
            self = .raw(s)
            return
        }
        self = .raw("(detail)")
    }
}

/// One-cell JSON-scalar coercion helper — used to flatten heterogeneous
/// object values into a printable map without writing a custom decoder
/// for each agent's payload shape.
enum JSONScalar: Decodable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case other(String)

    var asString: String {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if n == floor(n), abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .bool(let b):   return b ? "true" : "false"
        case .null:          return "null"
        case .other(let s):  return s
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        self = .other("(complex)")
    }
}

#if os(iOS)
/// Centered card rendered inline in the timeline (or the crew
/// announcement stream once T4.6 lands the unified renderer). Same
/// surface area as `CrewProposalCardView` — same status badge, same
/// pending/decided footer split.
struct PermissionRequestCardView: View {
    let sessionLabel: String
    let payload: PermissionRequestPayload
    let busy: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

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
                .strokeBorder(borderColor, lineWidth: 0.6)
        )
        .padding(.horizontal, 12)
    }

    private var borderColor: Color {
        switch payload.riskKind {
        case .high:   return Color.red.opacity(0.35)
        case .medium: return Color.orange.opacity(0.25)
        case .low:    return Color.secondary.opacity(0.15)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(riskTint)
            Text("\(sessionLabel) 请求授权")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            riskBadge
            statusBadge
        }
    }

    private var riskTint: Color {
        switch payload.riskKind {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .secondary
        }
    }

    private var riskBadge: some View {
        let (label, tint): (String, Color) = {
            switch payload.riskKind {
            case .low:    return ("低风险", .secondary)
            case .medium: return ("中风险", .orange)
            case .high:   return ("高风险", .red)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch payload.statusKind {
        case .pending:
            EmptyView()
        case .approved:
            Label("已批准", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        case .denied:
            Label("已拒绝", systemImage: "xmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.12))
                .foregroundStyle(.red)
                .clipShape(Capsule())
        case .expired:
            Label("已过期", systemImage: "clock.badge.xmark")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.gray.opacity(0.15))
                .foregroundStyle(.gray)
                .clipShape(Capsule())
        case .cancelled:
            Label("已取消", systemImage: "minus.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.gray.opacity(0.15))
                .foregroundStyle(.gray)
                .clipShape(Capsule())
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(payload.action ?? "(无描述)")
                .font(.callout.weight(.semibold))
                .lineLimit(4)
            detailPreview
        }
    }

    @ViewBuilder
    private var detailPreview: some View {
        if let detail = payload.detail {
            switch detail {
            case .object(let dict):
                if !dict.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(dict.keys.sorted()), id: \.self) { key in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(key)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(dict[key] ?? "")
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            case .raw(let s) where !s.isEmpty:
                Text(s)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            case .raw:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch payload.statusKind {
        case .pending:
            HStack(spacing: 10) {
                Button(role: .destructive, action: onDeny) {
                    Label("拒绝", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(busy)

                Button(action: onApprove) {
                    Label("批准", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        case .approved, .denied, .expired, .cancelled:
            EmptyView()
        }
    }
}
#endif
#endif
