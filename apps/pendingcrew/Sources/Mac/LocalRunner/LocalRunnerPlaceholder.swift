#if os(macOS)
import Foundation

/// 本地 coding agent runner 模块占位。
///
/// Scaffold 阶段只是证明 `#if os(macOS)` 工程结构能编译 —— iOS 平台
/// 不会接触到这段代码（`Process` 在 iOS 沙盒下不可用）。
///
/// 真正实现在 Phase 3（T3.1 / T3.2 / T3.4），按 spec v2 §8.4：
///
/// - `process.environment` 必须显式 set 白名单（PATH / HOME / SHELL / LANG +
///   用户在 PendingCrew 配的 LLM API key），**不继承** PendingCrew 自己的 secret
///   （device grant token / Keychain 内容）
/// - Cancel：用户点"停止" → `SIGTERM` + 5 秒 grace + `SIGKILL` 兜底
/// - **不设 timeout**（claude code / codex 自己关心的事）
/// - 子进程拥有用户登录账户的所有权限，**首次启动时弹 disclosure 告知**
///
/// 老 `apps/macos/PendingCrew/Sources/PendingCrew/Services/LocalCodingAgentRunner.swift`
/// 已删，因为 codex 当时留下几个安全雷（env 没清空 / shell escaping 没做 /
/// finishRunnerSession 用 try? 吞错），不复用。
enum LocalRunnerPlaceholder {
    /// 占位 flag，让 build 系统验证 macOS-only target 能编译。
    static var isAvailable: Bool { true }
}
#endif
