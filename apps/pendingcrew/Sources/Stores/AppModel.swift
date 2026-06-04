import Foundation
import SwiftUI

/// PendingCrew 顶层状态。
///
/// Scaffold 版只保留 auth + api base url。Phase 1+ 按 spec v2 加上：
/// - subject 列表 / 当前 subject
/// - crew 树（DAG）
/// - runner hosts / machines
/// - 等等
///
/// **不要**回到老 PendingCrew 的 10+ @Published 字典爆炸路径
/// （那是 codex 留下的待重构债务）。新增状态应归并成结构化 model
/// （如 `CrewDetail` 容器），见 spec v2 §6.2 / roadmap §11。
///
/// **双轨 backend(T5.1 + T5.2)**:
/// - 登录态(`credential.kind == .deviceGrant`)→ `backend.mode == .logged`,
///   走 PendingBot edge,unified billing。
/// - 未登录 BYOK 态(`byokConfig.hasAnyKey`)→ `backend.mode == .byok`,
///   全本地,JSON crew store + 本机 captain。
/// - 两态都没有 → `RootView` 显示 WelcomeView 让用户选。
///
/// 本次 scope 内 mode 选定后不可在 app 内切换;签出走 `clearAuth()`/`clearByok()`
/// 重启回 WelcomeView。
@MainActor
final class AppModel: ObservableObject {
    @Published var apiBaseURL: String
    @Published private(set) var credential: PendingCrewAuthCredential?
    /// 当前 BYOK 配置快照。nil = 未配过(走登录路径或 WelcomeView)。
    /// 任意一个 key 非空即认为"已配 BYOK"。
    @Published private(set) var byokConfig: BYOKConfig?

    /// 登录这台机的 PendingCrew 用户(auth.users.id)。best-effort:在
    /// subject 解析出来(`CrewStore.refreshSubjects` → `/v1/me/subject` 回
    /// `user_id`)之前为 nil。群聊 `CrewChatView` 用它把
    /// `CrewWhiteboardEntry.senderUserId` 等于本值的消息识别成"自己的气泡"
    /// (右对齐、无头像);多 human crew 里其他人的消息因此不会被误判成自己。
    /// BYOK 假 subject 没有真用户 → 保持 nil。
    @Published private(set) var currentUserId: String?

    private let defaults: UserDefaults

