#if os(macOS)
import Foundation

/// Per-session launch configuration (spec §1 启动带指令 / §11 per-session 配置).
/// Pure value type so `argv()` is unit-testable without spawning a process.
public struct SessionConfig: Sendable, Equatable {
    public var kind: LocalCodingAgentKind
    /// `--model` (claude) / `-m` (codex). `nil` → let the CLI use its default.
    public var model: String?
    /// Thinking effort: claude `--effort <level>` / codex `model_reasoning_effort`.
    /// Passthrough string — valid levels are CLI-owned (UI validates; see spec probe §11).
    public var effort: String?
    /// The session's first instruction, passed as the positional prompt at launch
    /// (spec §1 — kills the post-spawn 0.6s sleep+inject).
    public var initialPrompt: String?
    /// Resume an existing agent session by id.
    public var resumeSessionId: String?
    /// claude permission mode. **Default "auto" = auto mode classifier (spec §9); never bypass.**
    public var permissionMode: String
    /// 隔离:on → session 跑在独立 git worktree（并行不打架 + claude containment §8）；
    /// off → 用 crew 共享目录。**编排参数,不进 argv。**
    public var isolation: Bool
    /// 世界观 system prompt 文件路径 → claude `--append-system-prompt-file`
    /// (**append**,不 replace claude 默认 system prompt;flag 已 `claude --help` 核实)。
    /// nil = 不注入。调用方用 `LocalSessionWorldModel` 渲染后写临时文件,把路径塞这里
    /// (spec local-first chunk 4 session↔crew 接线)。codex 路径暂不接(走 app-server
    /// 的 additionalContext,见 codex 参考)。
    public var appendSystemPromptFile: String?
    /// claude `--settings <file>`：per-session settings.json（含 PostToolUse hook =
    /// `pendingcrew-mcp hook`，每轮注入未读白板）。nil = 不带。flag 经 spike 实测。
    public var settingsFile: String?
    /// claude `--mcp-config <file>`：per-session mcp-config.json（挂 `pendingcrew-mcp
    /// serve`，提供 post_to_crew/read_whiteboard）。nil = 不带。flag 经 spike 实测。
    public var mcpConfigFile: String?

    public init(kind: LocalCodingAgentKind,
                model: String? = nil,
                effort: String? = nil,
                initialPrompt: String? = nil,
                resumeSessionId: String? = nil,
                permissionMode: String = "auto",
                isolation: Bool = false,
                appendSystemPromptFile: String? = nil,
                settingsFile: String? = nil,
                mcpConfigFile: String? = nil) {
        self.kind = kind
        self.model = model
        self.effort = effort
        self.initialPrompt = initialPrompt
        self.resumeSessionId = resumeSessionId
        self.permissionMode = permissionMode
        self.isolation = isolation
        self.appendSystemPromptFile = appendSystemPromptFile
        self.settingsFile = settingsFile
        self.mcpConfigFile = mcpConfigFile
    }

    /// Build the spawn argv for this session's agent CLI.
    ///
    /// **claude** (`claudeCode`): interactive TUI — positional prompt is the trailing
    /// argv; only `-p`/`exec` go headless, which we never use.
    ///
    /// **codex**: runs as `codex app-server` (stdio JSON-RPC). The subcommand is the
    /// only mandatory token. `effort` goes via `-c model_reasoning_effort=<e>` at spawn
    /// time — config.toml would otherwise override turn-level effort, so `-c` is the
    /// deterministic path (spec §5). `model`, `cwd`, `developerInstructions`, and
    /// `initialPrompt` are NOT argv — they go over the protocol (thread/start,
    /// turn/start) after the handshake. `resumeSessionId` for codex is a deferred
    /// concern and is excluded from argv for now.
    public func argv() -> [String] {
        switch kind {
        case .claudeCode:
            var a: [String] = []
            if let id = resumeSessionId, !id.isEmpty { a += ["--resume", id] }
            a += ["--permission-mode", permissionMode] // "auto", NOT --dangerously-skip-permissions
            if let f = appendSystemPromptFile, !f.isEmpty { a += ["--append-system-prompt-file", f] }
            if let s = settingsFile, !s.isEmpty { a += ["--settings", s] }
            if let mc = mcpConfigFile, !mc.isEmpty { a += ["--mcp-config", mc] }
            if let m = model, !m.isEmpty { a += ["--model", m] }
            if let e = effort, !e.isEmpty { a += ["--effort", e] }
            // `--` terminates option parsing so the positional prompt is never swallowed by a
            // preceding variadic flag. `--mcp-config <configs...>` is variadic (claude --help);
            // when it's the last flag (captain launch has no `--model` to separate them) it
            // otherwise eats the prompt as a second config path → "MCP config file not found:
            // <cwd>/<prompt>". Verified against claude 2.1.170. Also makes a prompt starting
            // with `-` safe. positional prompt LAST.
            if let p = initialPrompt, !p.isEmpty { a += ["--", p] }
            return a
        case .codex:
            // codex runs as an app-server (stdio JSON-RPC), NOT an interactive TUI.
            // effort goes via `-c model_reasoning_effort=<e>` on spawn — config.toml would
            // otherwise override turn-level effort, so -c is the deterministic path (spec §5).
            // model / cwd / developerInstructions / initialPrompt are NOT argv — they go over
            // the protocol (thread/start, turn/start) after the handshake.
            var a: [String] = []
            if let e = effort, !e.isEmpty { a += ["-c", "model_reasoning_effort=\(e)"] }
            a.append("app-server")
            return a
        }
    }
}
#endif
