import Foundation

/// 把本地 crew + session 事实渲染成 session 的世界观 system prompt（spec
/// 2026-06-05-pendingcrew-local-first-crew-design §6 复用 + chunk 4 接线）。
///
/// 对齐 edge `renderSessionWorldModel` 的语义，但**全本地**：吃 primitives（调用方
/// 从 `CrewDetail`/`CrewMember` 抽出来传），不引 app module 的 model —— 这样能编进
/// PendingCrewTests bundle 单测（同 LocalWhiteboardStore 模式）。
///
/// 本地无 DAG / 无责任分账，所以 `lineageBlock`/`sharesBlock`/`tiebreakerBlock`
/// **不提供** → `PromptTemplate` 把那几个槽 strip 成空（§6/§7 留空，benign）。
struct LocalSessionWorldModel {
    /// 一个本地人类成员（喂花名册）。
    struct Human: Equatable {
        var displayName: String
        var role: String
        var userId: String?

        init(displayName: String, role: String = "member", userId: String? = nil) {
            self.displayName = displayName
            self.role = role
            self.userId = userId
        }
    }

    /// 渲染所需的本地事实。
    struct Context {
        var sessionTaskBrief: String
        var runnerKind: String              // "claude_code" | "codex"
        var sessionId: String = ""
        var crewId: String
        var crewTitle: String
        var workingDirectory: String = ""
        var humans: [Human] = []
        var captainName: String? = nil
        var captainBotId: String? = nil
        var locale: String = "zh"
    }

    let loader: LocalPromptLoader

    init(loader: LocalPromptLoader = LocalPromptLoader()) {
        self.loader = loader
    }

    /// 渲染好的世界观 markdown，可作为 `--append-system-prompt-file` 喂给 claude。
    func render(_ ctx: Context) throws -> String {
        try loader.render(name: "session-world-model", locale: ctx.locale, vars: buildVars(ctx))
    }

    /// 暴露给单测：只测 var 映射不碰文件。
    func buildVars(_ ctx: Context) -> [String: String] {
        [
            "sessionTaskBrief": ctx.sessionTaskBrief.isEmpty ? "(无任务描述)" : ctx.sessionTaskBrief,
            "runnerKind": ctx.runnerKind,
            "sessionId": ctx.sessionId.isEmpty ? "(本地 session)" : ctx.sessionId,
            "crewId": ctx.crewId,
            "crewTitle": ctx.crewTitle.isEmpty ? "(未命名 crew)" : ctx.crewTitle,
            "runtimeLocation": "local_host",
            "workingDirectory": ctx.workingDirectory.isEmpty ? "(未设置)" : ctx.workingDirectory,
            "humanRoster": renderRoster(ctx.humans),
            "captainBlock": renderCaptain(name: ctx.captainName, botId: ctx.captainBotId),
            // lineageBlock / sharesBlock / tiebreakerBlock 本地不提供 → strip 成空。
        ]
    }

    private func renderRoster(_ humans: [Human]) -> String {
        guard !humans.isEmpty else { return "(暂无)" }
        return humans
            .map { "- **\($0.displayName)** — role: \($0.role), user_id: `\($0.userId ?? "?")`" }
            .joined(separator: "\n")
    }

    private func renderCaptain(name: String?, botId: String?) -> String {
        guard let botId, let name else { return "本 crew 暂无指定 captain。" }
        return "Captain: **\(name)** (bot_id: `\(botId)`)"
    }
}
