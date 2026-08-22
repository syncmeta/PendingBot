import Foundation

/// 预设(onboarding)会话那批消息被刻意钉在纪元附近 —— 日期不是"过期时间戳",
/// 是设计好的标记。这里是**客户端这一侧的唯一一处**常量。
///
/// 服务端的对应常量是 `pendingbot.preset_epoch_base_ts()` /
/// `pendingbot.preset_epoch_window_end()`,定义在
/// `supabase/migrations/20260822132304_preset_epoch_1970_01_02.sql`。
/// 要挪这个时间:改那条迁移里的常量函数 + 改这里的 `base`,两边各一处,
/// 别再把字面量抄回散落的判断里。
enum PresetEpoch {
    /// 预设会话的基准戳:1970-01-02 12:34(北京时间)= 04:34:00 UTC。
    /// (86400 + 4*3600 + 34*60)
    static let base = Date(timeIntervalSince1970: 102_840)

    /// 纪元窗口的右边界:1971-01-01 00:00:00 UTC(365 * 86400)。
    /// 落在窗口内 = 预置的;真实消息一律在窗口之外。判据用年份而不是"基准戳
    /// 当天",这样以后再挪基准戳也不会像 `< 1970-01-02` 那样把判断反过来。
    static let windowEnd = Date(timeIntervalSince1970: 31_536_000)

    /// 这个时间戳是不是预置消息的标记。
    static func isPreseeded(_ date: Date) -> Bool { date < windowEnd }
}
