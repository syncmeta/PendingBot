import Foundation

/// 本地 crew 元数据控制通道（spec 2026-06-17-pendingcrew-crew-naming）。
///
/// captain 的 MCP helper 是**离线子进程**，碰不到 `LocalCrewStore`（crew 标题真源）/
/// 网络，只能读写 `--dir` 下的共享文件。`rename_crew` 工具把一条待改名写进这里，
/// app 侧（`CrewStore`）靠目录监听感知、排空、落地到 `LocalCrewStore.setTitle` 并刷新侧栏。
///
/// 每 crew 一个 JSON：`<dir>/<crewId>.crewmeta.json` = `CrewMetaChange`（last-write-wins ——
/// 只保留最新一次改名，captain 反复改也只落最后那个）。与 `LocalWhiteboardStore`
/// 的 `<crewId>.json` / `LocalApprovalStore` 的 `<crewId>.approvals.json` 后缀不同，不冲突；
/// 共用 `LocalWhiteboardStore.defaultDirectory`，所以写盘即触发 app 的 `directoryChanged`。
///
/// **自包含 Foundation**（编进 `pendingcrew-mcp` re-exec helper + PendingCrewTests bundle）。
/// `@unchecked Sendable` + app↔helper 并发同 `LocalWhiteboardStore` 的 last-write-wins
/// tech-debt（v1 单用户低频可接受）。
final class LocalCrewControlStore: @unchecked Sendable {
    static let shared = LocalCrewControlStore()

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? LocalWhiteboardStore.defaultDirectory
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Write（helper 侧：rename_crew 工具）

    /// 写一条待改名（覆盖既有 → 只留最新）。空名（trim 后）忽略，不落盘。
    func requestRename(crewId: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let change = CrewMetaChange(title: trimmed, ts: ISO8601DateFormatter().string(from: Date()))
        guard let data = try? JSONEncoder().encode(change) else { return }
        try? data.write(to: fileURL(crewId), options: .atomic)
    }

    // MARK: - Read / drain（app 侧：CrewStore 落地）

    /// 偷看某 crew 的待改名（不删）。无 → nil。
    func pendingRename(crewId: String) -> String? {
        load(crewId)?.title
    }

    /// 排空全部待改名（目录监听 tick 调）：返回 `(crewId, title)` 列表并删除对应文件。
    /// 落地由调用方做（`LocalCrewStore.setTitle` + 刷新）。
    func drainRenames() -> [(crewId: String, title: String)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [(crewId: String, title: String)] = []
        for url in files where url.lastPathComponent.hasSuffix(Self.suffix) {
            let file = url.lastPathComponent
            let crewId = String(file.dropLast(Self.suffix.count))
            guard !crewId.isEmpty,
                  let data = try? Data(contentsOf: url),
                  let change = try? JSONDecoder().decode(CrewMetaChange.self, from: data) else { continue }
            out.append((crewId, change.title))
            try? FileManager.default.removeItem(at: url)
        }
        return out
    }

    // MARK: - Attention（机长 raise_attention / clear_attention → 侧栏黄点）
    //
    // 与 rename 同款 last-write-wins 单文件：`<crewId>.crewattention.json` =
    // `CrewAttentionChange`（reason 非 nil = 点亮，nil = 熄灭）。同 tick 先 raise
    // 后 clear 只落最后一次 —— app 侧 drain 时直接应用最终态即可。

    /// 点亮 attention（helper 侧：`raise_attention` 工具）。reason 一句话说明为什么
    /// 需要人类注意；空（trim 后）忽略，不落盘。
    func requestAttention(crewId: String, reason: String) {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        writeAttention(crewId: crewId, reason: trimmed)
    }

    /// 熄灭 attention（helper 侧：`clear_attention` 工具）。
    func requestClearAttention(crewId: String) {
        writeAttention(crewId: crewId, reason: nil)
    }

    /// 偷看某 crew 的待应用 attention 变更（不删）。无 → nil。
    func pendingAttention(crewId: String) -> CrewAttentionChange? {
        guard let data = try? Data(contentsOf: attentionFileURL(crewId)) else { return nil }
        return try? JSONDecoder().decode(CrewAttentionChange.self, from: data)
    }