    /// 两条 backend 实例,启动时一次性构造,mode 切换只是切引用。
    /// 不在 each-call 时 new (避免 EdgeBackend 内每次重新解析 credential
    /// 但 instance 不复用的浪费;LocalBackend.store 是 shared singleton)。
    private lazy var edgeBackend: EdgeBackend = EdgeBackend(appModel: self)
    private lazy var localBackend: LocalBackend = LocalBackend(store: .shared)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apiBaseURL = defaults.string(forKey: DefaultsKey.apiBaseURL) ?? "https://api.pendingname.com"
        self.credential = PendingCrewAuthCredential.resolveDeviceGrant(
            KeychainStore.get(account: KeychainAccount.deviceGrant)
        )
        // BYOK 启动时只在没有 device grant 的情况下读 —— 登录态优先,避免
        // 用户切回登录后还残留旧 BYOK key 误导 mode 判定。
        if self.credential == nil {
            let snapshot = BYOKConfig.load()
            self.byokConfig = snapshot.hasAnyKey ? snapshot : nil
        } else {
            self.byokConfig = nil
        }
    }

    /// 当前生效的 backend。WelcomeView 阶段(没凭据)返回 nil —— UI 层
    /// 不应当在那个 phase 调任何数据方法。
    var backend: PendingCrewBackend? {
        switch mode {
        case .logged: return edgeBackend
        case .byok: return localBackend
        case .none: return nil
        }
    }

    /// 是否已具备任一可用凭据(登录 grant 或 BYOK key)。
    /// `RootView` 用它决定显 WelcomeView 还是直接进主界面。
    var isConfigured: Bool { credential != nil || byokConfig?.hasAnyKey == true }

    /// 兼容老代码 —— `isAuthenticated` 现在仅指"登录态(device grant)",
    /// **不**包含 BYOK。BYOK 态判定用 `mode == .byok` 或 `byokConfig?.hasAnyKey`。
    var isAuthenticated: Bool { credential != nil }

    /// 当前 backend mode。两种凭据都没有时返回 nil(WelcomeView 时态)。
    var mode: BackendMode? {
        if credential != nil { return .logged }
        if byokConfig?.hasAnyKey == true { return .byok }
        return nil
    }

    func saveAPIBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        apiBaseURL = trimmed
        defaults.set(trimmed, forKey: DefaultsKey.apiBaseURL)
    }

    func saveDeviceGrantToken(_ token: String) throws {
        try KeychainStore.set(token, account: KeychainAccount.deviceGrant)
        credential = PendingCrewAuthCredential.resolveDeviceGrant(token)
        // 切到登录态后,清掉 BYOK config —— 一台机不能同时两条路。
        // (本次 scope 内"任一模式选完不可切换"是简化版,但万一启动时两边都有
        // 凭据,优先登录;BYOK 清掉避免 mode 判定歧义。)
        if credential != nil {
            BYOKConfig.clear()
            byokConfig = nil
        }
    }

    func clearAuth() {
        KeychainStore.delete(account: KeychainAccount.deviceGrant)
        credential = nil
        currentUserId = nil
    }

    /// 由 `CrewStore.refreshSubjects` 在解析到 subject 时回填(best-effort)。
    /// 只在拿到非 nil 值时更新,避免 BYOK 假 subject(userId == nil)把已
    /// 解析出的真实 user id 清掉。
    func setCurrentUserIdIfResolved(_ userId: String?) {
        guard let userId, !userId.isEmpty else { return }
        currentUserId = userId
    }

    /// 把 BYOK 配置写到 keychain 并落地到内存态。
    /// `LocalSetupView` "完成" 按钮调。
    func saveByokConfig(_ config: BYOKConfig) throws {
        try config.save()
        byokConfig = config.hasAnyKey ? config : nil
    }

    /// 清掉 BYOK 配置(三个 provider account 一并删)。
    /// 切回 WelcomeView / 退出 BYOK 模式时调。
    func clearByokConfig() {
        BYOKConfig.clear()
        byokConfig = nil
    }

    // MARK: - T4.5 crew-session server lifecycle

    /// 本 app session 缓存的 runner-host id —— 第一个 logged crew session 时
    /// 懒注册,之后复用;重启后重新注册。
    private var cachedRunnerHostId: String?

    /// 用当前 device-grant 凭据构造一个 `PendingCrewAPI`。非登录态抛错。
    func loggedAPIClient() throws -> PendingCrewAPI {
        guard let credential, credential.kind == .deviceGrant else {
            throw PendingCrewBackendError.notAuthenticated
        }
        guard let url = URL(string: apiBaseURL) else {
            throw PendingCrewBackendError.invalidConfig("API base URL 无效")
        }
        return PendingCrewAPI(baseURL: url, bearerToken: credential.token)
    }

    /// 把这台机注册成 runner host(每个 app session 一次,缓存 id 复用)。
    func ensureRunnerHost(
        api: PendingCrewAPI,
        subjectId: String,
        allowedRunnerKinds: [String]
    ) async throws -> String {
        if let id = cachedRunnerHostId { return id }
        let id = try await api.registerRunnerHost(
            responsibleSubjectId: subjectId,
            displayName: ProcessInfo.processInfo.hostName,
            allowedRunnerKinds: allowedRunnerKinds
        )
        cachedRunnerHostId = id
        return id
    }
}

/// PendingCrewBackend 的 mode 标记。
/// 放在 AppModel 文件里因为初始化路由就要用,不想为了一个 enum 起新 file。
enum BackendMode: Equatable {
    /// 走 PendingBot edge,扫码登录,unified billing。
    case logged
    /// BYOK 本地态,JSON store,只本机 crew。
    case byok
}

private enum DefaultsKey {
    static let apiBaseURL = "PendingCrew.apiBaseURL"
}

enum KeychainAccount {
    static let deviceGrant = "device-grant"
    /// BYOK provider key 三件套。三个分开存,删/查/写都 per-key 走 Keychain
    /// 的 generic-password。命名前缀 `byok-` 跟 `device-grant` 区分。
    static let byokAnthropic = "byok-anthropic"
    static let byokOpenAI = "byok-openai"
    static let byokGemini = "byok-gemini"
}
