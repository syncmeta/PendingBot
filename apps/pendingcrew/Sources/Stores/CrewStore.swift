import Foundation
import SwiftUI
import Combine

/// Crew 列表 + detail 缓存。
///
/// 设计原则（AppModel 顶端注释 + spec v2 §11）：**不**回到 "10+ 散装
/// `@Published` 字典" 的老路。所有 detail 数据进 `details: [String: CrewDetail]`
/// —— 一个 crewId 对应一个结构化 `CrewDetail`。新加字段时改 `CrewDetail`
/// struct，不要在这里 / view 里到处摊。
///
/// **T5.2 重构**:Store 不再直接拼 `PendingCrewAPI`,改成调
/// `appModel.backend`(`PendingCrewBackend` protocol)。这样登录态 / BYOK
/// 两条路用同一份 store 逻辑;backend 实例换了,数据来源自动切。
/// `client()` 老函数没了 —— 用 `currentBackend()` 替代,失败时设
/// `error = "未配置 backend"` 让 UI 显空态。
@MainActor
final class CrewStore: ObservableObject {
    @Published private(set) var crews: [CrewSummary] = []
    @Published private(set) var details: [String: CrewDetail] = [:]
    @Published private(set) var subjects: [UserSubject] = []
    /// 本账号可用机器（CreateCrewSheet 据 `count > 1` 决定显不显示 machine 选择）。
    /// 本地态恒单元素 [本机]；登录态走 `GET /v1/machines`。
    @Published private(set) var machines: [Machine] = []
    @Published var selectedCrewId: String?
    @Published private(set) var loadingList: Bool = false
    @Published private(set) var loadingDetailIds: Set<String> = []
    @Published private(set) var loadingSubjects: Bool = false
    @Published var error: String?

    /// 建带 captain 的 crew 后，请求自动起机长（用户要的零摩擦：新建即启动 + 群里报到）。
    /// `MacThreePaneView` 观察这个值（它持有 `CrewSessionRunner`），起完置 nil。
    /// 放 store 而非建 crew 的 sheet：sheet 建完即 dismiss，且拿不到 window 级的
    /// sessionRunner —— 信号经 store 冒泡给常驻的 three-pane 才能可靠落地。
    @Published var captainAutostartRequest: String?

    /// `start_session` 命令排空后的待起会话队列 —— `MacRootView`（持
    /// `CrewSessionRunner`）观察它,逐条调 `runner.startForBrief`,起完清空。
    ///
    /// **数组而非单值**:单个 `@Published` 槽位在同一次目录监听 tick 里连续
    /// 两条 `start_session` 落地时会丢命令 —— SwiftUI 对同步的 `@Published`
    /// 赋值做合并,`.onChange` 只看得到最后一次赋值。数组 append 不丢、
    /// 消费方读完整体后清空,同 `captainAutostartRequest` 的"一次性信号"
    /// 模式但扛得住同 tick 多条。
    @Published var sessionSpawnRequests: [SessionSpawnRequest] = []
    /// `set_profile` 命令排空后的待切换队列（同 sessionSpawnRequests 的数组语义,
    /// 防同 tick coalescing 丢命令）。`MacRootView` 观察执行。
    @Published var profileChangeRequests: [SessionProfileChangeRequest] = []
    /// `schedule_wakeup` 命令排空后的待登记队列。`MacRootView` 交给
    /// `CrewSessionRunner.scheduleWakeup`（持久化 + 定时器）。
    @Published var wakeupRequests: [SessionWakeupRequest] = []

    private unowned let appModel: AppModel

    /// crew-naming：机长 `rename_crew` 经 `LocalCrewControlStore` 写的待改名，
    /// 由 `LocalWhiteboardStore.directoryChanged`（跨进程目录监听）触发排空落地。
    /// 仅 macOS（本地 crew 的家）；只起一次。
    private var didStartRenameWatch = false
    private var renameWatch: AnyCancellable?

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    // MARK: - Derived

