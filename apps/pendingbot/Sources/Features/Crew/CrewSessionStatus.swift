import SwiftUI

/// The lifecycle status of a crew session, normalized from the server's
/// free-form `crew_sessions.status` string into the buckets the 机组 tab
/// renders. Unknown strings fall back to `.queued` visually (a session the
/// UI doesn't understand is safest shown as "pending").
enum CrewSessionStatus: Hashable {
    case queued          // queued / waiting_runner — 排队中
    case running         // running — 运行中
    case waitingPermission // waiting_permission — 待审批(琥珀,置顶)
    case blocked         // blocked — 受阻
    case completed       // completed / done — 已完成
    case failed          // failed / error — 失败
    case cancelled       // cancelled — 已取消

    init(raw: String) {
        switch raw.lowercased() {
        case "running", "in_progress": self = .running
        case "waiting_permission", "awaiting_permission", "needs_permission": self = .waitingPermission
        case "blocked": self = .blocked
        case "completed", "done", "succeeded": self = .completed
        case "failed", "error": self = .failed
        case "cancelled", "canceled": self = .cancelled
        case "queued", "waiting_runner", "pending", "created": self = .queued
        default: self = .queued
        }
    }

    /// True while the session is not in a terminal state — drives the
    /// 「进行中」segment filter + whether to keep polling / hold the WS open.
    var isActive: Bool {
        switch self {
        case .completed, .failed, .cancelled: return false
        default: return true
        }
    }

    var label: String {
        switch self {
        case .queued:            return "排队中"
        case .running:           return "运行中"
        case .waitingPermission: return "待审批"
        case .blocked:           return "受阻"
        case .completed:         return "已完成"
        case .failed:            return "失败"
        case .cancelled:         return "已取消"
        }
    }

    var tint: Color {
        switch self {
        case .queued:            return Theme.Palette.inkMuted
        case .running:           return Theme.Palette.accent
        case .waitingPermission: return Theme.Palette.amber
        case .blocked:           return Theme.Palette.amber
        case .completed:         return Theme.Palette.success
        case .failed:            return Theme.Palette.danger
        case .cancelled:         return Theme.Palette.inkMuted
        }
    }

    var background: Color {
        switch self {
        case .waitingPermission, .blocked: return Theme.Palette.amberBg
        case .completed:                   return Theme.Palette.surfaceMuted
        case .failed:                      return Theme.Palette.dangerBg
        default:                           return Theme.Palette.surfaceMuted
        }
    }

    var symbol: String {
        switch self {
        case .queued:            return "clock"
        case .running:           return "bolt.fill"
        case .waitingPermission: return "hand.raised.fill"
        case .blocked:           return "exclamationmark.triangle.fill"
        case .completed:         return "checkmark.circle.fill"
        case .failed:            return "xmark.octagon.fill"
        case .cancelled:         return "slash.circle"
        }
    }
}

/// A small pill rendering a session status. Used on list rows + the detail
/// banner.
struct CrewStatusBadge: View {
    let status: CrewSessionStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(status.label)
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous).fill(status.background)
        )
    }
}

// MARK: - ISO date helpers

enum CrewDate {
    /// Parse an ISO-8601 timestamp string (with or without fractional
    /// seconds) into a Date. The server emits Postgres `timestamptz` which
    /// supabase returns with microsecond precision.
    static func parse(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }

    /// Relative "3分钟前" style for list subtitles + banner.
    static func relative(_ iso: String?) -> String {
        guard let date = parse(iso) else { return "" }
        return RelativeMessageTime.format(date, style: .tombstone)
    }
}