    /// 排空全部待应用 attention 变更（目录监听 tick 调）：返回 `(crewId, reason)`
    /// 列表并删除对应文件。`reason == nil` = 熄灭。落地由调用方做
    /// （`LocalCrewStore.setAttention` + 刷新）。
    func drainAttentions() -> [(crewId: String, reason: String?)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [(crewId: String, reason: String?)] = []
        for url in files where url.lastPathComponent.hasSuffix(Self.attentionSuffix) {
            let file = url.lastPathComponent
            let crewId = String(file.dropLast(Self.attentionSuffix.count))
            guard !crewId.isEmpty,
                  let data = try? Data(contentsOf: url),
                  let change = try? JSONDecoder().decode(CrewAttentionChange.self, from: data) else { continue }
            out.append((crewId, change.reason))
            try? FileManager.default.removeItem(at: url)
        }
        return out
    }

    private func writeAttention(crewId: String, reason: String?) {
        let change = CrewAttentionChange(reason: reason, ts: ISO8601DateFormatter().string(from: Date()))
        guard let data = try? JSONEncoder().encode(change) else { return }
        try? data.write(to: attentionFileURL(crewId), options: .atomic)
    }

    // MARK: - Command queue（helper 侧：start_session / create_child_crew）
    //
    // rename 是 last-write-wins 单文件；起 session / 建子 crew 可重复，用队列：
    // 每条一个独立文件 <crewId>.<uuid>.crewcmd.json，drain 时全读+删。

    /// 机长起 worker session：brief 必填（空则忽略）；runner/isolation/model/effort 可选
    /// （model/effort nil = 用对应 CLI 的默认）。
    func enqueueStartSession(crewId: String, brief: String, runner: String?, isolation: Bool?,
                             model: String? = nil, effort: String? = nil, title: String? = nil) {
        enqueue(CrewCommand(
            id: UUID().uuidString.lowercased(), crewId: crewId, kind: "start_session",
            brief: brief, runner: runner, isolation: isolation, title: title,
            model: model, effort: effort,
            ts: ISO8601DateFormatter().string(from: Date())))
    }

    /// 机长以当前 crew 为父建子 crew：brief 必填；title 可选（不给 → app 侧地名占位）。
    func enqueueCreateChildCrew(crewId: String, brief: String, title: String?) {
        enqueue(CrewCommand(
            id: UUID().uuidString.lowercased(), crewId: crewId, kind: "create_child_crew",
            brief: brief, runner: nil, isolation: nil, title: title,
            model: nil, effort: nil,
            ts: ISO8601DateFormatter().string(from: Date())))
    }

    /// session 自切模型/effort（至少一个非空;两个都空则忽略不落盘）。
    /// `sessionId` = 发起方自己 —— app 侧据此找到对应 run。
    func enqueueSetProfile(crewId: String, sessionId: String, model: String?, effort: String?) {
        guard model?.isEmpty == false || effort?.isEmpty == false else { return }
        enqueue(CrewCommand(
            id: UUID().uuidString.lowercased(), crewId: crewId, kind: "set_profile",
            brief: "-", runner: nil, isolation: nil, title: nil,
            model: model, effort: effort, sessionId: sessionId,
            ts: ISO8601DateFormatter().string(from: Date())))
    }

    /// 机长跨 crew 消息（汇报线）：`direction` = "to_parent"（发所有直系父）|
    /// "to_child"（发 `targetHint` 指定的直系子）。消息文本放 `brief`（复用非空
    /// 校验）。DAG 解析/投递/唤醒归 app 侧（helper 读不到 crew store）。
    func enqueueCrewMessage(crewId: String, sessionId: String, direction: String,
                            targetHint: String?, message: String) {
        enqueue(CrewCommand(
            id: UUID().uuidString.lowercased(), crewId: crewId, kind: "crew_message",
            brief: message, runner: nil, isolation: nil, title: targetHint,
            sessionId: sessionId, direction: direction,
            ts: ISO8601DateFormatter().string(from: Date())))
    }

    /// session 设定时唤醒：到点 app 把 `note` 注入回该 session（不在跑 → 白板落一条）。
    func enqueueScheduleWakeup(crewId: String, sessionId: String, fireAt: String, note: String) {
        guard !fireAt.isEmpty, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        enqueue(CrewCommand(
            id: UUID().uuidString.lowercased(), crewId: crewId, kind: "schedule_wakeup",
            brief: "-", runner: nil, isolation: nil, title: nil,
            sessionId: sessionId, fireAt: fireAt, note: note,
            ts: ISO8601DateFormatter().string(from: Date())))
    }

