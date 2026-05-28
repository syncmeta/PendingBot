import Foundation
import SwiftUI

/// Crew 列表 + detail 缓存。
///
/// 设计原则（AppModel 顶端注释 + spec v2 §11）：**不**回到 "10+ 散装
/// `@Published` 字典" 的老路。所有 detail 数据进 `details: [String: CrewDetail]`
/// —— 一个 crewId 对应一个结构化 `CrewDetail`。新加字段时改 `CrewDetail`
/// struct，不要在这里 / view 里到处摊。
///
/// Store 不持有自己的 `PendingCrewAPI` 实例。`AppModel` 持有 base URL +
/// credential，每次 refresh 通过 `client(_:)` 拼出一个新的 API（轻量 struct，
/// `URLSession` 是共享的）。这样切 base URL / 重新登录都自然生效。
@MainActor
final class CrewStore: ObservableObject {
    @Published private(set) var crews: [CrewSummary] = []
    @Published private(set) var details: [String: CrewDetail] = [:]
    @Published private(set) var subjects: [UserSubject] = []
    @Published var selectedCrewId: String?
    @Published private(set) var loadingList: Bool = false
    @Published private(set) var loadingDetailIds: Set<String> = []
    @Published private(set) var loadingSubjects: Bool = false
    @Published var error: String?

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
        guard let api = client() else { return }
        loadingList = true
        defer { loadingList = false }
        do {
            let result = try await api.listCrews()
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
        guard let api = client() else { return }
        loadingDetailIds.insert(crewId)
        defer { loadingDetailIds.remove(crewId) }
        do {
            let detail = try await api.getCrew(crewId)
            details[crewId] = detail
        } catch {
            self.error = "加载 crew 详情失败：\(error.localizedDescription)"
        }
    }

    func refreshSubjects() async {
        guard let api = client() else { return }
        loadingSubjects = true
        defer { loadingSubjects = false }
        do {
            subjects = try await api.listMySubjects()
        } catch {
            self.error = "加载 subject 列表失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Mutations

    /// 创建 crew 并把它选中。新 crew 进 `crews` 头部 + 自动选中。
    /// 返回值是新 crew 的 summary —— caller 决定要不要做后续操作
    /// （比如关 sheet）。
    @discardableResult
    func createCrew(_ request: CreateCrewRequest) async throws -> CreateCrewResponse {
        guard let api = client() else {
            throw PendingCrewAPIError.invalidResponse
        }
        let response = try await api.createCrew(request)
        // 刷新列表 + detail —— 避免靠 client 自己拼 CrewSummary 出 bug
        // （edge 端将来加字段时会自动跟上）。
        await refreshList()
        await refreshDetail(response.crewId)
        selectedCrewId = response.crewId
        return response
    }

    // MARK: - Auth lifecycle

    /// 用户退出登录时调，清掉所有内存态。`AppModel.clearAuth` 时一并调。
    func reset() {
        crews = []
        details = [:]
        subjects = []
        selectedCrewId = nil
        error = nil
    }

    // MARK: - Internals

    private func client() -> PendingCrewAPI? {
        guard let credential = appModel.credential else {
            self.error = "未登录"
            return nil
        }
        guard let url = URL(string: appModel.apiBaseURL) else {
            self.error = "API base URL 无效"
            return nil
        }
        return PendingCrewAPI(baseURL: url, bearerToken: credential.token)
    }
}
