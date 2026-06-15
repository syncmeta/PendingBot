import Foundation
import SwiftUI

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

    private unowned let appModel: AppModel

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
        guard let backend = currentBackend() else { return }
        loadingSubjects = true
        defer { loadingSubjects = false }
        do {
            subjects = try await backend.listMySubjects()
            // 回填登录用户 id(群聊区分"自己的气泡")。best-effort:仅在
            // subject 带真实 userId 时更新(BYOK 假 subject 是 nil,忽略)。
            appModel.setCurrentUserIdIfResolved(subjects.first?.userId)
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
}
