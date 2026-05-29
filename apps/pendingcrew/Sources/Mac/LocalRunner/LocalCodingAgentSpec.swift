#if os(macOS)
import Foundation

/// 启动一个本机 coding agent 子进程所需的全部参数。
///
/// **Value semantics**：所有字段 immutable，构造时一次性传齐；`argv()` / `env()`
/// 是纯函数。便于测试 + 防止 LocalCodingAgentProcess 内部偷偷 mutate spec。
public struct LocalCodingAgentLaunchSpec: Sendable, Hashable {
    /// 子进程跑的 agent 类型。
    public let kind: LocalCodingAgentKind

    /// 已通过 `LocalCodingAgentExecutable.resolve(kind)` 找到的可执行文件。
    /// 调用方负责保证 valid —— 构造 spec 时不再重复 `which`。
    public let executableURL: URL

    /// 子进程 `cwd`。**必须存在**（`LocalCodingAgentProcess.start` 会再校验一次）。
    public let workingDirectory: URL

    /// 任务标题/简介（一句话），UI 上显示给用户的"你在跑什么"。
    /// 不直接拼进 argv（避免长 prompt 撑爆命令行），通过 stdin / `--print` 等
    /// 方式传给底层 CLI。详见 `argv()` 注释。
    public let taskBrief: String

    /// 第一轮 prompt 全文。同样不拼进 argv，走 stdin / file。
    public let initialPrompt: String

    /// 额外的 env 透传。**只放用户在 PendingCrew 设置里自己配的 LLM API key**
    /// （`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY` 等）。
    ///
    /// **不要**把 PendingCrew 自己的 secret 塞进来 —— 见 `env()` 的白名单逻辑。
    public let additionalEnv: [String: String]

    public init(
        kind: LocalCodingAgentKind,
        executableURL: URL,
        workingDirectory: URL,
        taskBrief: String,
        initialPrompt: String,
        additionalEnv: [String: String] = [:]
    ) {
        self.kind = kind
        self.executableURL = executableURL
        self.workingDirectory = workingDirectory
        self.taskBrief = taskBrief
        self.initialPrompt = initialPrompt
        self.additionalEnv = additionalEnv
    }

    // MARK: - argv

    /// 构造给 `Process.arguments` 用的命令行参数数组。
    ///
    /// **数组形式直接传给 `Process` —— 不走 shell**，所以参数内的引号 / `$` / `\`
    /// 都不需要 escape。这是 spec v2 §8.4 防 shell injection 的关键。
    ///
    /// initial prompt 通过 stdin 而不是 argv 传：
    /// - argv 有长度限制（macOS `ARG_MAX` 一般 256 KB，prompt 可能逼近）
    /// - prompt 里常带换行/反引号，走 stdin 完全不用考虑 escape
    ///
    /// 具体 flag 选择见各 case 注释 —— Claude Code / Codex 的 CLI 都在持续演进，
    /// 这里挑了**当前文档里最稳的非交互模式 flag**，新版若改了需要回头复核。
    public func argv() -> [String] {
        switch kind {
        case .claudeCode:
            // Claude Code CLI: 非交互模式 = `claude -p <prompt>` 或 `claude --print`
            // 用 `--print` 拒绝 TTY；`--output-format=stream-json` 让我们一行一行
            // 读 JSON 事件流（PendingCrew 后面要解析做 session 窗口）。
            // `--verbose` 是硬性要求:`--print` + `--output-format=stream-json`
            // 不带 `--verbose` 时 CLI 直接报错退出
            // ("Error: When using --print, --output-format=stream-json requires --verbose")。
            //
            // prompt 走 stdin（`--print` 在没有位置参数时从 stdin 读）。
            //
            // TODO(T4.x): Claude Code CLI flag 还在变；以后需要复核：
            //   - `--append-prompt` 用来 queue 后续 prompt（spec v2 §9.2）
            //   - `--dangerously-skip-permissions` 给"自动模式"（spec v2 §10.1）
            //   - `--model <id>` 选模型
            // 现在 T3.1 只保证能起一个非交互 session，flag 留作 follow-up。
            return [
                "--print",
                "--output-format=stream-json",
                "--verbose",
            ]

        case .codex:
            // Codex CLI: 非交互模式 = `codex exec [prompt]`
            // 同样让 prompt 走 stdin —— Codex `exec` 在没有位置参数时也从 stdin 读。
            //
            // TODO(T4.x): Codex CLI 的细节也在变。后续要复核：
            //   - 是否有等价的 stream-json 输出 flag
            //   - 模型选择参数
            //   - permission / approval 模式 flag
            return [
                "exec",
            ]
        }
    }

    // MARK: - env

    /// 子进程的完整 env。**显式构造**，不继承 PendingCrew 父进程的 env。
    ///
    /// **spec v2 §8.4.2 白名单**：
    /// - 透传基础 shell vars：`PATH` / `HOME` / `SHELL` / `LANG` / `TERM`
    /// - 透传 `LC_*`（locale）：避免 CLI 报 locale 不一致 warning
    /// - 透传 `USER` / `LOGNAME`：CLI 可能用它做 `~` 解析或日志
    /// - 透传 `TMPDIR`：macOS launchd 给每个用户一个 sandbox tmpdir，子进程也得用同一个
    /// - `additionalEnv` 里用户自配的 LLM API key
    ///
    /// **不透传**：PendingBot device grant token、Keychain 凭据、任何 `PENDING*` 前缀的
    /// PendingCrew 自己 env。所有非白名单 var 默认就不在返回 dict 里。
    public func env() -> [String: String] {
        var result: [String: String] = [:]

        let parent = ProcessInfo.processInfo.environment
        for key in Self.passthroughKeys {
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
            if Self.isForbidden(key: key) { continue }
            result[key] = value
        }
        return result
    }

    /// 透传到子进程的 env var 白名单。详细原因见 `env()`。
    static let passthroughKeys: [String] = [
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
    static func isForbidden(key: String) -> Bool {
        // 别让 PendingCrew 自己的 device-grant / supabase 凭据混进去。
        let upper = key.uppercased()
        return upper.hasPrefix("PENDINGBOT_")
            || upper.hasPrefix("PENDINGCREW_")
            || upper == "SUPABASE_SERVICE_ROLE_KEY"
            || upper == "SUPABASE_ANON_KEY"
    }
}
#endif
