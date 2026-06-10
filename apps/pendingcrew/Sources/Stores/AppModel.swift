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
    /// 当前 BYOK 配置快照。nil = 没填 key。**注意**：本机模式不需要 key，这里
    /// 只是给未来 SDK/`-p` API-key 额度池路径用的选填凭据，不再决定 mode。
    @Published private(set) var byokConfig: BYOKConfig?

    /// 用户是否显式选了**本机模式**（驱动本机已登录的 claude/codex，不需要 key）。
    /// 与 `byokConfig` 解耦 —— 进本机模式不再被"有没有 key"门禁。
    @Published private(set) var localModeSelected: Bool

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
    private lazy var localBackend: LocalBackend = LocalBackend(store: .shared, whiteboard: .shared)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apiBaseURL = defaults.string(forKey: DefaultsKey.apiBaseURL) ?? "https://api.pendingname.com"
        // 用局部变量算，避免 init 里在所有 stored 属性赋值前读 self.x（definite-init）。
        let cred = PendingCrewAuthCredential.resolveDeviceGrant(
            KeychainStore.get(account: KeychainAccount.deviceGrant)
        )
        self.credential = cred
        // BYOK key 启动时只在没有 device grant 的情况下读 —— 登录态优先。
        let loadedByok: BYOKConfig?
        if cred == nil {
            let snapshot = BYOKConfig.load()
            loadedByok = snapshot.hasAnyKey ? snapshot : nil
        } else {
            loadedByok = nil
        }
        self.byokConfig = loadedByok
        // 本机模式标记：登录态优先（登录时不进本机模式）。向后兼容 —— 老用户填过
        // key（loadedByok 非 nil）也视为选过本机模式，不至于重启后退回 Welcome。
        self.localModeSelected = cred == nil
            && (defaults.bool(forKey: DefaultsKey.localModeSelected) || loadedByok?.hasAnyKey == true)
    }

    /// 当前生效的 backend。WelcomeView 阶段(没凭据)返回 nil —— UI 层
    /// 不应当在那个 phase 调任何数据方法。
    var backend: PendingCrewBackend? {
        switch mode {
        case .logged: return edgeBackend
        case .local: return localBackend
        case .none: return nil
        }
    }

    /// `RootView` 用它决定显 WelcomeView 还是直接进主界面。
    /// **Mac 默认进本机模式**（驱动本机已登录的 claude/codex），不开屏让人选模式 ——
    /// 登录是可选附加功能（侧栏入口）。iOS 仍需先登录（无本机后端）。
    var isConfigured: Bool {
        if credential != nil { return true }
        #if os(macOS)
        return true
        #else
        return localModeSelected
        #endif
    }

    /// 兼容老代码 —— `isAuthenticated` 现在仅指"登录态(device grant)",
    /// **不**包含 BYOK。BYOK 态判定用 `mode == .byok` 或 `byokConfig?.hasAnyKey`。
    var isAuthenticated: Bool { credential != nil }

    /// 当前 backend mode。两种凭据都没有时返回 nil(WelcomeView 时态)。
    var mode: BackendMode? {
        if credential != nil { return .logged }
        #if os(macOS)
        return .local   // Mac 默认本机模式（无需开屏选），登录是可选升级。
        #else
        return localModeSelected ? .local : nil
        #endif
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
        // 注意：这里**不**清 FamilyCredentialStore —— 家族凭据是账号级、跨 app
        // 共享的（PendingBot / 其它家族成员都靠它静默 mint），签出本 app 的
        // device grant 不该连坐。真要吊销家族凭据走 PendingBot 端的管理入口。
        KeychainStore.delete(account: KeychainAccount.deviceGrant)
        credential = nil
        currentUserId = nil
    }

    // MARK: - 家族 SSO（登录 SSO B4）

    /// QR 登录 consume 时随 grant 下发的家族凭据（`pfa_*`）落到共享 keychain
    /// 组，供家族 app（含本 app 重装后）静默 mint。LoginView poll 成功分支调。
    func saveFamilyCredential(token: String, subjectId: String) {
        FamilyCredentialStore.set(FamilyCredential(token: token, subjectId: subjectId))
    }

    /// 启动时静默家族 SSO：共享 keychain 组里有家族凭据且本 app 尚未登录时，
    /// 用它调 `POST /v1/device-grant/mint` 换本 app 自己的 scoped device grant，
    /// 免扫码秒登。**best-effort**：任何一步失败都静默放弃，留在本机模式，
    /// 绝不阻塞启动。RootView `.task` 调一次。
    func tryFamilySSO() async {
        guard credential == nil else { return }
        guard let cred = FamilyCredentialStore.get() else { return }
        guard let url = URL(string: apiBaseURL) else { return }
        // mint 不需要本 app 的 grant —— 鉴权是家族凭据本身作 bearer，
        // 所以跟 LoginView 的 device-login 一样用无 token 的 client。
        let api = PendingCrewAPI(baseURL: url)
        do {
            let resp = try await api.mintGrant(
                familyCredential: cred.token,
                subjectId: cred.subjectId,
                grantKind: "pendingcrew_control",
                scopes: ["subject:read", "crew:read", "crew:write", "runner:read", "runner:write"]
            )
            if let token = resp.deviceGrantToken {
                try saveDeviceGrantToken(token)   // mode 翻成 .logged
            }
        } catch {
            print("[family-sso] silent login failed: \(error)")
        }
    }

    /// 由 `CrewStore.refreshSubjects` 在解析到 subject 时回填(best-effort)。
    /// 只在拿到非 nil 值时更新,避免 BYOK 假 subject(userId == nil)把已
    /// 解析出的真实 user id 清掉。
    func setCurrentUserIdIfResolved(_ userId: String?) {
        guard let userId, !userId.isEmpty else { return }
        currentUserId = userId
    }

    /// 进入**本机模式**（驱动本机已登录的 claude/codex，不需要 key）。
    /// `LocalSetupView` 的"进入"按钮调 —— 与有没有填 key 无关。
    func enterLocalMode() {
        localModeSelected = true
        defaults.set(true, forKey: DefaultsKey.localModeSelected)
    }

    /// 把（选填的）BYOK key 写到 keychain 并落地到内存态。
    /// 不再决定 mode —— 进本机模式走 `enterLocalMode()`。空 config 也合法（清空 key）。
    func saveByokConfig(_ config: BYOKConfig) throws {
        try config.save()
        byokConfig = config.hasAnyKey ? config : nil
    }

    /// 退出本机模式 + 清掉 BYOK key。切回 WelcomeView / 登录态时调。
    func clearByokConfig() {
        BYOKConfig.clear()
        byokConfig = nil
        localModeSelected = false
        defaults.set(false, forKey: DefaultsKey.localModeSelected)
    }

    // MARK: - T4.5 crew-session server lifecycle

    /// 本 app session 缓存的 runner-host id —— 第一个 logged crew session 时
    /// 懒注册,之后复用;重启后重新注册。
    private var cachedRunnerHostId: String?

    /// auth-gated 图片加载所需的 (baseURL, device-grant token)。群聊附件
    /// `CrewRemoteImage` 用它给 `/v1/uploads/<id>` 带上 `Authorization: Bearer`。
    /// 非登录态(无 device grant)或 baseURL 无效时返回 nil —— 调用方降级到
    /// 占位图,不崩。
    var imageAuth: (baseURL: URL, token: String)? {
        guard let credential, credential.kind == .deviceGrant,
              let url = URL(string: apiBaseURL) else { return nil }
        return (url, credential.token)
    }

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
    /// **本机模式**:直接驱动本机已登录的 claude / codex CLI（用它们自己的
    /// 登录态/订阅额度，**不需要 API key**），JSON store，只本机 crew。
    /// 过去叫 "byok" —— 其实 key 是选填的（仅未来 SDK/`-p` API-key 额度池路径用），
    /// 进本机模式不该被"有没有 key"门禁，所以正名为 `.local`。
    case local
}

private enum DefaultsKey {
    static let apiBaseURL = "PendingCrew.apiBaseURL"
    /// 用户显式选了"本机模式"（与有没有 BYOK key 解耦）。
    static let localModeSelected = "PendingCrew.localModeSelected"
}

enum KeychainAccount {
    static let deviceGrant = "device-grant"
    /// BYOK provider key 三件套。三个分开存,删/查/写都 per-key 走 Keychain
    /// 的 generic-password。命名前缀 `byok-` 跟 `device-grant` 区分。
    static let byokAnthropic = "byok-anthropic"
    static let byokOpenAI = "byok-openai"
    static let byokGemini = "byok-gemini"
}
