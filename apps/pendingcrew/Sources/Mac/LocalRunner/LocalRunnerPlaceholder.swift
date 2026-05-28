#if os(macOS)
import Foundation

/// 本地 coding agent runner 模块入口（保留 module-level 注释；真实现见下面文件）。
///
/// T3.1 / T3.2 / T3.4 已落地 —— scaffold 阶段的 placeholder 退役。
///
/// **入口**：`MacLocalCodingAgentService`（实现 `LocalCodingAgentService` protocol）。
///   - `discoverAvailable()` 扫本机有哪些 runner
///   - `runSession(runID:spec:)` 起子进程，返回 `LocalCodingAgentRunHandle`
///
/// **相关文件**：
///   - `LocalCodingAgentKind.swift`      —— Claude Code / Codex 枚举
///   - `LocalCodingAgentExecutable.swift` —— `which` + Homebrew 路径解析
///   - `LocalCodingAgentSpec.swift`      —— argv / env 构造（含 env 白名单）
///   - `LocalCodingAgentProcess.swift`   —— Process actor + SIGTERM/SIGKILL cancel
///   - `LocalCodingAgentService.swift`   —— 顶层 protocol + 默认实现
///
/// **安全模型**（spec v2 §8.4）：
///   - 完全信任 + 最小 env 卫生（白名单 + 用户自配 API key）
///   - **不**继承 PendingCrew 父进程的全部 env（device grant / Keychain 不会泄）
///   - 不设 timeout；Cancel = SIGTERM + 5s grace + SIGKILL
///   - 数组形式传 argv，不走 shell ——⁠ 不需要 shell escape
enum LocalRunnerModule {
    /// 留一个 marker 让 `import` 文件外面好查找。无运行时意义。
    static let moduleLoaded: Bool = true
}
#endif