    var selectedCrew: CrewSummary? {
        guard let id = selectedCrewId else { return nil }
        return crews.first(where: { $0.id == id })
    }

    var selectedDetail: CrewDetail? {
        guard let id = selectedCrewId else { return nil }
        return details[id]
    }

    // MARK: - Selection

    func selectCrew(_ id: String?) {
        selectedCrewId = id
        guard let id else { return }
        // detail 进 cache 之前，先发起 fetch（不 await）。view 会按
        // `details[id]` 的 nil / 非 nil 状态切空态 / 内容态。
        Task { await refreshDetail(id) }
    }

    // MARK: - Refresh

    func refreshList() async {
        startRenameWatchIfNeeded()   // crew-naming：首刷时挂上改名监听（仅 macOS，幂等）
        guard let backend = currentBackend() else { return }
        loadingList = true
        defer { loadingList = false }
        do {
            let result = try await backend.listCrews()
            crews = result
            // 选中项消失（比如刚被删）的话清掉。
            if let sel = selectedCrewId, !result.contains(where: { $0.id == sel }) {
                selectedCrewId = nil
            }
        } catch {
            self.error = "加载 crew 列表失败：\(error.localizedDescription)"
        }
    }

    func refreshDetail(_ crewId: String) async {
        guard let backend = currentBackend() else { return }
        loadingDetailIds.insert(crewId)
        defer { loadingDetailIds.remove(crewId) }
        do {
            let detail = try await backend.getCrew(crewId)
            details[crewId] = detail
        } catch {
            self.error = "加载 crew 详情失败：\(error.localizedDescription)"
        }
    }

    func refreshSubjects() async {
        loadingSubjects = true
        defer { loadingSubjects = false }
        // 身份是**账号级**概念 —— 登录态一律走 edge `/v1/me/subjects` 拿真实主体
        // (display_name / kind / userId)。**不能**经 `appModel.backend`:macOS 上
        // 它恒为 `LocalBackend`(本地为家),其 `listMySubjects` 返回写死的假主体
        // 「本机 (BYOK)」—— 于是登录后侧栏身份一直显示这个假名而非真实账号
        // (本 fix 的病根)。与 `refreshMachines()` 同构:authed → edge,否则本地兜底。
        if appModel.isAuthenticated {
            // 登录态只认 edge 真实主体,**绝不**回落本地假主体(否则又显示
            // 「本机 (BYOK)」)。拉取失败保留上次 subjects、只记 error,不挡 UI。
            guard let api = try? appModel.loggedAPIClient() else { return }
            do {
                subjects = try await api.listMySubjects()
                // 回填登录用户 id(群聊区分"自己的气泡")—— 真实主体带 userId。
                appModel.setCurrentUserIdIfResolved(subjects.first?.userId)
            } catch {
                self.error = "加载身份失败：\(error.localizedDescription)"
            }
            return
        }
        // 未登录(Mac 本地态):LocalBackend 合成的「本机 (BYOK)」假主体,供
        // CreateCrewSheet 拿 `subjects.first?.id` 当本地 crew 的 responsibleSubjectId。
        // iOS 未登录无 backend → 留空(WelcomeView 时态)。
        guard let backend = appModel.backend else { subjects = []; return }
        do {
            subjects = try await backend.listMySubjects()
        } catch {
            self.error = "加载 subject 列表失败：\(error.localizedDescription)"
        }
    }

