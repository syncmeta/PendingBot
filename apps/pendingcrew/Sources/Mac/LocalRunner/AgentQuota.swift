// 纯 Foundation、不带平台门 —— McpServer(跨平台编译)的 get_quota 要用
// AgentQuotaFile;真正 macOS-only 的是 QuotaCenter(轮询/子进程),不在本文件。
import Foundation

/// 一个限额窗口的快照：`label`（人话窗名）+ 已用百分比 + 重置时刻（原样字符串，
/// claude 是本地化人话如 "Jul 5 at 4:39am (Asia/Shanghai)"，codex 是 ISO8601）。
struct AgentQuotaWindow: Codable, Equatable {
    let label: String
    let usedPercent: Int
    let resetsAt: String?
}

/// 某个 agent（claude / codex）的额度快照。两家都**只给百分比 + 重置时刻**，
/// 没有剩余 token 绝对值（2026-07-05 实测核对）。
struct AgentQuotaSnapshot: Codable, Equatable {
    let agent: String              // "claude" | "codex"
    let windows: [AgentQuotaWindow]
    let fetchedAt: String          // ISO8601，消费方据此显示新鲜度

    /// 给 UI / get_quota 工具的一行摘要，如 "session 80% · 周(全模型) 23%"。
    var summary: String {
        windows.map { w in
            w.usedPercent >= 0 ? "\(w.label) \(w.usedPercent)%" : w.label
        }.joined(separator: " · ")
    }

    /// 5 小时滚动窗（claude 的 "session" / codex 的 "5小时窗"）。
    var fiveHourWindow: AgentQuotaWindow? {
        windows.first { $0.label == "session" || $0.label == "5小时窗" }
    }

    /// 周窗（claude 取「全模型」总窗,模型分窗只进 tooltip；codex 的 "周窗"）。
    var weeklyWindow: AgentQuotaWindow? {
        windows.first { $0.label == "周(全模型)" || $0.label == "周窗" }
    }
}

/// quota.json 的文件形状 —— app 的 `QuotaCenter` 定时写、helper 的 `get_quota`
/// 工具读（离线 helper 唯一能碰的共享文件层，与白板/控制通道同 `--dir`）。
struct AgentQuotaFile: Codable, Equatable {
    var claude: AgentQuotaSnapshot?
    var codex: AgentQuotaSnapshot?
}

/// `claude -p "/usage"` 输出的文本解析（实测 2.1.201：纯本地 control-request，
/// 不烧额度）。行形如：
///   Current session: 80% used · resets Jul 5 at 4:39am (Asia/Shanghai)
///   Current week (all models): 23% used · resets Jul 5 at 10:59am (Asia/Shanghai)
///   Current week (Fable): 18% used · resets Jul 5 at 10:59am (Asia/Shanghai)
/// 只认含 "% used" 的行，其余（Last 24h 统计等）忽略。窗名翻译成短中文。
enum ClaudeUsageTextParser {
    static func parse(_ text: String, now: Date = Date()) -> AgentQuotaSnapshot? {
        var windows: [AgentQuotaWindow] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let usedRange = line.range(of: "% used"),
                  let colon = line.range(of: ": ") else { continue }
            let label = String(line[line.startIndex..<colon.lowerBound])
            let percentText = line[colon.upperBound..<usedRange.lowerBound]
            guard let percent = Int(percentText.trimmingCharacters(in: .whitespaces)) else { continue }
            var resets: String? = nil
            if let r = line.range(of: "resets ") {
                resets = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            windows.append(AgentQuotaWindow(
                label: shortLabel(label), usedPercent: percent, resetsAt: resets))
        }
        guard !windows.isEmpty else { return nil }
        return AgentQuotaSnapshot(
            agent: "claude", windows: windows,
            fetchedAt: ISO8601DateFormatter().string(from: now))
    }

    /// "Current session" → "session"（5 小时滚动窗）；"Current week (all models)" →
    /// "周(全模型)"；"Current week (Fable)" → "周(Fable)"。没认出的原样保留 ——
    /// claude 改文案时宁可显示英文原文也别丢数据。
    static func shortLabel(_ raw: String) -> String {
        if raw == "Current session" { return "session" }
        if raw == "Current week (all models)" { return "周(全模型)" }
        if raw.hasPrefix("Current week ("), raw.hasSuffix(")") {
            let inner = raw.dropFirst("Current week (".count).dropLast()
            return "周(\(inner))"
        }
        return raw
    }
}

