import Foundation
import SwiftUI

/// Renders a message's timestamp the way WeChat / iMessage do — a fuzzy
/// "几秒前 / 几分钟前 / 昨天 HH:mm / 11/12 HH:mm" string, locale-fixed to
/// zh_Hans_CN since the product is Chinese-default.
///
/// Two styles:
///   • .pill  — used by the inter-bubble time separator. Shorter at the
///              recent end ("几秒前" / "刚刚"), absolute past today.
///   • .tombstone — used by the recall log row's "我撤回了 X 的一条消息".
///                  Always reads as a duration phrase ("几秒前"),
///                  matches WeChat's exact wording.
enum RelativeMessageTime {
    enum Style {
        case pill
        case tombstone
    }

    static func format(_ date: Date, now: Date = Date(), style: Style = .pill) -> String {
        let interval = now.timeIntervalSince(date)

        switch style {
        case .tombstone:
            return durationPhrase(interval)
        case .pill:
            return pillPhrase(date, interval: interval, now: now)
        }
    }

    // MARK: - Tombstone-style (always a duration)

    /// "刚刚" / "X 秒前" / "X 分钟前" / "X 小时前" / "X 天前" / "X 个月前" / "X 年前"
    private static func durationPhrase(_ interval: TimeInterval) -> String {
        if interval < 10 {
            return "刚刚"
        }
        if interval < 60 {
            return "\(Int(interval)) 秒前"
        }
        if interval < 3600 {
            return "\(Int(interval / 60)) 分钟前"
        }
        if interval < 86_400 {
            return "\(Int(interval / 3600)) 小时前"
        }
        if interval < 86_400 * 30 {
            return "\(Int(interval / 86_400)) 天前"
        }
        if interval < 86_400 * 365 {
            return "\(Int(interval / (86_400 * 30))) 个月前"
        }
        return "\(Int(interval / (86_400 * 365))) 年前"
    }

    // MARK: - Pill-style (mixed relative + absolute)

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "zh_Hans_CN")
        return c
    }()

    private static let timeOfDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateAndTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()

    private static func pillPhrase(_ date: Date, interval: TimeInterval, now: Date) -> String {
        // Within 1 minute → "刚刚"
        if interval < 60 {
            return "刚刚"
        }
        // Same calendar day → just HH:mm
        if calendar.isDateInToday(date) {
            return timeOfDayFormatter.string(from: date)
        }
        // Yesterday → "昨天 HH:mm"
        if calendar.isDateInYesterday(date) {
            return "昨天 " + timeOfDayFormatter.string(from: date)
        }
        // Same year → "M月d日 HH:mm"
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return dateAndTimeFormatter.string(from: date)
        }
        // Older → "yyyy年M月d日 HH:mm"
        return fullDateFormatter.string(from: date)
    }
}

extension RelativeMessageTime {
    /// Inter-bubble gap threshold. Render a time separator when the next
    /// message is more than this many seconds after the previous one,
    /// matching the WeChat 5-min cadence.
    static let separatorGapSeconds: TimeInterval = 5 * 60
}

/// Centered timestamp pill inserted between messages whose time-gap to
/// the previous bubble crossed RelativeMessageTime.separatorGapSeconds.
/// Visually quiet — secondary color, small caption font — so it doesn't
/// compete with the bubbles.
struct TimeSeparatorPill: View {
    let date: Date

    var body: some View {
        Text(RelativeMessageTime.format(date, style: .pill))
            .font(Theme.Fonts.caption2)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
            .accessibilityLabel("时间:\(RelativeMessageTime.format(date, style: .pill))")
    }
}