    /// session 开/关群聊收听（`listen` 工具;#465）。开 = `until`（ISO8601）必给，
    /// `senders` 可选（nil = 听全部）；关 = `off: true`（until/senders 忽略）。
    /// 同一 session 重复开 = 覆盖（app 侧 last-write-wins）。
    func enqueueListen(crewId: String, sessionId: String, until: String?,
                       senders: [String]?, off: Bool) {
        guard off || until?.isEmpty == false else { return }
        enqueue(CrewCommand(
            id: UUID().uuidString.lowercased(), crewId: crewId, kind: "listen",
            brief: off ? "off" : "on", runner: nil, isolation: nil, title: nil,
            sessionId: sessionId, fireAt: until, senders: senders, off: off,
            ts: ISO8601DateFormatter().string(from: Date())))
    }

    private func enqueue(_ cmd: CrewCommand) {
        guard !cmd.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let data = try? JSONEncoder().encode(cmd) else { return }
        let url = directory.appendingPathComponent("\(cmd.crewId).\(cmd.id)\(Self.cmdSuffix)")
        try? data.write(to: url, options: .atomic)
    }

    /// 排空全部待执行命令（目录监听 tick 调）：返回列表并删除对应文件。
    /// 执行由调用方做（CrewStore）。跨 crew 一并返回，调用方按 crewId 分派。
    func drainCommands() -> [CrewCommand] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [CrewCommand] = []
        for url in files where url.lastPathComponent.hasSuffix(Self.cmdSuffix) {
            guard let data = try? Data(contentsOf: url),
                  let cmd = try? JSONDecoder().decode(CrewCommand.self, from: data) else { continue }
            out.append(cmd)
            try? FileManager.default.removeItem(at: url)
        }
        return out.sorted { $0.ts < $1.ts }
    }

    // MARK: - Persistence

    private static let cmdSuffix = ".crewcmd.json"

    private static let suffix = ".crewmeta.json"

    private static let attentionSuffix = ".crewattention.json"

    private func fileURL(_ crewId: String) -> URL {
        // crewId 是受控本地 id（"local-"+uuid，无路径分隔符/点），直接当文件名安全。
        directory.appendingPathComponent("\(crewId)\(Self.suffix)")
    }

    private func attentionFileURL(_ crewId: String) -> URL {
        directory.appendingPathComponent("\(crewId)\(Self.attentionSuffix)")
    }

    private func load(_ crewId: String) -> CrewMetaChange? {
        guard let data = try? Data(contentsOf: fileURL(crewId)) else { return nil }
        return try? JSONDecoder().decode(CrewMetaChange.self, from: data)
    }
}

/// 一条待落地的 crew 元数据变更（目前只有改名）。`ts` = 写入时间（ISO8601），调试用。
struct CrewMetaChange: Codable, Equatable {
    let title: String
    let ts: String
}

/// 一条待落地的 attention 变更（机长黄点）。`reason` 非 nil = 点亮（悬浮提示文案），
/// nil = 熄灭。`ts` = 写入时间（ISO8601），调试用。
struct CrewAttentionChange: Codable, Equatable {
    let reason: String?
    let ts: String
}

/// 一条待执行的机长命令（起 session / 建子 crew）。`ts` 用于 drain 后按写入序执行。
struct CrewCommand: Codable, Equatable {
    let id: String
    let crewId: String
    let kind: String        // "start_session" | "create_child_crew"
    let brief: String
    let runner: String?     // start_session：nil=随 crew captainAgentKind；"claude"/"codex" 覆盖
    let isolation: Bool?    // start_session：nil/false=共享 crew 目录；true=独立 worktree
    let title: String?      // create_child_crew：nil=地名占位
    /// start_session / set_profile：模型别名/slug（claude 如 "opus"/"sonnet"，codex 如
    /// "gpt-5-codex"）。nil=对应 CLI 默认。optional → 旧队列文件缺键向后兼容。
    var model: String? = nil
    /// start_session / set_profile：thinking effort（claude: low/medium/high/xhigh/max；
    /// codex: minimal/low/medium/high）。nil=CLI 默认。
    var effort: String? = nil
    /// set_profile / schedule_wakeup：目标（=发起方自己的）session id。
    var sessionId: String? = nil
    /// schedule_wakeup：唤醒时刻（ISO8601）。
    var fireAt: String? = nil
    /// schedule_wakeup：唤醒时带回的备注。
    var note: String? = nil
    /// crew_message：投递方向 "to_parent" | "to_child"（targetHint 复用 `title` 字段）。
    var direction: String? = nil
    /// listen：只听这些发送者（"human"/"captain"/session id 或其前缀/显示名）。nil=全部。
    var senders: [String]? = nil
    /// listen：true=停止收听（此时 fireAt/senders 忽略）。
    var off: Bool? = nil
    let ts: String
}
