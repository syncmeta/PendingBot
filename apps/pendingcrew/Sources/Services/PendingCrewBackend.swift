import Foundation

/// PendingCrew 数据后端的统一抽象(T5.2)。
///
/// 双轨边界(spec v2 §5.3):
/// - `EdgeBackend`(mode = `.logged`)— wrap `PendingCrewAPI`,所有 crew /
///   subject 数据走 PendingBot edge,unified billing
/// - `LocalBackend`(mode = `.byok`)— wrap `LocalCrewStore`,纯本地 JSON,
///   crew 只本机,假 subject 单元素,Fly 等 cloud 资源不可用
///
/// **设计原则**:protocol 返回值 shape **跟 edge 一致**(`CrewSummary` /
/// `CrewDetail` / `UserSubject` 几个 model 复用),这样 UI 层 + `CrewStore`
/// 不分叉。BYOK 路径只在数据来源上短路;view 层依然只看到一组 crews + 一个
/// subject picker。
///
/// **mode + 能力查询**:UI(如 CreateCrewSheet / sidebar Machines section)
/// 在渲染时通过 `mode` 决定灰显 / 加 "登录解锁" 提示。
///
/// **未来扩展**:此 protocol 是 phase 5/v1.1+ 多个端点(share-change /
/// runner / mailbox / whiteboard 等)的注入点;每新加一个端点就在 protocol
/// 加方法 + 两个实现各补一份(LocalBackend 多半 throw `notSupportedInByok`)。
@MainActor
protocol PendingCrewBackend: AnyObject {
    var mode: BackendMode { get }

    /// 主能力查询 —— UI 渲染时判断要不要灰显 Fly / cloud 资源相关入口。
    var supportsCloudRuntime: Bool { get }

    // MARK: - Subject
    func listMySubjects() async throws -> [UserSubject]

    // MARK: - Crew
    func listCrews() async throws -> [CrewSummary]
    func getCrew(_ crewId: String) async throws -> CrewDetail
    func createCrew(_ request: CreateCrewRequest) async throws -> CreateCrewResponse

    /// `POST /v1/crews/:crewId/attach-parent`(edge);BYOK 抛 `notSupportedInByok`。
    func attachParent(crewId: String, parentCrewId: String, childKeepsBps: Int) async throws
}

// MARK: - Edge backend

/// 登录态后端 —— wrap PendingCrewAPI。
///
/// 每次方法调用前重新 resolve `(baseURL, token)`,避免 url / 凭据变化
/// 后还用老 instance。
final class EdgeBackend: PendingCrewBackend {
    var mode: BackendMode { .logged }
    var supportsCloudRuntime: Bool { true }

    private unowned let appModel: AppModel

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    func listMySubjects() async throws -> [UserSubject] {
        try await client().listMySubjects()
    }

    func listCrews() async throws -> [CrewSummary] {
        try await client().listCrews()
    }

    func getCrew(_ crewId: String) async throws -> CrewDetail {
        try await client().getCrew(crewId)
    }

    func createCrew(_ request: CreateCrewRequest) async throws -> CreateCrewResponse {
        try await client().createCrew(request)
    }

    func attachParent(crewId: String, parentCrewId: String, childKeepsBps: Int) async throws {
        try await client().attachParent(
            crewId: crewId,
            parentCrewId: parentCrewId,
            childKeepsBps: childKeepsBps
        )
    }

    private func client() throws -> PendingCrewAPI {
        guard let credential = appModel.credential else {
            throw PendingCrewBackendError.notAuthenticated
        }
        guard let url = URL(string: appModel.apiBaseURL) else {
            throw PendingCrewBackendError.invalidConfig("API base URL 无效")
        }
        return PendingCrewAPI(baseURL: url, bearerToken: credential.token)
    }
}

// MARK: - Local backend (BYOK)

/// BYOK 本地后端 —— wrap LocalCrewStore。
///
/// `listMySubjects` 返回单元素假 subject `local-byok` —— 复用 UI 层 picker
/// 形状,不再分叉(Spec §5.3 双轨边界明确"BYOK 本地态依然有 subject 概念,
/// 只是只有一个,代表 '本机/这台机器'")。
final class LocalBackend: PendingCrewBackend {
    var mode: BackendMode { .byok }
    var supportsCloudRuntime: Bool { false }

    /// 写死的"本机 BYOK"subject id —— LocalCrewStore 里 crew 都标这个
    /// responsibleSubjectId。后续 Phase 引真本机 captain 时这个 id 也是
    /// 责任分账的唯一 holder。
    static let localSubjectId = "local-byok"

    private let store: LocalCrewStore

    /// store 必传 —— 不给默认值,避免 `LocalCrewStore.shared`(@MainActor 隔离)
    /// 跟 init 的 nonisolated 默认参数 evaluation 冲突(Swift 6 mode 报错)。
    /// 调用方在 `@MainActor` 环境里显式传 `.shared`。
    init(store: LocalCrewStore) {
        self.store = store
    }

    func listMySubjects() async throws -> [UserSubject] {
        [UserSubject(
            id: Self.localSubjectId,
            kind: "byok",
            displayName: "本机 (BYOK)",
            role: nil
        )]
    }

    func listCrews() async throws -> [CrewSummary] {
        store.listCrews()
    }

    func getCrew(_ crewId: String) async throws -> CrewDetail {
        guard let detail = store.getCrew(crewId) else {
            throw PendingCrewBackendError.notFound("本地 crew \(crewId) 不存在")
        }
        return detail
    }

    func createCrew(_ request: CreateCrewRequest) async throws -> CreateCrewResponse {
        // BYOK 模式 runtimeLocation 必须是 local_host(spec §5.3:本地态
        // 不许 fly_machine)。peer_device 留 v1.1。
        guard request.runtimeLocation == "local_host" else {
            throw PendingCrewBackendError.notSupportedInByok(
                "BYOK 模式仅支持本机 runtime;Fly / peer 设备需要登录 PendingBot 账号"
            )
        }
        return store.createCrew(request)
    }

    func attachParent(crewId: String, parentCrewId: String, childKeepsBps: Int) async throws {
        throw PendingCrewBackendError.notSupportedInByok(
            "BYOK 模式不支持 crew 之间的责任分账;需要登录 PendingBot 账号才能挂父 crew"
        )
    }
}

// MARK: - Errors

enum PendingCrewBackendError: LocalizedError {
    case notAuthenticated
    case invalidConfig(String)
    case notFound(String)
    /// BYOK 路径试图调用 logged-only 端点。
    case notSupportedInByok(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "未登录"
        case .invalidConfig(let msg), .notFound(let msg), .notSupportedInByok(let msg):
            return msg
        }
    }
}
