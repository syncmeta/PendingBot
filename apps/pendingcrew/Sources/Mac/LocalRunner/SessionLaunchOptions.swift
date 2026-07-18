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

    /// 当调用方**没显式选 model** 时，解析出一个具体别名显式落到启动配置里 ——
    /// 让 argv 永远带 `--model`、`run.model` 永不为 nil，UI 显示即真实跑的模型
    /// （用户定调：不许再糊「默认」，#489）。
    ///
    /// **只做主链，不复刻 claude 全部解析规则**（drift 风险已记 tech-debt 🟡）：
    /// - **claude**：`ANTHROPIC_MODEL` env → 项目 `.claude/settings.local.json` →
    ///   项目 `.claude/settings.json` → 用户 `~/.claude/settings.json` 的 `model` 字段。
    ///   都没有 → 兜底当代默认 `sonnet` + fail-loud 日志（绝不返回 nil / 糊「默认」）。
    /// - **codex**：`~/.codex/config.toml` 顶层 `model = "..."` 一眼可读则用；读不到就
    ///   返回 nil（保持 codex CLI 自身默认；显示端会退「默认」，复杂 TOML 解析留 tech-debt 尾巴）。
    ///
    /// - Parameter projectDir: session 的工作目录（claude 会在此找项目级 settings）。
    static func defaultModel(for kind: LocalCodingAgentKind, projectDir: URL?) -> String? {
        switch kind {
        case .claudeCode:
            if let env = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"],
               !env.isEmpty { return env }
            let home = FileManager.default.homeDirectoryForCurrentUser
            var candidates: [URL] = []
            if let dir = projectDir {
                candidates.append(dir.appendingPathComponent(".claude/settings.local.json"))
                candidates.append(dir.appendingPathComponent(".claude/settings.json"))
            }
            candidates.append(home.appendingPathComponent(".claude/settings.json"))
            for url in candidates {
                if let m = jsonStringField("model", at: url), !m.isEmpty { return m }
            }
            // fail-loud：真没解析出用户默认 —— 落一个当代默认，别静默糊「默认」。
            FileHandle.standardError.write(Data(
                "⚠️ [SessionLaunch] claude 默认模型未从 env/settings.json 解析出，兜底 sonnet（显示=实际）。\n".utf8))
            return "sonnet"
        case .codex:
            let home = FileManager.default.homeDirectoryForCurrentUser
            let toml = home.appendingPathComponent(".codex/config.toml")
            return tomlTopLevelString("model", at: toml)
        }
    }

    /// 读 JSON 文件顶层某个字符串字段（best-effort，任何失败返回 nil）。
    private static func jsonStringField(_ key: String, at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[key] as? String
    }

    /// 从 TOML 里读**顶层**（第一个 `[section]` 之前）的 `key = "..."`。只认一眼可读的
    /// 简单形式，不做完整 TOML 解析（codex 复杂配置留 tech-debt 尾巴）。
    private static func tomlTopLevelString(_ key: String, at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { break } // 进入某个 section，顶层结束
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") { // 行尾注释
                value = String(value[value.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
#endif
