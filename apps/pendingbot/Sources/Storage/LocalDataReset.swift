import Foundation
#if os(macOS)
import AppKit
#endif

/// PendingBot「清除本机所有数据」协调器。仅本地清除(≠ 注销账号服务端删号)。
///
/// 清除范围:
/// 1. 遥测身份(PostHog / Sentry / RevenueCat)
/// 2. Supabase 会话 + SQLCipher 本地库 + (条件)PendingCrew 共享登录凭据 + iOS 头像缓存
/// 3. HTTP / 图片 URLCache
/// 4. UserDefaults 整域(外观/语音传输/通知偏好/排序/arena 偏好/未读等)
///
/// macOS:清完重启进程(绕开运行时 @AppStorage / 单例缓存);
/// iOS:signOut 已置空 `AccountStore.current` → RootView 自动回登录页(iOS 不能自重启)。
@MainActor
enum LocalDataReset {

    /// 与 PendingCrew 共享的登录状态是否存在(共享凭证是 macOS-only)。
    static var sharedLoginPresent: Bool {
        #if os(macOS)
        return FamilyCredentialWriter.get() != nil
        #else
        return false
        #endif
    }

    /// 执行清除。
    /// - Parameters:
    ///   - accountStore: 当前 `AccountStore` 实例,用于 signOut。
    ///   - clearSharedLogin: `true` 时连「与 PendingCrew 共享的登录状态」一并删除。
    static func performReset(accountStore: AccountStore, clearSharedLogin: Bool) async {
        // 1. 遥测身份(PostHog/Sentry/RevenueCat)
        Telemetry.shared.reset()
        // 2. 会话 + 本地 SQLCipher 库 + (条件)共享登录 + iOS 头像缓存 —— 复用 signOut。
        //    用 .local scope:清本机数据不应撤销用户其他设备的会话。
        //    (App Support 目录目前只有 pendingbot.sqlite,已被 wipeForSignOut 删,无额外目录要清。)
        await accountStore.signOut(clearSharedLogin: clearSharedLogin, scope: .local)
        // 3. HTTP/图片缓存
        URLCache.shared.removeAllCachedResponses()
        // 4. UserDefaults 整域(外观/语音传输/通知偏好/排序/arena 偏好/未读等)
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        // 5. 收尾
        #if os(macOS)
        relaunch()   // 绕开运行进程里的 @AppStorage / 单例缓存
        #endif
        // iOS: signOut 已置空 current → RootView 自动回登录页;iOS 不能自重启。
    }

    #if os(macOS)
    private static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    #endif
}
