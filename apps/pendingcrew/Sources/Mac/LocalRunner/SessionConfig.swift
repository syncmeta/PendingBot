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

    public init(kind: LocalCodingAgentKind,
                model: String? = nil,
                effort: String? = nil,
                initialPrompt: String? = nil,
                resumeSessionId: String? = nil,
                permissionMode: String = "auto",
                isolation: Bool = false) {
        self.kind = kind
        self.model = model
        self.effort = effort
        self.initialPrompt = initialPrompt
        self.resumeSessionId = resumeSessionId
        self.permissionMode = permissionMode
        self.isolation = isolation
    }

    /// Build the interactive-CLI argv. The session's instruction is the trailing
    /// positional prompt — both CLIs start an interactive (subscription-billed)
    /// session by default; only `-p`/`exec` go headless, which we never use.
    public func argv() -> [String] {
        switch kind {
        case .claudeCode:
            var a: [String] = []
            if let id = resumeSessionId, !id.isEmpty { a += ["--resume", id] }
            a += ["--permission-mode", permissionMode] // "auto", NOT --dangerously-skip-permissions
            if let m = model, !m.isEmpty { a += ["--model", m] }
            if let e = effort, !e.isEmpty { a += ["--effort", e] }
            if let p = initialPrompt, !p.isEmpty { a.append(p) } // positional prompt LAST
            return a
        case .codex:
            // Placeholder until codex moves to app-server (separate plan). Keep the FS sandbox.
            var a: [String] = []
            if let id = resumeSessionId, !id.isEmpty { a += ["resume", id] }
            a += ["--sandbox", "workspace-write"]
            if let m = model, !m.isEmpty { a += ["--model", m] }
            if let p = initialPrompt, !p.isEmpty { a.append(p) }
            return a
        }
    }
}
#endif
