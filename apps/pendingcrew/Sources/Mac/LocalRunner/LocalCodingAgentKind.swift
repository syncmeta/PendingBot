#if os(macOS)
import Foundation

/// PendingCrew v1 支持的本机 coding agent kind。
///
/// 注：spec v2 §8.1 砍掉了 Kilo Code / opencode（不熟、降低复杂度），
/// 留到 v1.x 视需要再加。**不要**在这里塞回旧 enum case。
public enum LocalCodingAgentKind: String, CaseIterable, Sendable, Hashable {
    /// Anthropic Claude Code CLI（`claude`）
    case claudeCode = "claude_code"
    /// OpenAI Codex CLI（`codex`）
    case codex = "codex"

    /// 用户可见的简短显示名。**仅日志/UI 用**，不参与 wire/storage。
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// 工具发现时在 `PATH` 上找的可执行名。
    var binaryName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    /// 对应 server `crew_sessions.runner_kind` 的 wire 值(T4.5)。edge 的
    /// RunnerKind enum:`local_claude_code` / `local_codex`。
    public var serverRunnerKind: String {
        switch self {
        case .claudeCode: return "local_claude_code"
        case .codex: return "local_codex"
        }
    }

    /// crew 存的 `captainAgentKind`("claude_code"/"codex"/nil) → 本机 agent kind。
    /// **默认 Codex**(建 crew 时的默认;老 crew / edge crew 没记也走这里)。
    public static func captainDefault(_ raw: String?) -> LocalCodingAgentKind {
        switch raw {
        case "claude_code": return .claudeCode
        case "codex": return .codex
        default: return .codex
        }
    }

    /// 从成员显示名反推 kind —— @ 唤醒已退出成员时用。`LocalSessionMember` 只存
    /// 了 displayName(形如「Claude Code · ab12cd」,来自 `run.displayName` =
    /// `kind.displayName + " · " + 前缀`),没单存 kind;显示名对不上(如「机长」)
    /// 返 nil,caller 落回 `captainDefault`。
    public static func inferred(fromDisplayName name: String) -> LocalCodingAgentKind? {
        for kind in allCases where name.hasPrefix(kind.displayName) { return kind }
        return nil
    }
}
#endif
