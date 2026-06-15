import Foundation
import Combine

/// BYOK 本地白板持久化（spec 2026-06-05-pendingcrew-local-first-crew-design §2
/// 本地 crew-comms）。
///
/// 每 crew 一个 JSON 文件：`<dir>/<crewId>.json` = `[LocalWhiteboardMessage]`。
/// 单 crew 消息量可控，整文件 append-rewrite 足够（白板不是高频 IO）。
///
/// **自包含**：只依赖 Foundation，**不引** edge 的 `CrewWhiteboardEntry`。
/// 这样能单独编进 PendingCrewTests bundle **和 `pendingcrew-mcp` helper target**
/// （chunk 4：claude 子进程的 MCP server / hook 读写同一份白板文件）。映射成
/// `CrewWhiteboardEntry` 的活由 `LocalBackend` 在 app 模块里做。
///
/// **非 `@MainActor`**：helper CLI（非 main-actor）要用。app 侧只从 `@MainActor`
/// 调（LocalBackend / CrewChatView），不跨 actor 传实例。`@unchecked Sendable`：
/// 实例状态全 `let`（不可变），共享可变资源是磁盘文件 —— **app 与 helper 并发读写
/// 同一 JSON 有 read-modify-write 竞态（last-write-wins 偶丢消息）**，v1 单用户低频
/// 可接受，已记 tech-debt，后续上 append-only log / 文件锁。
///
/// 不依赖 PendingBot/edge —— 是 PendingCrew 开源核心的一部分。
final class LocalWhiteboardStore: @unchecked Sendable {
    /// 本机 BYOK "人类成员" 的合成发言者 id —— 给 `CrewSenderResolver` 认
    /// "自己"（右对齐）。与 `LocalBackend.localSubjectId` 区分：那是责任主体，
    /// 这是发言者身份。
    static let localUserId = "local-byok-user"

    static let shared = LocalWhiteboardStore()

    /// 默认白板目录（app 与 helper 共用同一路径）。
    static let defaultDirectory: URL = {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("PendingCrew", isDirectory: true)
            .appendingPathComponent("whiteboards", isDirectory: true)
    }()

    private let directory: URL

    /// 进程内变更信号（Phase 5：去轮询）。本进程每次 append 后发一个 `crewId` ——
    /// `LocalBackend.whiteboardChanges` 订阅它、按 crewId 过滤，把中栏/右栏的
    /// 「3s 轮询」换成「append 即刷新」。app 侧人类发送 + CrewRelayAgent 搬入的
    /// relay 消息都走 app 进程内的 `.shared` 实例，立即推。
    ///
    /// **跨进程写**（helper `--mcp-serve` 子进程经 `post_to_crew` 写 agent 进展、
    /// `--mcp-hook` 注入）走另一个进程的 `LocalWhiteboardStore` 实例、不经此
    /// subject —— 由下面的 `directoryChanged` 文件监听补齐（FSEvents/DispatchSource
    /// 监 whiteboards 目录），所以跨进程 agent 进展也能即时推到 UI，无需轮询。
    ///
    /// `PassthroughSubject` 是引用类型，作 `let` 持有不破坏 `@unchecked Sendable`
    /// （实例状态仍全 `let`）；本仓低频单写、`.send` 在 MainActor app 路径 + helper
    /// 进程各自调，无跨线程竞态热点。
    let changes = PassthroughSubject<String, Never>()

    /// **跨进程**白板目录变更信号。`startWatching()` 起一个 DispatchSource 目录
    /// 监听，本进程**或子进程**对 `<dir>/*.json` 的写（atomic rename）会触发，
    /// 发一个 `Void` tick。`LocalBackend.whiteboardChanges` 收到即重拉本 crew ——
    /// 目录事件不带 crewId（rename 粒度到目录），但重拉单 crew 的 JSON 很廉价。
    let directoryChanged = PassthroughSubject<Void, Never>()

    /// 目录监听的可变状态 —— 锁保护，维持 `@unchecked Sendable`（实例其余皆 `let`）。
    private let watchLock = NSLock()
    private var watchSource: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Cross-process directory watch（去轮询：补齐 helper 子进程的写）