    /// 拉机器清单：本机始终在；登录态额外并入账号其它机器（edge `GET /v1/machines`）。
    /// 机器是账号概念 → 走 edge，**不**经 crew backend（crew 仍本地优先）。
    /// 失败静默回落「仅本机」—— 机器清单只是侧栏分组数据源，拉不到不挡用。
    func refreshMachines() async {
        let localMachine = Machine(
            id: DeviceIdentity.current,
            kind: Machine.Kind.computer.rawValue,
            deviceId: DeviceIdentity.current,
            displayName: DeviceIdentity.displayName,
            flyMachineId: nil,
            status: "online",
            lastSeenAt: nil
        )
        guard appModel.isAuthenticated, let api = try? appModel.loggedAPIClient() else {
            machines = [localMachine]
            return
        }
        do {
            let remote = try await api.listMachines()
            // edge 已含本机行（deviceId == 本机）则用 edge 行，否则把合成本机置顶补上。
            machines = remote.contains { $0.deviceId == DeviceIdentity.current }
                ? remote
                : [localMachine] + remote
        } catch {
            machines = [localMachine]
        }
    }

    /// 把本机真注册进账号 machine 表（edge，幂等 upsert by device_id）。登录后调。
    /// 失败静默 —— best-effort，不挡用户用 app。未登录直接跳过（返回 nil）。
    @discardableResult
    func registerSelfMachine() async -> String? {
        guard appModel.isAuthenticated, let api = try? appModel.loggedAPIClient() else {
            return nil
        }
        return try? await api.registerSelfMachine()
    }

    // MARK: - Mutations

    /// 创建 crew 并把它选中。新 crew 进 `crews` 头部 + 自动选中。
    /// 返回值是新 crew 的 summary —— caller 决定要不要做后续操作
    /// （比如关 sheet）。
    @discardableResult
    func createCrew(_ request: CreateCrewRequest) async throws -> CreateCrewResponse {
        guard let backend = currentBackend() else {
            throw PendingCrewBackendError.notAuthenticated
        }
        let response = try await backend.createCrew(request)
        // 刷新列表 + detail —— 避免靠 client 自己拼 CrewSummary 出 bug
        // （edge 端将来加字段时会自动跟上）。
        await refreshList()
        await refreshDetail(response.crewId)
        selectedCrewId = response.crewId
        // 建完请求自动起机长（detail 已 refresh，three-pane 观察到就拉起 captain）。
        // 当前建 crew 必带 systemGenerated captain；用 detail.captain 兜底判断，
        // 防将来出现无 captain 的 crew 也误触发。
        if details[response.crewId]?.captain != nil {
            captainAutostartRequest = response.crewId
        }
        return response
    }

    /// 把 `crewId` 挂到父 crew `parentCrewId` 之下(本地 DAG 父边)。
    /// 成功后刷新列表(侧栏树重算)+ 两端 detail。禁环错误向上抛给 UI 提示。
    func attachParent(crewId: String, parentCrewId: String) async throws {
        guard let backend = currentBackend() else {
            throw PendingCrewBackendError.notAuthenticated
        }
        try await backend.attachParent(
            crewId: crewId, parentCrewId: parentCrewId, childKeepsBps: 10000)
        await refreshList()
        await refreshDetail(crewId)
        await refreshDetail(parentCrewId)
    }

    /// 解绑 `crewId` 的父边 `parentCrewId`。成功后刷新列表 + 两端 detail。
    func detachParent(crewId: String, parentCrewId: String) async throws {
        guard let backend = currentBackend() else {
            throw PendingCrewBackendError.notAuthenticated
        }
        try await backend.detachParent(crewId: crewId, parentCrewId: parentCrewId)
        await refreshList()
        await refreshDetail(crewId)
        await refreshDetail(parentCrewId)
    }

    // MARK: - Auth lifecycle

    /// 用户退出登录时调，清掉所有内存态。`AppModel.clearAuth` 时一并调。
    func reset() {
        crews = []
        details = [:]
        subjects = []
        machines = []
        selectedCrewId = nil
        error = nil
    }

    // MARK: - Internals

    /// 拿当前生效的 backend;nil 时设 error 给 UI 显示。
    /// 唯一的"两态共用"入口 —— EdgeBackend / LocalBackend 切换在这里自动发生。
    private func currentBackend() -> PendingCrewBackend? {
        guard let backend = appModel.backend else {
            self.error = "未配置 backend(凭据缺失)"
            return nil
        }
        return backend
    }