/// claude `/usage` 输出里重置时刻的**人话文本**解析（"Jul 5 at 4:39am
/// (Asia/Shanghai)" → Date）。撞额度自动挂唤醒钩子要真实的重置时刻,不能拿
/// 展示串糊弄。年份按「未来最近」推断（12 月看 1 月的重置会跨年）。
/// 解析不出 → nil,调用方走保守回退（定期重试）,不猜。
enum ClaudeResetTimeParser {
    static func parse(_ raw: String, now: Date = Date()) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        // 尾部时区 "(Asia/Shanghai)" —— 抠出来喂 formatter,剩下 "Jul 5 at 4:39am"。
        var tz = TimeZone.current
        if let open = text.lastIndex(of: "("), text.hasSuffix(")") {
            let name = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            if let parsed = TimeZone(identifier: name) { tz = parsed }
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        // 无年份格式 —— DateFormatter 默认落在 2000 年,parse 后把年份替换成
        // 「>= now 的最近一年」。分/无分两个变体（"4pm" 与 "4:39am" 都出现过）。
        for fmt in ["MMM d 'at' h:mma", "MMM d 'at' ha"] {
            f.dateFormat = fmt
            guard let base = f.date(from: text) else { continue }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            var parts = cal.dateComponents([.month, .day, .hour, .minute], from: base)
            let nowYear = cal.component(.year, from: now)
            for year in [nowYear, nowYear + 1] {
                parts.year = year
                if let candidate = cal.date(from: parts), candidate >= now {
                    return candidate
                }
            }
        }
        return nil
    }
}

/// codex rollout jsonl 的 `token_count.rate_limits` 解析（实测 0.137.0：每轮落盘，
/// 无进程也能读）。形如：
///   {"payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5.0,
///    "window_minutes":300,"resets_at":1782030455},"secondary":{...},"plan_type":"prolite"}}}
/// 输入整段 jsonl 文本，取**最后一条**带 rate_limits 的记录（最新额度态）。
enum CodexRolloutQuotaParser {
    static func parse(_ jsonl: String, now: Date = Date()) -> AgentQuotaSnapshot? {
        // 倒序找最后一行可解析出 rate_limits 的记录。
        for rawLine in jsonl.split(separator: "\n").reversed() {
            guard rawLine.contains("rate_limits"),
                  let data = rawLine.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let limits = rateLimitsDict(in: obj) else { continue }
            var windows: [AgentQuotaWindow] = []
            if let w = window(from: limits["primary"]) { windows.append(w) }
            if let w = window(from: limits["secondary"]) { windows.append(w) }
            guard !windows.isEmpty else { continue }
            return AgentQuotaSnapshot(
                agent: "codex", windows: windows,
                fetchedAt: ISO8601DateFormatter().string(from: now))
        }
        return nil
    }

    /// rate_limits 可能挂在 payload 下（rollout）或顶层（保守兼容）。
    private static func rateLimitsDict(in obj: [String: Any]) -> [String: Any]? {
        if let payload = obj["payload"] as? [String: Any],
           let l = payload["rate_limits"] as? [String: Any] { return l }
        return obj["rate_limits"] as? [String: Any]
    }

    private static func window(from any: Any?) -> AgentQuotaWindow? {
        guard let d = any as? [String: Any],
              let used = d["used_percent"] as? Double else { return nil }
        let minutes = (d["window_minutes"] as? Int) ?? 0
        let label: String
        switch minutes {
        case 300: label = "5小时窗"
        case 10080: label = "周窗"
        default: label = minutes > 0 ? "\(minutes)分钟窗" : "窗口"
        }
        var resets: String? = nil
        if let epoch = d["resets_at"] as? Double {
            resets = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: epoch))
        }
        return AgentQuotaWindow(label: label, usedPercent: Int(used.rounded()), resetsAt: resets)
    }
}
