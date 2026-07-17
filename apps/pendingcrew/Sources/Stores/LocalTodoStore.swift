import Foundation
import Combine

/// 每 crew 一个人类 Todo 列表（task #478，右栏 inspector 面板的数据层）。
///
/// 每 crew 一个 JSON：`<dir>/<crewId>.todos.json` = `[LocalTodoItem]`。
/// - **只有人类能加条目**：唯一的新增入口是 `add`（app 侧 TodoInspectorPanel 调用）；
///   MCP 侧不暴露任何新增工具，机器人加不了。
/// - **机器人只能回应**：helper 的 `respond_todo` 走 `respond` —— **追加式**回应
///   （每次追加一条，绝不覆盖旧回应），可顺带推进状态：
///   待办 pending → 进行中 in_progress → 完成 completed。
/// - 条目编号 `number`（群消息「To do +1: #N …」里的 #N）从 1 自增，crew 内唯一。
///
/// **自包含 Foundation**（编进 `pendingcrew-mcp` re-exec helper + PendingCrewTests
/// bundle）。`@unchecked Sendable` + app↔helper 并发同 `LocalWhiteboardStore` 的
/// tech-debt（read-modify-write 竞态 last-write-wins，v1 单用户低频可接受）。
final class LocalTodoStore: @unchecked Sendable {
    static let shared = LocalTodoStore()

    /// 合法状态集（待办 → 进行中 → 完成）。
    static let validStatuses: Set<String> = ["pending", "in_progress", "completed"]

    private let directory: URL

    /// 进程内变更信号：本进程每次 save 后发一个 `crewId`（app 侧人类 add 即推）。
    /// 跨进程写（helper `respond_todo`）由 `todoChanges` 合流的目录监听补齐 ——
    /// todos JSON 与白板 JSON 同目录（`LocalWhiteboardStore.defaultDirectory`），
    /// 已被 `LocalWhiteboardStore.startWatching()` 的 DispatchSource 一并监听。
    let changes = PassthroughSubject<String, Never>()

    init(directory: URL? = nil) {
        self.directory = directory ?? LocalWhiteboardStore.defaultDirectory
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - 变更流（去轮询；与 LocalApprovalStore.approvalChanges 同模式）

    /// 本 crew 的 todo 变更流：本进程 `changes` 按 crewId 过滤 + 跨进程目录监听
    ///（helper `respond_todo` 写盘落在同一被监听目录，事件不带 crewId 不过滤）。
    func todoChanges(crewId: String) -> AsyncStream<Void> {
        LocalWhiteboardStore.shared.startWatching()
        let inProcess = changes
        let crossProcess = LocalWhiteboardStore.shared.directoryChanged
        return AsyncStream { continuation in
            let c1 = inProcess
                .filter { $0 == crewId }
                .sink { _ in continuation.yield(()) }
            let c2 = crossProcess
                .sink { _ in continuation.yield(()) }
            continuation.onTermination = { _ in c1.cancel(); c2.cancel() }
        }
    }

    // MARK: - Read

    func list(crewId: String) -> [LocalTodoItem] { load(crewId) }

    func item(crewId: String, number: Int) -> LocalTodoItem? {
        load(crewId).first { $0.number == number }
    }

    // MARK: - Write

    /// 人类新增一条 Todo（唯一新增入口；面板 UI 调用）。返回新条目（含分到的 #N）。
    @discardableResult
    func add(crewId: String, text: String) -> LocalTodoItem {
        var rows = load(crewId)
        let item = LocalTodoItem(
            id: UUID().uuidString.lowercased(),
            number: (rows.map(\.number).max() ?? 0) + 1,
            text: text,
            status: "pending",
            createdAt: ISO8601DateFormatter().string(from: Date()))
        rows.append(item)
        save(crewId: crewId, rows: rows)
        return item
    }

    /// 机器人回应某条 Todo（追加式）：往 `responses` 尾部加一条，`newStatus` 非 nil
    /// 且合法时同时推进条目状态。找不到 #N → nil；非法 status → 忽略状态只追加回应
    ///（合法性卫生归 McpServer，那里会先拒掉并报错，不走到这）。
    @discardableResult
    func respond(crewId: String, number: Int, sessionId: String,
                 senderName: String? = nil, text: String,
                 newStatus: String? = nil) -> LocalTodoItem? {
        var rows = load(crewId)
        guard let idx = rows.firstIndex(where: { $0.number == number }) else { return nil }
        rows[idx].responses.append(LocalTodoResponse(
            id: UUID().uuidString.lowercased(),
            sessionId: sessionId,
            senderName: senderName,
            text: text,
            status: newStatus,
            createdAt: ISO8601DateFormatter().string(from: Date())))
        if let s = newStatus, Self.validStatuses.contains(s) {
            rows[idx].status = s
        }
        save(crewId: crewId, rows: rows)
        return rows[idx]
    }

    // MARK: - Persistence

    private func fileURL(_ crewId: String) -> URL {
        directory.appendingPathComponent("\(crewId).todos.json")
    }

    private func load(_ crewId: String) -> [LocalTodoItem] {
        guard let data = try? Data(contentsOf: fileURL(crewId)) else { return [] }
        return (try? JSONDecoder().decode([LocalTodoItem].self, from: data)) ?? []
    }

    private func save(crewId: String, rows: [LocalTodoItem]) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: fileURL(crewId), options: .atomic)
        changes.send(crewId)
    }
}

/// 一条人类 Todo。`number` = 群消息「To do +1: #N」的 N（crew 内自增唯一）。
struct LocalTodoItem: Codable, Equatable, Identifiable {
    let id: String
    let number: Int
    let text: String
    /// "pending"（待办）| "in_progress"（进行中）| "completed"（完成）。
    var status: String
    let createdAt: String
    /// 机器人回应（追加式，按时间序）。新条目从空开始。
    var responses: [LocalTodoResponse] = []
}

/// 一条机器人回应。`status` = 本条回应把条目推进到的状态（nil = 只回应没动状态）。
struct LocalTodoResponse: Codable, Equatable, Identifiable {
    let id: String
    let sessionId: String
    /// 回应者显示名（session label，如「机长」）；nil → 渲染退回 session id。
    var senderName: String? = nil
    let text: String
    var status: String? = nil
    let createdAt: String
}

extension LocalTodoItem {
    /// 状态的中文显示（面板徽章 + MCP 回执共用）。
    static func statusLabel(_ status: String) -> String {
        switch status {
        case "pending": return "待办"
        case "in_progress": return "进行中"
        case "completed": return "完成"
        default: return status
        }
    }
}