    // MARK: - crew-naming：机长改名落地（仅 macOS）

    /// 挂上改名监听（幂等，仅 macOS）。机长 `rename_crew` 经离线 helper 把待改名
    /// 写进共享 `--dir`（= 白板目录）→ app 的 `directoryChanged` 跨进程目录监听触发
    /// → 排空落地到 `LocalCrewStore` + 刷新侧栏。启动先排空一次，兜住 app 没开时写入的改名。
    /// `setTitle` 写的是 `local-crews.json`（另一目录），不触发白板目录监听 → 不成环。
    private func startRenameWatchIfNeeded() {
        #if os(macOS)
        guard !didStartRenameWatch else { return }
        didStartRenameWatch = true
        LocalWhiteboardStore.shared.startWatching()
        Task {
            await applyPendingRenames()
            await drainPendingCommands()
        }
        renameWatch = LocalWhiteboardStore.shared.directoryChanged
            .sink { [weak self] in
                Task { @MainActor in
                    await self?.applyPendingRenames()
                    await self?.drainPendingCommands()
                }
            }
        #endif
    }

    /// 排空 `LocalCrewControlStore` 的待改名，逐条落到 `LocalCrewStore`；有变更才刷新列表。
    private func applyPendingRenames() async {
        let renames = LocalCrewControlStore.shared.drainRenames()
        guard !renames.isEmpty else { return }
        for r in renames { LocalCrewStore.shared.setTitle(r.crewId, r.title) }
        await refreshList()
    }

    // MARK: - crew-comms：机长命令排空（start_session / create_child_crew）

    /// 排空机长命令通道，逐条执行。`start_session` → 追加到
    /// `sessionSpawnRequests`（`MacRootView` 观察数组、逐条起、清空）；
    /// `create_child_crew` → 深度 cap 检查 → 通过既有 `createCrew` +
    /// `attachParent` 建子 crew（自动带出 `captainAutostartRequest`）+
    /// 父白板回执一行。与 `applyPendingRenames` 同一 tick 触发
    /// （`directoryChanged` 跨进程目录监听）。
    func drainPendingCommands() async {
        let cmds = LocalCrewControlStore.shared.drainCommands()
        guard !cmds.isEmpty else { return }
        for cmd in cmds {
            switch cmd.kind {
            case "start_session":
                sessionSpawnRequests.append(SessionSpawnRequest(
                    crewId: cmd.crewId, brief: cmd.brief,
                    runner: cmd.runner, isolation: cmd.isolation ?? false,
                    model: cmd.model, effort: cmd.effort))
            case "set_profile":
                guard let sid = cmd.sessionId else { break }
                profileChangeRequests.append(SessionProfileChangeRequest(
                    crewId: cmd.crewId, sessionId: sid, model: cmd.model, effort: cmd.effort))
            case "schedule_wakeup":
                guard let sid = cmd.sessionId, let fireAt = cmd.fireAt else { break }
                wakeupRequests.append(SessionWakeupRequest(
                    id: cmd.id, crewId: cmd.crewId, sessionId: sid,
                    fireAt: fireAt, note: cmd.note ?? ""))
            case "create_child_crew":
                await executeCreateChildCrew(cmd)
            default:
                break
            }
        }
    }

    /// 子 crew 深度 cap 判定的薄包装 —— 真逻辑在 `CrewChildDepthPolicy`
    /// （自包含文件，供 `CrewStoreChildDepthTests` 单测；`CrewStore` 依赖
    /// `AppModel`，未编进 PendingCrewTests bundle，没法直接测这个类型上的静态方法）。
    static func shouldRejectChild(depthOfParent d: Int, cap: Int = 3) -> Bool {
        CrewChildDepthPolicy.shouldReject(depthOfParent: d, cap: cap)
    }