    /// 起目录监听（幂等）。监 whiteboards 目录的写/rename —— atomic write 落盘
    /// （写临时文件 → rename 覆盖）在目录上表现为写/rename 事件，per-file fd 会因
    /// inode 被换而失效，所以监**目录**而非单文件。事件 → `directoryChanged` tick。
    /// app UI（`LocalBackend`）首次订阅时调；短命的 helper stdio 进程不调（无需）。
    func startWatching() {
        watchLock.lock()
        defer { watchLock.unlock() }
        guard watchSource == nil else { return }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.directoryChanged.send(())
        }
        source.setCancelHandler { close(fd) }
        watchFD = fd
        watchSource = source
        source.resume()
    }

    // MARK: - Public

    /// 列出某 crew 的全部白板消息（按写入顺序）。文件缺失 → 空。
    func list(crewId: String) -> [LocalWhiteboardMessage] {
        load(crewId: crewId)
    }

    /// 该 `afterId` **之后**的消息（读未读用）。afterId=nil 或找不到 → 返回全部。
    func entries(crewId: String, afterId: String?) -> [LocalWhiteboardMessage] {
        let all = load(crewId: crewId)
        guard let afterId, let idx = all.firstIndex(where: { $0.id == afterId }) else { return all }
        return Array(all.suffix(from: all.index(after: idx)))
    }

    /// 追加一条本机人类消息。`senderName` = 人类显示名（如已知；nil → 渲染退回「我/人类」）。
    func appendUserMessage(crewId: String, text: String, senderName: String? = nil) {
        append(crewId: crewId, LocalWhiteboardMessage(
            id: UUID().uuidString.lowercased(),
            senderKind: "user",
            senderUserId: Self.localUserId,
            senderSessionId: nil,
            category: nil,
            text: text,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            senderName: senderName))
    }

    /// 追加一条 session（编码 agent）消息（chunk 4：`post_to_crew`）。`senderName` =
    /// 该 session 的显示 label（如「机长」/「Claude Code · abc123」；nil → 渲染退回
    /// `session:<id>`，给 agent 看的白板就不再只剩裸 uuid）。
    func appendSessionMessage(crewId: String, sessionId: String, text: String,
                              category: String? = nil, senderName: String? = nil) {
        append(crewId: crewId, LocalWhiteboardMessage(
            id: UUID().uuidString.lowercased(),
            senderKind: "session",
            senderUserId: nil,
            senderSessionId: sessionId,
            category: category,
            text: text,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            senderName: senderName))
    }

    /// 追加一条 **relay 拉下来的** 消息（接合 v2 block 3：CrewRelayAgent 把
    /// edge 信箱新条目搬进本地白板）。幂等：同 `relayRemoteId` 已存在 → no-op
    /// （edge 拉取 `?since=` 是闭区间,游标边界条目会重复出现）。
    func appendRelayMessage(
        crewId: String,
        remoteId: String,
        senderKind: String,
        senderDisplayName: String?,
        text: String,
        createdAt: String
    ) {
        let rows = load(crewId: crewId)
        guard !rows.contains(where: { $0.relayRemoteId == remoteId }) else { return }
        append(crewId: crewId, LocalWhiteboardMessage(
            id: UUID().uuidString.lowercased(),
            senderKind: senderKind,
            senderUserId: nil,
            senderSessionId: nil,
            category: nil,
            text: text,
            createdAt: createdAt,
            relayRemoteId: remoteId,
            senderDisplayName: senderDisplayName))
    }

    /// 该 crew 已从 relay 同步进来的 edge message id 集合（拉取去重用）。
    func relayRemoteIds(crewId: String) -> Set<String> {
        Set(load(crewId: crewId).compactMap(\.relayRemoteId))
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

    private func append(crewId: String, _ msg: LocalWhiteboardMessage) {
        var rows = load(crewId: crewId)
        rows.append(msg)
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: fileURL(crewId), options: .atomic)
        // 单一写入漏斗 —— 所有 public append 变体都经此，发一个变更信号即覆盖全部
        // （人类发送 / session 进展 / relay 搬入）。订阅方按 crewId 过滤。
        changes.send(crewId)
    }
}

/// 本地白板的持久化行。与 edge wire 解耦（edge 的 `CrewWhiteboardEntry` 只有
/// Decodable 且依赖 app 模块）。`LocalBackend` 把它映射成 `CrewWhiteboardEntry`
/// 给中栏渲染。新增可选字段向后兼容（旧 JSON 缺键 → nil）。
struct LocalWhiteboardMessage: Codable, Equatable {
    let id: String
    /// 'user' | 'session' | 'captain' | …
    let senderKind: String
    let senderUserId: String?
    /// session 作者的 id（senderKind == "session" 时）。
    let senderSessionId: String?
    /// post_to_crew 的 category（progress/question/milestone），可选。
    let category: String?
    let text: String
    /// ISO8601 字符串，与 edge `created_at` 同形，便于 UI 复用时间分隔逻辑。
    let createdAt: String
    /// relay 来源的 edge message id（接合 v2 block 3）。非 nil = 这条是
    /// CrewRelayAgent 从 edge 信箱搬进来的 —— 上行推送侧据此排除（防回环），
    /// 拉取侧据此去重。本地产生的消息恒为 nil（默认值兼容旧调用方/旧 JSON）。
    var relayRemoteId: String? = nil
    /// relay 消息在 edge 侧的发送者显示名（iOS 用户名 / bot 名）。本地消息 nil。
    var senderDisplayName: String? = nil
    /// 本地产生消息（session post_to_crew / 人类输入）的发送者显示名 ——
    /// 给 agent 看的白板（`HookEmitter.render`）用它替掉裸 `session:<uuid>` / 「人类」。
    /// 与 `senderDisplayName`（relay 远端名）区分来源；渲染时两者皆可作回退。
    /// 新增可选字段向后兼容（旧 JSON 缺键 → nil）。
    var senderName: String? = nil
}
