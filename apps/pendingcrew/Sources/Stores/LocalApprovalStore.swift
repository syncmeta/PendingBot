import Foundation

/// 本地待审批 / 待决策 store（spec 2026-06-08-pendingcrew-ask-approval-design §4）。
///
/// 每 crew 一个 JSON：`<dir>/<crewId>.approvals.json` = `[ApprovalItem]`。
/// - **决策类（decision）**：session 经 `ask` 工具 raise 一条 pending；人类（先 captain，
///   chunk 2）在 PendingCrew UI 答 → `answer`；helper 的 `ask` long-poll `item().status
///   == answered` 拿 `reply` 返回 agent。
/// - **权限类（permission）**：PreToolUse hook raise 一条 pending；人类在待审批列表
///   allow/deny → `decide`；hook long-poll 拿 `decision` 返回 allow/deny。
///
/// **自包含 Foundation**（编进 `pendingcrew-mcp` re-exec helper + PendingCrewTests bundle）。
/// `@unchecked Sendable` + app↔helper 并发同 `LocalWhiteboardStore` 的 tech-debt（v1 接受）。
final class LocalApprovalStore: @unchecked Sendable {
    static let shared = LocalApprovalStore()

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? LocalWhiteboardStore.defaultDirectory
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Read

    func list(crewId: String) -> [ApprovalItem] { load(crewId) }
    func pending(crewId: String) -> [ApprovalItem] { load(crewId).filter { $0.status == "pending" } }
    func item(crewId: String, id: String) -> ApprovalItem? { load(crewId).first { $0.id == id } }

    // MARK: - Write

    /// raise 一条待处理（kind: "decision" | "permission"）。返回新 id。
    @discardableResult
    func raise(crewId: String, kind: String, sessionId: String, summary: String) -> String {
        var rows = load(crewId)
        let item = ApprovalItem(
            id: UUID().uuidString.lowercased(), kind: kind, sessionId: sessionId,
            summary: summary, status: "pending", reply: nil, decision: nil,
            createdAt: ISO8601DateFormatter().string(from: Date()))
        rows.append(item)
        save(crewId: crewId, rows: rows)
        return item.id
    }

    /// 决策类答复（人类 / captain 答文本）。
    func answer(crewId: String, id: String, reply: String) {
        update(crewId: crewId, id: id) { $0.status = "answered"; $0.reply = reply }
    }

    /// 权限类决定（allow / deny）。
    func decide(crewId: String, id: String, decision: String) {
        update(crewId: crewId, id: id) { $0.status = "answered"; $0.decision = decision }
    }

    // MARK: - Persistence

    private func fileURL(_ crewId: String) -> URL {
        directory.appendingPathComponent("\(crewId).approvals.json")
    }
    private func load(_ crewId: String) -> [ApprovalItem] {
        guard let data = try? Data(contentsOf: fileURL(crewId)) else { return [] }
        return (try? JSONDecoder().decode([ApprovalItem].self, from: data)) ?? []
    }
    private func save(crewId: String, rows: [ApprovalItem]) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: fileURL(crewId), options: .atomic)
    }
    private func update(crewId: String, id: String, _ mut: (inout ApprovalItem) -> Void) {
        var rows = load(crewId)
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        mut(&rows[idx])
        save(crewId: crewId, rows: rows)
    }
}

/// 一条待审批 / 待决策。`reply`（决策答复）/ `decision`（权限 allow|deny）按 kind 用其一。
struct ApprovalItem: Codable, Equatable {
    let id: String
    /// "decision"（ask）| "permission"（权限 hook）
    let kind: String
    let sessionId: String
    let summary: String
    /// "pending" | "answered"
    var status: String
    /// 决策类的人类 / captain 答复文本。
    var reply: String?
    /// 权限类的决定 "allow" | "deny"。
    var decision: String?
    let createdAt: String
}
