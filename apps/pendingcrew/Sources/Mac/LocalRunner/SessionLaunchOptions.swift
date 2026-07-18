#if os(macOS)
import Foundation

/// 新建 session 的模型/effort 候选清单（人面 picker 与 prompt 文档共用一份，
/// 不在 UI 里散写字符串）。
///
/// - **模型**用两家 CLI 的**稳定别名**而非带日期的 slug：claude 的
///   fable/opus/sonnet/haiku 由 CLI 解析到当代最新（`/model opus` 同款语义），
///   换代不用改这里；codex 常用 gpt-5-codex（coding 调优默认）/gpt-5。
///   picker 之外仍允许任意字符串（机长 start_session / 未来自定义输入）——
///   有效性归 CLI 校验，起不来经 lastStartError 浮出。
/// - **effort 档位两家不同**（实测核对：claude 2.1.201 二进制 zod 枚举
///   low/medium/high/xhigh/max；codex model_reasoning_effort 取
///   minimal/low/medium/high），别互相塞。
enum SessionLaunchOptions {
    static func models(for kind: LocalCodingAgentKind) -> [String] {
        switch kind {
        case .claudeCode: return ["fable", "opus", "sonnet", "haiku"]
        case .codex:      return ["gpt-5-codex", "gpt-5"]
        }
    }

    /// 别名 → UI 友好显示名（**只标系列、不标版本号**）。传给 CLI/MCP 的仍是裸
    /// 别名，只有人面展示走这里。刻意不带版本号：别名本就交给 CLI 解析到当代最新
    /// （`/model opus` 同款语义），UI 硬编「4.8」这类数字会过时，系列名则永不漂移。
    /// 未收录的值（codex 系 / 手填）原样返回。
    static func displayName(for model: String) -> String {
        switch model {
        case "fable":  return "Fable"
        case "opus":   return "Opus"
        case "sonnet": return "Sonnet"
        case "haiku":  return "Haiku"
        default:       return model
        }
    }

    static func efforts(for kind: LocalCodingAgentKind) -> [String] {
        switch kind {
        case .claudeCode: return ["low", "medium", "high", "xhigh", "max"]
        case .codex:      return ["minimal", "low", "medium", "high"]
        }
    }
}
#endif
