import Foundation

/// BYOK 本地白板持久化（spec 2026-06-05-pendingcrew-local-first-crew-design §2
/// 本地 crew-comms）。
///
/// 每 crew 一个 JSON 文件：`<dir>/<crewId>.json` = `[LocalWhiteboardMessage]`。
/// 单 crew 消息量可控，整文件 append-rewrite 足够（白板不是高频 IO）。
///
/// **自包含**：只依赖 Foundation，**不引** edge 的 `CrewWhiteboardEntry`。
/// 这样能单独编进 PendingCrewTests bundle（脚手架期 test 不链 app module，
/// 见 project.yml 注释）。映射成 `CrewWhiteboardEntry` 的活由 `LocalBackend`
/// 在 app 模块里做。
///
/// 不依赖 PendingBot/edge —— 是 PendingCrew 开源核心的一部分。
@MainActor
final class LocalWhiteboardStore {
    /// 本机 BYOK "人类成员" 的合成发言者 id —— 给 `CrewSenderResolver` 认
    /// "自己"（右对齐）。与 `LocalBackend.localSubjectId` 区分：那是责任主体，
    /// 这是发言者身份。
    static let localUserId = "local-byok-user"

    static let shared = LocalWhiteboardStore()

    private let directory: URL
    private let fm = FileManager.default

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            self.directory = base
                .appendingPathComponent("PendingCrew", isDirectory: true)
                .appendingPathComponent("whiteboards", isDirectory: true)
        }
        try? fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Public

    /// 列出某 crew 的全部白板消息（按写入顺序）。文件缺失 → 空。
    func list(crewId: String) -> [LocalWhiteboardMessage] {
        load(crewId: crewId)
    }

    /// 追加一条本机人类消息。
    func appendUserMessage(crewId: String, text: String) {
        var rows = load(crewId: crewId)
        rows.append(LocalWhiteboardMessage(
            id: UUID().uuidString.lowercased(),
            senderKind: "user",
            senderUserId: Self.localUserId,
            text: text,
            createdAt: ISO8601DateFormatter().string(from: Date())
        ))
        save(crewId: crewId, rows: rows)
    }

    // MARK: - Persistence

    private func fileURL(_ crewId: String) -> URL {
        // crewId 是受控本地 id（"local-"+uuid），无路径分隔符，直接当文件名安全。
        directory.appendingPathComponent("\(crewId).json")
    }

    private func load(crewId: String) -> [LocalWhiteboardMessage] {
        guard let data = try? Data(contentsOf: fileURL(crewId)) else { return [] }
        return (try? JSONDecoder().decode([LocalWhiteboardMessage].self, from: data)) ?? []
    }

    private func save(crewId: String, rows: [LocalWhiteboardMessage]) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: fileURL(crewId), options: .atomic)
    }
}

/// 本地白板的持久化行。与 edge wire 解耦（edge 的 `CrewWhiteboardEntry` 只有
/// Decodable 且依赖 app 模块）。`LocalBackend` 把它映射成 `CrewWhiteboardEntry`
/// 给中栏渲染。
struct LocalWhiteboardMessage: Codable, Equatable {
    let id: String
    /// 'user' | 'session' | 'captain' | …（目前只有 user；session/captain 留后续 chunk）
    let senderKind: String
    let senderUserId: String?
    let text: String
    /// ISO8601 字符串，与 edge `created_at` 同形，便于 UI 复用时间分隔逻辑。
    let createdAt: String
}
