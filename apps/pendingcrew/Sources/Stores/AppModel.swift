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

    private let defaults: UserDefaults

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