    /// 执行一条 `create_child_crew` 命令：深度 cap → 继承父
    /// `workingDirectory`/`captainAgentKind`/`machineId`/`responsibleSubjectId`
    /// 建子 crew → 挂父边 → 父白板回执一行。全部失败路径都落一行回执，
    /// 不静默吞（机长看不到 app 里的错误提示，只能靠白板知道命令没成）。
    private func executeCreateChildCrew(_ cmd: CrewCommand) async {
        let parentId = cmd.crewId
        let parentDepth = LocalCrewStore.shared.depth(of: parentId)
        if Self.shouldRejectChild(depthOfParent: parentDepth) {
            postSystemNotice(crewId: parentId, text: "⚠️ 建子 crew 被拒：已达子 crew 深度上限（3 层）。")
            return
        }
        // 父 crew 的 workingDirectory 只在 detail（CrewBody）里,summary 没有这个字段 ——
        // 需要时才 fetch,不常驻占内存。取不到 detail 就现拉一次再读。
        if details[parentId] == nil {
            await refreshDetail(parentId)
        }
        guard let parentSummary = crews.first(where: { $0.id == parentId }),
              let parentDetail = details[parentId] else {
            postSystemNotice(crewId: parentId, text: "⚠️ 建子 crew 被拒：找不到父 crew 信息。")
            return
        }
        guard let wd = parentDetail.crew.workingDirectory, !wd.isEmpty else {
            postSystemNotice(crewId: parentId, text: "⚠️ 建子 crew 被拒：父 crew 无可继承的工作目录。")
            return
        }
        do {
            let request = CreateCrewRequest.make(
                responsibleSubjectId: parentSummary.responsibleSubjectId,
                title: cmd.title,
                machineId: parentSummary.machineId,
                workingDirectory: wd,
                captainAgentKind: parentSummary.captainAgentKind,
                captain: .systemGenerated(templateName: nil))
            let resp = try await createCrew(request) // 既有：内部会置 captainAutostartRequest
            try await attachParent(crewId: resp.crewId, parentCrewId: parentId)
            postSystemNotice(
                crewId: parentId,
                text: "已建子 crew「\(cmd.title ?? resp.crewId)」，子机长将自动报到。")
        } catch {
            postSystemNotice(crewId: parentId, text: "⚠️ 建子 crew 失败：\(error.localizedDescription)")
        }
    }

    /// 往 crew 白板发一行系统回执。`LocalWhiteboardStore` 没有单独的
    /// "系统消息" API —— 复用 `appendSessionMessage`（senderKind "session"），
    /// `senderName` 标成「系统」区分于真实 session/机长发言，`sessionId` 用固定
    /// 哨兵值（不对应任何真实 session，纯展示用）。
    private func postSystemNotice(crewId: String, text: String) {
        LocalWhiteboardStore.shared.appendSessionMessage(
            crewId: crewId, sessionId: "system", text: text, senderName: "系统")
    }
}

/// `start_session` 命令排空后的一次待起会话请求。`MacRootView` 观察
/// `CrewStore.sessionSpawnRequests` 数组，逐条调 `runner.startForBrief`。
/// `set_profile` 命令排空后的一次待切换请求（session 自切模型/effort）。
struct SessionProfileChangeRequest: Equatable {
    let crewId: String
    let sessionId: String
    let model: String?
    let effort: String?
}

/// `schedule_wakeup` 命令排空后的一次待登记唤醒。
struct SessionWakeupRequest: Equatable {
    let id: String
    let crewId: String
    let sessionId: String
    let fireAt: String   // ISO8601
    let note: String
}

struct SessionSpawnRequest: Equatable {
    let crewId: String
    let brief: String
    /// nil = 随 crew `captainAgentKind`；"claude"/"codex" 覆盖。
    let runner: String?
    /// true = 独立 worktree；false/nil = 共享 crew 目录。
    let isolation: Bool
    /// 模型别名/slug；nil = 对应 CLI 默认。
    var model: String? = nil
    /// thinking effort；nil = CLI 默认。
    var effort: String? = nil
}
