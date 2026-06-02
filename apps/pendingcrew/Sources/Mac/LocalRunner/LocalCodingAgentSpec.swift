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

    /// 用户在 CreateSessionSheet 选的模型 slug。
    ///
    /// - Claude Code：拼成 `--model <slug>` 透传给 CLI；nil = 让 CLI 用默认。
    /// - Codex：拼成 `-m/--model <slug>` 透传给 `codex exec`；nil = 让 Codex 用
    ///   `~/.codex/config.toml` 的默认。
    ///
    /// 不会出现在 env 里 —— spec v2 §8.4.2 白名单严控环境变量。
    public let model: String?

    /// 额外的 env 透传。**只放用户在 PendingCrew 设置里自己配的 LLM API key**
    /// （`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY` 等）。
    ///
    /// **不要**把 PendingCrew 自己的 secret 塞进来 —— 见 `env()` 的白名单逻辑。
    public let additionalEnv: [String: String]

    /// 完全替换 `argv()` 计算结果的命令行。`nil`（默认）= 走每个 kind 的标准
    /// 非交互 argv（已真机验过的首回合路径，**不动**）。非 nil 用于 T4.5
    /// send_prompt 的 `--resume` 续跑回合（见 `makingResumeTurn`），让一次
    /// resume turn 复用同一套 Process / stdin / 流式解析管道，只换 argv。
    public let argvOverride: [String]?

    /// T4.5 ambient steering —— Claude Code 的 `--settings <file>` 路径，指向
    /// PendingCrew 托管的 settings（含 `UserPromptSubmit` hook，把常驻便签作为
    /// 上下文注入；见 `SteeringChannel`）。`nil`（默认）= 不挂 hook，argv 与
    /// 验证过的路径一致。仅 Claude 用；Codex 忽略。
    public let claudeSettingsPath: String?

    public init(
        kind: LocalCodingAgentKind,
        executableURL: URL,
        workingDirectory: URL,
        taskBrief: String,
        initialPrompt: String,
        model: String? = nil,
        additionalEnv: [String: String] = [:],
        argvOverride: [String]? = nil,
        claudeSettingsPath: String? = nil
    ) {
        self.kind = kind
        self.executableURL = executableURL
        self.workingDirectory = workingDirectory
        self.taskBrief = taskBrief
        self.initialPrompt = initialPrompt
        self.model = model
        self.additionalEnv = additionalEnv
        self.argvOverride = argvOverride
        self.claudeSettingsPath = claudeSettingsPath
    }

    /// 构造一个 **resume 续跑回合** 的 spec（T4.5 send_prompt 跨端遥控）。
    ///
    /// 复用 agent 已有的 session，所以模型保留完整上下文；新 prompt 跟首回合
    /// 一样走 stdin，转写仍是 `--output-format=stream-json`，现有解析层无需改。
    /// 缓存前缀复用，所以一次 resume turn 很便宜（2026-06-02 实测，见
    /// `docs/crew-runner-steering.md`）。
    ///
    /// **目前仅 Claude** —— Codex 的续跑是另一个子命令（`codex exec resume`），
    /// 这里对 Codex 返回 nil，让上层 fail loud，而不是悄悄起一个丢了上下文的
    /// 全新 Codex run（那是埋雷）。
    public func makingResumeTurn(agentSessionId: String, prompt: String) -> LocalCodingAgentLaunchSpec? {
        guard kind == .claudeCode, !agentSessionId.isEmpty else { return nil }
        var resumeArgv: [String] = [
            "--resume", agentSessionId,
            "--print", "--output-format=stream-json", "--verbose",
        ]
        if let model, !model.isEmpty {
            resumeArgv.append("--model")
            resumeArgv.append(model)
        }
        // Carry the ambient-steering hook into resume turns too, so a standing
        // note keeps injecting on every follow-up turn.
        resumeArgv.append(contentsOf: claudeSettingsArgs())
        return LocalCodingAgentLaunchSpec(
            kind: kind,
            executableURL: executableURL,
            workingDirectory: workingDirectory,
            taskBrief: taskBrief,
            initialPrompt: prompt,
            model: model,
            additionalEnv: additionalEnv,
            argvOverride: resumeArgv,
            claudeSettingsPath: claudeSettingsPath
        )
    }

    /// `--settings <path>` for the ambient-steering hook, or `[]` when unset.
    /// Shared by the first-turn argv + the resume argv so a standing note
    /// injects on every turn.
    private func claudeSettingsArgs() -> [String] {
        guard let claudeSettingsPath, !claudeSettingsPath.isEmpty else { return [] }
        return ["--settings", claudeSettingsPath]
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
        // A resume turn (or any caller-built command) bypasses the standard
        // per-kind argv. The default path below is unchanged + still verified.
        if let argvOverride { return argvOverride }
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
            var args: [String] = [
                "--print",
                "--output-format=stream-json",
                "--verbose",
            ]
            if let model, !model.isEmpty {
                args.append("--model")
                args.append(model)
            }
            args.append(contentsOf: claudeSettingsArgs())
            return args

        case .codex:
            // Codex CLI (codex-cli ≥ 0.13x): 非交互模式 = `codex exec [PROMPT]`。
            // prompt 走 stdin —— `exec` 在没有位置参数时从 stdin 读（`codex exec
            // --help`: "If not provided as an argument … instructions are read from
            // stdin"）。
            //
            // `--json` = 把事件以 JSONL 打到 stdout（对标 Claude Code 的
            // `--output-format=stream-json`）。PendingCrew 后面要逐行解析事件流做
            // session 窗口，所以两个 runner 统一走 JSONL。
            //
            // `-m/--model <slug>` 透传用户在 CreateSessionSheet 选的模型；nil/空 =
            // 让 Codex 用 `~/.codex/config.toml` 的默认。
            //
            // TODO(T4.x): 还在演进、留作 follow-up 复核：
            //   - sandbox 策略（`-s read-only|workspace-write|danger-full-access`）
            //     + approval 模式 —— 对标 Claude 的 `--dangerously-skip-permissions`，
            //     和"自动模式"一起做（spec v2 §10.1）。
            //   - `resume` 子命令做多轮续跑（spec v2 §9.2）。
            var args: [String] = [
                "exec",
                "--json",
            ]
            if let model, !model.isEmpty {
                args.append("--model")
                args.append(model)
            }
            return args
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
