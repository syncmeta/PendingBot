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

    /// 别名 → UI 友好显示名（带版本）。传给 CLI/MCP 的仍是裸别名，只有人面
    /// 展示走这里。版本号是手维护的（CLI 解析别名到哪代这里看不见）——换代要
    /// 记得同步，漂移记录见 docs/tech-debt.md。未收录的值（codex 系 / 手填）原样返回。
    static func displayName(for model: String) -> String {
        switch model {
        case "fable":  return "Fable 5"
        case "opus":   return "Opus 4.8"
        case "sonnet": return "Sonnet 5"
        case "haiku":  return "Haiku 4.5"
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
