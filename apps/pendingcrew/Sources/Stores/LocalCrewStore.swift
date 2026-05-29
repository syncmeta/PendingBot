import Foundation

/// BYOK 模式下本地 crew 的持久化 store。
///
/// **设计取舍**:
/// - 不引入 GRDB / SQLite,简单 JSON 文件够 MVP(crew 数量预期 < 100,
///   全量读写不到 1ms)
/// - 写策略:每次 mutation 后 atomic write,避免崩溃留半截 JSON
/// - 文件位置:`~/Library/Application Support/PendingCrew/local-crews.json`
///   (Mac;iOS BYOK 路径本次 scope 不开)
/// - id 用 UUID v4(`UUID().uuidString.lowercased()`),跟 edge 端 crew id
///   形状一致,后续真要往 edge 上传时可平滑迁移
///
/// **shape**:复用 `CrewSummary` / `CrewDetail`,这样 backend protocol 两条
/// 路返回同一 model,UI 层不分叉。
/// - 因为本地 crew 没有真正的 parents/children/shares,这些字段空填(`[]`)
/// - captain 留存"用户起的名字 + 自生成 botId"(纯字符串,后续 Phase 才接
///   真本机 captain template + 模型调用)
///
/// **MainActor**:跟 `CrewStore` / `AppModel` 一致,所有 mutation 都在 UI
/// 线程跑;文件 I/O 量极小不会卡 frame。
@MainActor
final class LocalCrewStore {
    static let shared = LocalCrewStore()

    private let fileURL: URL
    private var crews: [String: LocalCrew] = [:]

    /// `nil` baseDirectory = 默认 `Application Support/PendingCrew/`;
    /// 测试时传 tmp 目录便于隔离。
    init(baseDirectory: URL? = nil) {
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else {
            // 缺省 Application Support/PendingCrew/。Application Support
            // 目录在 Mac 上没有 sandbox 限制,直接 mkdir。
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            base = support.appendingPathComponent("PendingCrew", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true
            )
        } catch {
            // mkdir 失败基本不可能(权限问题除外);记一行 stderr 即可,
            // 后续 read/write 会再报。
            NSLog("[LocalCrewStore] mkdir failed: \(error)")
        }
        self.fileURL = base.appendingPathComponent("local-crews.json")
        loadFromDisk()
    }

    // MARK: - Public API

    /// 全量 crew 列表(顺序按 createdAt DESC,跟 edge 端一致)。
    func listCrews() -> [CrewSummary] {
        crews.values
            .sorted { $0.createdAt > $1.createdAt }
            .map(\.summary)
    }

    /// 单条 crew detail。本地 crew 没有 parents/children/shares,空数组兜底。
    func getCrew(_ id: String) -> CrewDetail? {
        guard let crew = crews[id] else { return nil }
        return crew.detail
    }

    /// 新建本地 crew。返回包含自生成的 crewId + captainBotId(本地都用 UUID)。
    ///
    /// captain 当前只接 `systemGenerated(templateName:)` —— reuseBot 走的是
    /// edge 端 `/v1/me/bots` 列表;BYOK 本地暂不实现 reuse(留下次)。
    @discardableResult
    func createCrew(_ request: CreateCrewRequest) -> CreateCrewResponse {
        let now = ISO8601DateFormatter().string(from: Date())
        let id = "local-" + UUID().uuidString.lowercased()
        // captain bot id 也本地生成。后续 Phase 接真 captain template 时,
        // 这个 botId 会成为本地存活的 BotProfile 的 id。
        let captainBotId = "local-bot-" + UUID().uuidString.lowercased()
        let captainName: String
        switch request.captain {
        case .systemGenerated(let templateName):
            captainName = templateName?.isEmpty == false ? templateName! : "Captain"
        case .reuseBot(let botId):
            // BYOK 本地 store 不支持 reuse_bot 路径(没有 bot 列表)。
            // 走兜底:把传进来的 botId 当 captainBotId 直接用,name 留空
            // ——保留 shape 完整,UI 层就当一个普通 captain 看待。
            captainName = "Bot \(botId.prefix(8))"
        }

        let crew = LocalCrew(
            id: id,
            title: request.title,
            responsibleSubjectId: request.responsibleSubjectId,
            runtimeLocation: request.runtimeLocation,
            workingDirectory: request.workingDirectory,
            tag: request.tag,
            captainBotId: captainBotId,
            captainName: captainName,
            createdAt: now,
            updatedAt: now
        )
        crews[id] = crew
        persistToDisk()
        return CreateCrewResponse(crewId: id, captainBotId: captainBotId)
    }

    /// 删除一条 crew。
    func deleteCrew(_ id: String) {
        guard crews.removeValue(forKey: id) != nil else { return }
        persistToDisk()
    }

    /// 全清(切回 WelcomeView / 调试时用)。
    func clearAll() {
        crews.removeAll()
        persistToDisk()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(LocalCrewFile.self, from: data)
            crews = Dictionary(uniqueKeysWithValues: payload.crews.map { ($0.id, $0) })
        } catch {
            // JSON 损坏 → 不直接清掉,留备份让用户 / 调试时手动救;内存里
            // 留空 store 当从 0 开始。
            let backup = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("[LocalCrewStore] decode failed (\(error)), backed up to \(backup.lastPathComponent)")
        }
    }

    private func persistToDisk() {
        let payload = LocalCrewFile(version: 1, crews: Array(crews.values))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("[LocalCrewStore] persist failed: \(error)")
        }
    }
}

// MARK: - Wire types

/// 本地 crew 完整内存表示。比 CrewSummary 多 captain name + working dir,
/// 比 CrewDetail 少 parents/children/shares。
private struct LocalCrew: Codable, Equatable {
    let id: String
    let title: String
    let responsibleSubjectId: String
    let runtimeLocation: String
    let workingDirectory: String?
    let tag: String?
    let captainBotId: String?
    let captainName: String?
    let createdAt: String
    let updatedAt: String

    var summary: CrewSummary {
        CrewSummary(
            id: id,
            title: title,
            responsibleSubjectId: responsibleSubjectId,
            runtimeLocation: runtimeLocation,
            tag: tag,
            captainBotId: captainBotId,
            status: "active",
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    var detail: CrewDetail {
        CrewDetail(
            crew: CrewDetail.CrewBody(
                id: id,
                title: title,
                responsibleSubjectId: responsibleSubjectId,
                runtimeLocation: runtimeLocation,
                workingDirectory: workingDirectory,
                tag: tag,
                captainBotId: captainBotId,
                status: "active",
                createdAt: createdAt,
                updatedAt: updatedAt
            ),
            // 本地 crew 没有 DAG / 责任分账 —— 全空数组。后续 Phase 接本机
            // captain template 时也只动 captain section,parents/children
            // 这些跨 crew 关系本地路径不开。
            parents: [],
            children: [],
            shares: [
                CrewDetail.ResponsibilityShare(
                    subjectId: responsibleSubjectId,
                    shareBps: 10000,
                    isTiebreaker: true,
                    displayName: "本机 (BYOK)",
                    kind: "byok"
                )
            ],
            captain: captainBotId.map {
                CrewDetail.Captain(botId: $0, displayName: captainName ?? "Captain")
            }
        )
    }
}

private struct LocalCrewFile: Codable {
    /// schema 版本号,以后 shape 改了走 migration。
    let version: Int
    let crews: [LocalCrew]
}
