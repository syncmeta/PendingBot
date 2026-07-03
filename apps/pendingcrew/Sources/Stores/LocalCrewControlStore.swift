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

    // MARK: - Command queue（helper 侧：start_session / create_child_crew）
    //
    // rename 是 last-write-wins 单文件；起 session / 建子 crew 可重复，用队列：
    // 每条一个独立文件 <crewId>.<uuid>.crewcmd.json，drain 时全读+删。

    /// 机长起 worker session：brief 必填（空则忽略）；runner/isolation 可选。
    func enqueueStartSession(crewId: String, brief: String, runner: String?, isolation: Bool?) {
        enqueue(CrewCommand(
            id: UUID().uuidString.lowercased(), crewId: crewId, kind: "start_session",
            brief: brief, runner: runner, isolation: isolation, title: nil,
            ts: ISO8601DateFormatter().string(from: Date())))
    }

    /// 机长以当前 crew 为父建子 crew：brief 必填；title 可选（不给 → app 侧地名占位）。
    func enqueueCreateChildCrew(crewId: String, brief: String, title: String?) {
        enqueue(CrewCommand(
            id: UUID().uuidString.lowercased(), crewId: crewId, kind: "create_child_crew",
            brief: brief, runner: nil, isolation: nil, title: title,
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

    private func fileURL(_ crewId: String) -> URL {
        // crewId 是受控本地 id（"local-"+uuid，无路径分隔符/点），直接当文件名安全。
        directory.appendingPathComponent("\(crewId)\(Self.suffix)")
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

/// 一条待执行的机长命令（起 session / 建子 crew）。`ts` 用于 drain 后按写入序执行。
struct CrewCommand: Codable, Equatable {
    let id: String
    let crewId: String
    let kind: String        // "start_session" | "create_child_crew"
    let brief: String
    let runner: String?     // start_session：nil=随 crew captainAgentKind；"claude"/"codex" 覆盖
    let isolation: Bool?    // start_session：nil/false=共享 crew 目录；true=独立 worktree
    let title: String?      // create_child_crew：nil=地名占位
    let ts: String
}
