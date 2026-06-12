import SwiftUI

/// Cross-platform formatting / label helpers for the v2 wallet (PNC ledger +
/// packs). Shared by the iOS `WalletV2View` and the native macOS
/// `MacWalletView` so the two render the same numbers, labels, and
/// threshold/expiry copy without each keeping its own copy.
enum WalletV2Format {

    /// micros → "X.XX" PNC string (2 decimals). 1 PNC = 1_000_000 micros.
    static func formatPnc(_ micros: Int) -> String {
        let pnc = Double(micros) / 1_000_000.0
        return pncFormatter.string(from: NSNumber(value: pnc)) ?? String(format: "%.2f", pnc)
    }

    private static let pncFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    struct Notice { let text: String; let icon: String; let color: Color }

    static func thresholdNotice(_ state: String) -> Notice? {
        switch state {
        case "low":
            return Notice(text: "余额偏低，建议充值。", icon: "exclamationmark.circle",
                          color: Theme.Palette.gold)
        case "throttle":
            return Notice(text: "余额不足，已切换到经济模式（只用便宜模型）。",
                          icon: "tortoise.fill", color: Theme.Palette.danger)
        case "exhausted":
            return Notice(text: "余额花完了，请充值后继续。", icon: "xmark.octagon.fill",
                          color: Theme.Palette.danger)
        default:
            return nil
        }
    }

    static func channelLabel(_ channel: String) -> String {
        switch channel {
        case "iap_ios", "iap_macos": return "App 内购买"
        case "lemon_squeezy":        return "网页充值"
        case "admin_grant":          return "官方赠送"
        case "group_topup":          return "群账户注资"
        case "group_refund":         return "退群返还"
        case "v1_migration":         return "历史余额迁移"
        default:                     return "充值包"
        }
    }

    static func entryLabel(_ type: String) -> String {
        switch type {
        case "debit":       return "消费"
        case "credit":      return "充值"
        case "adjustment":  return "调整"
        case "refund":      return "退款"
        case "expired":     return "过期"
        case "group_topup": return "群注资"
        case "group_refund":return "退群返还"
        case "overdraft":   return "透支"
        default:            return type
        }
    }

    struct ExpiryNotice { let text: String; let urgent: Bool }

    static func expiryNotice(_ iso: String?) -> ExpiryNotice? {
        guard let iso else { return nil }
        let date = isoParser.date(from: iso) ?? isoParserNoFrac.date(from: iso)
        guard let date else { return nil }
        let days = Int(date.timeIntervalSinceNow / 86_400)
        if days < 0 {
            return ExpiryNotice(text: "已过期", urgent: true)
        }
        if days <= 7 {
            return ExpiryNotice(text: "还剩 \(days) 天过期", urgent: true)
        }
        return ExpiryNotice(text: "\(dayFormatter.string(from: date)) 过期", urgent: false)
    }

    static func formatTime(_ iso: String) -> String {
        let date = isoParser.date(from: iso) ?? isoParserNoFrac.date(from: iso)
        guard let date else { return iso }
        return displayFormatter.string(from: date)
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoParserNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
