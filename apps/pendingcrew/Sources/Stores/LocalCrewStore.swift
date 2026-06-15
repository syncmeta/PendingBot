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
            // title 缺省/空 = 自动 → 本地占位 "未命名 crew"（后续接本机 captain
            // 总结时回填真名；本地路径没有 captain summary，先放占位）。
            title: request.title?.trimmingCharacters(in: .whitespaces).isEmpty == false
                ? request.title!.trimmingCharacters(in: .whitespaces)
                : "未命名 crew",
            responsibleSubjectId: request.responsibleSubjectId,
            // 本地 crew 恒「本机」 —— runtime_location 永远 local_host。
            runtimeLocation: "local_host",
            workingDirectory: request.workingDirectory,
            machineId: request.machineId,
            captainBotId: captainBotId,
            captainName: captainName,
            captainAgentKind: request.captainAgentKind,
            createdAt: now,
            updatedAt: now
        )
        crews[id] = crew
        persistToDisk()
        return CreateCrewResponse(crewId: id, captainBotId: captainBotId)
    }

    // MARK: - 本地 DAG 父边

    /// 把 `parentCrewId` 加进 `crewId` 的父边集合(去重)。
    ///
    /// **禁环**:若 `parentCrewId` 已经是 `crewId` 的后代(沿 children 向下能
    /// 到达),挂上去会成环 —— 拒绝并抛 `LocalCrewStoreError.wouldCreateCycle`。
    /// children 由「谁的 parentCrewIds 含本 crew」反推,所以"后代"判定走
    /// `descendants(of:)`。自挂自(crewId == parentCrewId)也算环,拒绝。
    func attachParent(crewId: String, parentCrewId: String) throws {
        guard crewId != parentCrewId else {
            throw LocalCrewStoreError.wouldCreateCycle
        }
        guard crews[crewId] != nil else {
            throw LocalCrewStoreError.crewNotFound(crewId)
        }
        guard crews[parentCrewId] != nil else {
            throw LocalCrewStoreError.crewNotFound(parentCrewId)
        }
        // parentCrewId 是 crewId 的后代 → 反向连边会成环。
        if descendants(of: crewId).contains(parentCrewId) {
            throw LocalCrewStoreError.wouldCreateCycle
        }
        guard var crew = crews[crewId] else { return }
        guard !crew.parentCrewIds.contains(parentCrewId) else { return } // 已挂,幂等
        crew.parentCrewIds.append(parentCrewId)
        crews[crewId] = crew
        persistToDisk()
    }

    /// 移除一条父边。父边不存在则无操作。
    func detachParent(crewId: String, parentCrewId: String) {
        guard var crew = crews[crewId],
              let idx = crew.parentCrewIds.firstIndex(of: parentCrewId) else { return }
        crew.parentCrewIds.remove(at: idx)
        crews[crewId] = crew
        persistToDisk()
    }

    /// `crewId` 的全部后代 id(沿 children 向下 BFS)。child = 其
    /// parentCrewIds 含某 crew 的那些 crew。带 visited 自保防脏数据成环。
    func descendants(of crewId: String) -> Set<String> {
        var result: Set<String> = []
        var queue: [String] = [crewId]
        while let current = queue.popLast() {
            for (id, crew) in crews where crew.parentCrewIds.contains(current) {
                if result.insert(id).inserted {
                    queue.append(id)
                }
            }
        }
        return result
    }

    // MARK: - Relay 绑定（接合 v2 block 3：edge 信箱）

    /// 把本地 crew 绑到 edge 侧 relay crew conversation（「接入 PendingBot」
    /// 成功后调）。同时把推送水位初始化为 nil —— CrewRelayAgent 首 tick 会
    /// 以"绑定时白板末尾"为基线，只上行之后的新消息。
    func bindRemoteConversation(crewId: String, remoteConversationId: String) {
        guard var crew = crews[crewId] else { return }
        crew.remoteConversationId = remoteConversationId
        crew.relayCursor = nil
        crew.relayPushedThroughId = nil
        crews[crewId] = crew
        persistToDisk()
    }

    /// 更新拉取游标（edge `lastCursor`，ISO8601）。
    func setRelayCursor(crewId: String, cursor: String?) {
        guard var crew = crews[crewId], crew.relayCursor != cursor else { return }
        crew.relayCursor = cursor
        crews[crewId] = crew
        persistToDisk()
    }

    /// 更新上行推送水位（最后一条已推送的本地白板消息 id）。
    func setRelayPushedThrough(crewId: String, messageId: String?) {
        guard var crew = crews[crewId], crew.relayPushedThroughId != messageId else { return }
        crew.relayPushedThroughId = messageId
        crews[crewId] = crew
        persistToDisk()
    }

    /// 已处理过的 task_request 远端消息 id（#242 遥控 v1）。持久化 →
    /// 重启 / 游标回拉后不会重复起 session。
    func processedTaskRequestIds(crewId: String) -> Set<String> {
        Set(crews[crewId]?.processedTaskRequestIds ?? [])
    }

    /// 标记一条 task_request 已处理。FIFO 裁剪只留最近 200 条 ——
    /// edge `?since=` 游标本来只会重放边界附近的条目，200 绰绰有余。
    func markTaskRequestProcessed(crewId: String, remoteId: String) {
        guard var crew = crews[crewId] else { return }
        var ids = crew.processedTaskRequestIds ?? []
        guard !ids.contains(remoteId) else { return }
        ids.append(remoteId)
        if ids.count > 200 { ids.removeFirst(ids.count - 200) }
        crew.processedTaskRequestIds = ids
        crews[crewId] = crew
        persistToDisk()
    }

    /// 单条 crew 的 relay 绑定快照（UI / 同步代理读）。crew 不存在或未绑定
    /// remote conversation → nil。
    func relayBinding(for crewId: String) -> LocalCrewRelayBinding? {
        guard let crew = crews[crewId], let remoteId = crew.remoteConversationId else { return nil }
        return LocalCrewRelayBinding(
            crewId: crew.id,
            remoteConversationId: remoteId,
            relayCursor: crew.relayCursor,
            relayPushedThroughId: crew.relayPushedThroughId,
            captainName: crew.captainName,
            workingDirectory: crew.workingDirectory
        )
    }

    /// 所有已绑定 relay 的 crew（CrewRelayAgent 每 tick 遍历）。
    func listRelayBindings() -> [LocalCrewRelayBinding] {
        crews.keys.compactMap { relayBinding(for: $0) }
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
    /// 所选 machine id（nil = 本机）。登录态多机时记录 crew 运行在哪台机；
    /// 本机/BYOK 路径恒 nil。
    let machineId: String?
    let captainBotId: String?
    let captainName: String?
    /// 机长跑哪个本机 coding agent（`LocalCodingAgentKind.rawValue` ——
    /// "claude_code" / "codex"）。建 crew 时表单选定并持久化;机长 session 据此
    /// 起对应 agent。旧 JSON 缺此键 → decodeIfPresent 兜底 nil（下游回落 `.codex`）。
    var captainAgentKind: String? = nil
    let createdAt: String
    let updatedAt: String
    /// 本地 crew DAG 的**父边**:本 crew 挂在哪些父 crew 之下(crew id 列表)。
    /// 「家」在本地 —— DAG 组织模型不走 edge,纯本地持久化。children 不存,渲染
    /// 时从「谁的 parentCrewIds 含本 crew」反推。旧 JSON 缺此键 → 默认空数组
    /// (= 根 crew),不破坏 decode。
    var parentCrewIds: [String] = []
    // 接合 v2 block 3：edge relay 信箱绑定（optional → 旧 JSON 缺键向后兼容）。
    /// 绑定的 edge crew conversation id（「接入 PendingBot」后写入）。
    var remoteConversationId: String? = nil
    /// 拉取游标 —— edge `lastCursor`（ISO8601），断线重连续传。
    var relayCursor: String? = nil
    /// 上行推送水位 —— 最后一条已推送到 edge 的本地白板消息 id。
    var relayPushedThroughId: String? = nil
    /// 已处理过的 task_request 远端消息 id（#242 遥控 v1，FIFO 裁剪留 200）。
    var processedTaskRequestIds: [String]? = nil

    /// memberwise init —— `createCrew` 等内部构造点用。父边默认空(新建 = 根)。
    init(
        id: String,
        title: String,
        responsibleSubjectId: String,
        runtimeLocation: String,
        workingDirectory: String?,
        machineId: String?,
        captainBotId: String?,
        captainName: String?,
        captainAgentKind: String? = nil,
        createdAt: String,
        updatedAt: String,
        parentCrewIds: [String] = [],
        remoteConversationId: String? = nil,
        relayCursor: String? = nil,
        relayPushedThroughId: String? = nil,
        processedTaskRequestIds: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.responsibleSubjectId = responsibleSubjectId
        self.runtimeLocation = runtimeLocation
        self.workingDirectory = workingDirectory
        self.machineId = machineId
        self.captainBotId = captainBotId
        self.captainName = captainName
        self.captainAgentKind = captainAgentKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.parentCrewIds = parentCrewIds
        self.remoteConversationId = remoteConversationId
        self.relayCursor = relayCursor
        self.relayPushedThroughId = relayPushedThroughId
        self.processedTaskRequestIds = processedTaskRequestIds
    }

    /// 显式 decoder —— 非 optional 的 `parentCrewIds` 在旧 JSON(无此键)里
    /// 合成 Codable 会抛 keyNotFound,这里用 decodeIfPresent ?? [] 兜底。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        responsibleSubjectId = try c.decode(String.self, forKey: .responsibleSubjectId)
        runtimeLocation = try c.decode(String.self, forKey: .runtimeLocation)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        machineId = try c.decodeIfPresent(String.self, forKey: .machineId)
        captainBotId = try c.decodeIfPresent(String.self, forKey: .captainBotId)
        captainName = try c.decodeIfPresent(String.self, forKey: .captainName)
        captainAgentKind = try c.decodeIfPresent(String.self, forKey: .captainAgentKind)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        parentCrewIds = try c.decodeIfPresent([String].self, forKey: .parentCrewIds) ?? []
        remoteConversationId = try c.decodeIfPresent(String.self, forKey: .remoteConversationId)
        relayCursor = try c.decodeIfPresent(String.self, forKey: .relayCursor)
        relayPushedThroughId = try c.decodeIfPresent(String.self, forKey: .relayPushedThroughId)
        processedTaskRequestIds = try c.decodeIfPresent([String].self, forKey: .processedTaskRequestIds)
    }

    var summary: CrewSummary {
        CrewSummary(
            id: id,
            title: title,
            responsibleSubjectId: responsibleSubjectId,
            runtimeLocation: runtimeLocation,
            captainBotId: captainBotId,
            status: "active",
            createdAt: createdAt,
            updatedAt: updatedAt,
            parentCrewIds: parentCrewIds,
            captainAgentKind: captainAgentKind,
            machineId: machineId
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
                captainBotId: captainBotId,
                status: "active",
                createdAt: createdAt,
                updatedAt: updatedAt,
                captainAgentKind: captainAgentKind
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

/// relay 绑定快照 —— `LocalCrew` 私有,把同步代理需要的字段抠出来给
/// CrewRelayAgent / inspector UI 用。
struct LocalCrewRelayBinding: Equatable {
    let crewId: String
    let remoteConversationId: String
    let relayCursor: String?
    let relayPushedThroughId: String?
    /// 本地 captain 名字 —— relay 上行 captain 话语时作 senderLabel。
    let captainName: String?
    /// crew 的工作目录 —— relay task_request 自动起 session 时用（#242）。
    let workingDirectory: String?
}

private struct LocalCrewFile: Codable {
    /// schema 版本号,以后 shape 改了走 migration。
    let version: Int
    let crews: [LocalCrew]
}

/// 本地 crew store 的错误。目前只覆盖 DAG 父边操作。
enum LocalCrewStoreError: LocalizedError {
    /// 挂父边会让本地 DAG 成环(parentCrewId 是 crewId 的后代,或自挂自)。
    case wouldCreateCycle
    /// 引用了不存在的本地 crew。
    case crewNotFound(String)

    var errorDescription: String? {
        switch self {
        case .wouldCreateCycle:
            return "挂到这个父 crew 会形成环(它已经是当前 crew 的子孙)"
        case .crewNotFound(let id):
            return "本地 crew \(id) 不存在"
        }
    }
}
