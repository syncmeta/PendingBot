import Foundation

/// PendingCrew 数据后端的统一抽象。
///
/// **接合 v2(spec 2026-06-10:本地为家,edge 是邮差)—— 双轨平行路由作废**:
/// - `LocalBackend` 是**常驻 home**:macOS 上 crew CRUD / 白板 / 花名册
///   永远走它,本地 crew 永远在、永远显示。
/// - `EdgeBackend` 退化成"叠加能力的 API 面":遥控、未来的信箱 + 邀请,
///   以及 iOS(暂无本地后端)的过渡路径。**不再平行路由 crew 数据**;
///   能力判定用 `AppModel.isAuthenticated`,不要再用 `mode` 选后端。
///
/// **设计原则**:protocol 返回值 shape **跟 edge 一致**(`CrewSummary` /
/// `CrewDetail` / `UserSubject` 几个 model 复用),这样 UI 层 + `CrewStore`
/// 不分叉。
///
/// **未来扩展**:edge 信箱(store-and-forward)+ 远端成员接入在 block 3
/// 落地时,以"本地真源 + edge 中转"接进 LocalBackend 的白板路径,而不是
/// 给 EdgeBackend 恢复平行地位。
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

    // MARK: - Crew comms（白板/群聊，spec local-first §8.4 单后端）

    /// crew 白板时间线。edge → `GET /v1/crews/:id/messages`;BYOK → 本地
    /// `LocalWhiteboardStore`(映射成同形 `CrewWhiteboardEntry`)。
    func listCrewWhiteboard(crewId: String) async throws -> [CrewWhiteboardEntry]

    /// crew 花名册。edge → `GET /v1/crews/:id/members`;BYOK → 从本地 crew 派生
    /// (captain + 本机人类)。
    func listCrewMembers(crewId: String) async throws -> CrewRoster

    /// 发一条群聊消息(默认广播)。`attachmentIds` 只 edge 支持;BYOK 非空即抛
    /// `notSupportedInByok`。
    func postCrewMessage(crewId: String, text: String, mentions: [CrewMention], attachmentIds: [String]) async throws

    // MARK: - Models

    /// 拉 model 目录给 CreateSessionSheet 用。
    /// - 登录态:走 edge `GET /v1/models`,返回 native + OpenRouter 全集。
    /// - BYOK:edge 不可达,返回空 array(UI 改走手动 model id 输入框)。
    func listModels() async throws -> [ModelCatalogEntry]
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

    func listModels() async throws -> [ModelCatalogEntry] {
        try await client().listModels()
    }

    func listCrewWhiteboard(crewId: String) async throws -> [CrewWhiteboardEntry] {
        try await client().listCrewWhiteboard(crewId: crewId)
    }

    func listCrewMembers(crewId: String) async throws -> CrewRoster {
        try await client().listCrewMembers(crewId: crewId)
    }

    func postCrewMessage(crewId: String, text: String, mentions: [CrewMention], attachmentIds: [String]) async throws {
        try await client().postCrewMessage(
            crewId: crewId, text: text, mentions: mentions, attachmentIds: attachmentIds)
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
    var mode: BackendMode { .local }
    var supportsCloudRuntime: Bool { false }

    /// 写死的"本机 BYOK"subject id —— LocalCrewStore 里 crew 都标这个
    /// responsibleSubjectId。后续 Phase 引真本机 captain 时这个 id 也是
    /// 责任分账的唯一 holder。
    static let localSubjectId = "local-byok"

    private let store: LocalCrewStore
    private let whiteboard: LocalWhiteboardStore

    /// store / whiteboard 必传 —— 不给默认值,避免 @MainActor `.shared` 在 init
    /// 的 nonisolated 默认参数 evaluation 里冲突(Swift 6 mode 报错)。调用方在
    /// `@MainActor` 环境里显式传 `.shared`。
    init(store: LocalCrewStore, whiteboard: LocalWhiteboardStore) {
        self.store = store
        self.whiteboard = whiteboard
    }

    func listMySubjects() async throws -> [UserSubject] {
        [UserSubject(
            id: Self.localSubjectId,
            kind: "byok",
            displayName: "本机 (BYOK)",
            role: nil,
            userId: nil
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

    func listModels() async throws -> [ModelCatalogEntry] {
        // BYOK 没法走 edge 拿动态目录。CreateSessionSheet 看到空 array 时
        // 会自动 fallback 到手动输入框。
        []
    }

    func listCrewWhiteboard(crewId: String) async throws -> [CrewWhiteboardEntry] {
        // 本地白板 message → edge 同形 entry。中栏两态渲染不分叉。
        whiteboard.list(crewId: crewId).map { m in
            CrewWhiteboardEntry(
                id: m.id,
                senderKind: m.senderKind,
                senderSessionId: nil,
                senderUserId: m.senderUserId,
                senderBotId: nil,
                messageKind: "instruction",
                summary: m.text,
                createdAt: m.createdAt,
                payload: CrewWhiteboardEntry.Payload(
                    text: m.text, kind: nil, question: nil, status: nil, permissionRequestId: nil),
                attachments: nil
            )
        }
    }

    func listCrewMembers(crewId: String) async throws -> CrewRoster {
        // 从本地 crew 派生:captain(若有)+ 本机人类。本地 session 成员留 chunk 4。
        guard let detail = store.getCrew(crewId) else {
            return CrewRoster(captainBotId: nil, members: [])
        }
        var members: [CrewMember] = []
        if let cap = detail.captain {
            members.append(CrewMember(
                id: cap.botId, memberKind: "captain", userId: nil, botId: cap.botId,
                codeSessionId: nil, displayName: cap.displayName, role: "captain",
                status: "active", representsCrewId: crewId, sessionStatus: nil))
        }
        members.append(CrewMember(
            id: LocalWhiteboardStore.localUserId, memberKind: "human",
            userId: LocalWhiteboardStore.localUserId, botId: nil, codeSessionId: nil,
            displayName: "我 (本机)", role: nil, status: "active",
            representsCrewId: nil, sessionStatus: nil))
        return CrewRoster(captainBotId: detail.captain?.botId, members: members)
    }

    func postCrewMessage(crewId: String, text: String, mentions: [CrewMention], attachmentIds: [String]) async throws {
        guard attachmentIds.isEmpty else {
            throw PendingCrewBackendError.notSupportedInByok("BYOK 模式暂不支持群聊附件")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        whiteboard.appendUserMessage(crewId: crewId, text: trimmed)
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
