#if os(macOS)
import Foundation

/// 构造本机 coding agent 子进程的 env（spec v2 §8.4.2 白名单）。
///
/// 内嵌终端（`AgentTerminalSession`）拿一个 plain `[String: String]` env 起 PTY；
/// 这里是那个 env 的**唯一**来源，集中收口白名单逻辑。不继承 PendingCrew 父进程
/// 的全部 env —— 只显式放行一组基础 shell vars + 用户自配的 LLM API key。
public enum LocalCodingAgentEnv {

    /// 构造子进程的完整 env。
    ///
    /// **白名单**：
    /// - 透传基础 shell vars：`PATH` / `HOME` / `SHELL` / `LANG` / `TERM`
    /// - 透传 `LC_*`（locale）：避免 CLI 报 locale 不一致 warning
    /// - 透传 `USER` / `LOGNAME`：CLI 可能用它做 `~` 解析或日志
    /// - 透传 `TMPDIR`：macOS launchd 给每个用户一个 sandbox tmpdir，子进程也得用同一个
    /// - `additionalEnv` 里用户自配的 LLM API key
    ///
    /// **不透传**：PendingBot device grant token、Keychain 凭据、任何 `PENDING*` 前缀的
    /// PendingCrew 自己 env。所有非白名单 var 默认就不在返回 dict 里。
    public static func build(additionalEnv: [String: String]) -> [String: String] {
        var result: [String: String] = [:]

        let parent = ProcessInfo.processInfo.environment
        for key in passthroughKeys {
            if let value = parent[key] {
                result[key] = value
            }
        }
        // LC_* 是一组 var（LC_ALL / LC_CTYPE / LC_COLLATE / …）—— 不枚举全部，
        // 一律放行 LC_ 前缀。
        for (key, value) in parent where key.hasPrefix("LC_") {
            result[key] = value
        }
        // PATH 一定要有，否则子进程 spawn 出来的 grandchild（如 git）找不到工具。
        // 父进程没设的话给个 conservative fallback。
        if result["PATH"] == nil {
            result["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }

        // 用户自配的 API key 等 —— 覆盖 / 补充，不与上面的白名单冲突。
        for (key, value) in additionalEnv {
            // 防御：明确拒绝 PendingCrew 自己的 secret 误进来。Caller 不应该传
            // 这种 key，但 defensive 一下方便排查。
            if isForbidden(key: key) { continue }
            result[key] = value
        }
        return result
    }

    /// 透传到子进程的 env var 白名单。详细原因见 `build(additionalEnv:)`。
    public static let passthroughKeys: [String] = [
        "PATH",
        "HOME",
        "SHELL",
        "LANG",
        "TERM",
        "USER",
        "LOGNAME",
        "TMPDIR",
    ]

    /// `additionalEnv` 里**绝不**允许的 key（PendingCrew 自己的 secret 命名规约）。
    /// 这是 defensive check，调用方本来就不该传。
    public static func isForbidden(key: String) -> Bool {
        // 别让 PendingCrew 自己的 device-grant / supabase 凭据混进去。
        // SUPABASE_ 整个前缀封死（SECRET_KEY/PUBLISHABLE_KEY/JWT_SECRET/
        // DB_PASSWORD…）——按名枚举在 key 改名时会漏（service_role →
        // sb_secret 迁移差点就漏了），sub-agent 也没有任何合法理由拿到
        // 我们的 supabase 凭据。
        let upper = key.uppercased()
        return upper.hasPrefix("PENDINGBOT_")
            || upper.hasPrefix("PENDINGCREW_")
            || upper.hasPrefix("SUPABASE_")
    }
}
#endif
