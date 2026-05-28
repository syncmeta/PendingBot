import Foundation

/// PendingCrew 未登录态 BYOK(Bring Your Own Key)配置。
///
/// 写在 Keychain(不是 UserDefaults)—— provider key 是高敏感凭据,UserDefaults
/// 明文落 plist。account 名按 provider 拆三个,删/查/写都 per-key 走 Keychain
/// 的 generic-password。
///
/// 设计:
/// - `load()` 静态拉一次,返回当前 keychain 里的快照(三个 key 全 nil 时也合法)。
/// - `save()` 把每个非 nil 字段写回;nil 字段触发 keychain 删除。
/// - `clear()` 三个 account 都 delete —— 退到 WelcomeView 时用。
/// - `hasAnyKey` 是 lightweight,用于 `RootView` 启动路由决策。
///
/// 不做的:
/// - **不做 key 验证**(只读 / 写,不发 HTTP 测试)。用户填了不对的 key,后续
///   bot 调起时让 LLM provider 自己 401,UI 显示 error。spec scope 内不做。
/// - **不在 UserDefaults 留 mode 缓存**。`hasAnyKey` 已经从 keychain 实时取,
///   一次取三个 generic-password 也就 < 1ms。
struct BYOKConfig: Equatable {
    var anthropicKey: String?
    var openaiKey: String?
    var geminiKey: String?

    static let empty = BYOKConfig(anthropicKey: nil, openaiKey: nil, geminiKey: nil)

    var hasAnyKey: Bool {
        anthropicKey?.isEmpty == false
            || openaiKey?.isEmpty == false
            || geminiKey?.isEmpty == false
    }

    /// 同步读 keychain(三次 generic-password 查询)。
    /// 调用者:`AppModel.init`(启动时定位 mode) / `LocalSetupView`(初始化表单)。
    static func load() -> BYOKConfig {
        BYOKConfig(
            anthropicKey: KeychainStore.get(account: KeychainAccount.byokAnthropic),
            openaiKey: KeychainStore.get(account: KeychainAccount.byokOpenAI),
            geminiKey: KeychainStore.get(account: KeychainAccount.byokGemini)
        )
    }

    /// 把当前 struct 落地到 keychain。
    ///
    /// - 非空 trim 后写;
    /// - 空字符串 / nil → delete 对应 account(等价于"清空这个 provider")。
    ///
    /// 任一 keychain 写失败抛出 `KeychainError`;调用方决定回滚/重试。
    func save() throws {
        try persist(anthropicKey, account: KeychainAccount.byokAnthropic)
        try persist(openaiKey, account: KeychainAccount.byokOpenAI)
        try persist(geminiKey, account: KeychainAccount.byokGemini)
    }

    /// 三个 BYOK keychain 项一并清。
    /// 切回登录态 / 用户主动签出 BYOK 时调。
    static func clear() {
        KeychainStore.delete(account: KeychainAccount.byokAnthropic)
        KeychainStore.delete(account: KeychainAccount.byokOpenAI)
        KeychainStore.delete(account: KeychainAccount.byokGemini)
    }

    /// 静态便捷读 —— `RootView` 启动路由 / `AppModel` mode 判定时用,
    /// 不需要构造完整 `BYOKConfig` 对象。
    static func hasAnyStoredKey() -> Bool {
        // 任一 account 命中即返回;短路避免三次都查。
        if let v = KeychainStore.get(account: KeychainAccount.byokAnthropic),
           !v.isEmpty { return true }
        if let v = KeychainStore.get(account: KeychainAccount.byokOpenAI),
           !v.isEmpty { return true }
        if let v = KeychainStore.get(account: KeychainAccount.byokGemini),
           !v.isEmpty { return true }
        return false
    }

    private func persist(_ value: String?, account: String) throws {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            try KeychainStore.set(trimmed, account: account)
        } else {
            KeychainStore.delete(account: account)
        }
    }
}
