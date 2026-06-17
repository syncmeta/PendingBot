import Foundation
import Security
import OSLog
#if canImport(UIKit)
import UIKit
#endif

private let log = Logger.category("family-sso")

/// 家族 SSO 凭据（`pfa_*`）—— **PendingBot 写入侧**。
///
/// PendingCrew 的 `FamilyCredentialStore`（apps/pendingcrew/Sources/Support/
/// FamilyCredentialStore.swift）从共享 keychain 组读这条凭据，拿去调
/// `POST /v1/device-grant/mint` 静默换自己的 scoped device grant，免扫码。
/// 这里是缺的另一半：PendingBot 登录后把凭据写进去、登出时清掉。
/// iOS 和 macOS 都写，确保 iPad 版 PendingCrew 也能静默登录。
///
/// ⚠️ 字节级契约：service / access group / JSON 字段名必须与 PendingCrew 的
/// FamilyCredentialStore 完全一致 —— 改任何一边都要同步另一边。
///
/// 所有查询必设 `kSecUseDataProtectionKeychain: true`（理由同
/// `DataProtectionKeychainStorage`：macOS 默认 legacy 登录钥匙串会反复弹
/// 授权框，且共享 access group 只在 data-protection 钥匙串里生效）。
///
/// ⚠️ headless / ad-hoc 签名构建下 `keychain-access-groups` entitlement 不被
/// 认可，所有调用得 `errSecMissingEntitlement`（-34018）→ 静默失败。共享组
/// 读写只能在正常签名（Xcode GUI / 有证书环境）下验证。
struct FamilyCredential: Codable, Equatable {
    let token: String        // pfa_*
    let subjectId: String    // 默认 mint 目标（个人主体）
    /// 同发布者确认卡展示用 —— PendingBot 写入侧在登录时带上。可选：旧 payload
    /// 无此字段时 decode 不失败（确认卡降级到通用文案，mint 后再回填真实身份）。
    var displayName: String?
    /// 用户自有头像的 seed（pendingbot.users.custom_fields.avatar_seed），
    /// 驱动确认卡的 BotAvatar 字形。可选，同上降级。
    var avatarSeed: String?
}

enum FamilyCredentialWriter {
    static let sharedGroup = "M42BKJN82S.com.pendingname.shared"
    static let service = "com.pendingname.family-sso"

    static func get() -> FamilyCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: sharedGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let cred = try? JSONDecoder().decode(FamilyCredential.self, from: data) else {
            return nil
        }
        return cred
    }

    static func set(_ cred: FamilyCredential) {
        guard let data = try? JSONEncoder().encode(cred) else { return }
        // delete-then-add：与 PendingCrew 侧一致（共享组下 SecItemUpdate 的
        // 匹配语义跨 app 容易踩坑；写入频率极低，不在乎两次调用）。
        clear()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: sharedGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("family credential write failed: \(status)")
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: sharedGroup,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - 签发同步

    /// 有有效会话但共享组里还没有凭据时，找 worker 签发一张并写入。
    /// displayName / avatarSeed 来自调用方已解析的 profile（AccountStore.refreshProfileFlags
    /// 在拿到 custom_fields 后调用），写进凭据供 PendingCrew 确认卡离线展示。
    /// 端点若已部署 Task 3（返回顶层 displayName），则以本地 profile 为优先、
    /// 端点回包兜底；若未部署，则只用本地传入值（均可选）。
    /// 幂等（已有就跳过）；失败只 log —— 缺凭据只影响 PendingCrew 静默登录，
    /// 不能反过来影响 PendingBot 自己的登录流。
    static func syncIfNeeded(displayName: String?, avatarSeed: String?) async {
        guard get() == nil else { return }
        struct Body: Encodable { let deviceName: String }
        // 端点回包：{ familyCredential: { token, subjectId }, displayName: <top-level, 可选> }
        // （displayName 由 Task 3 在 edge 加；未部署时为 nil，可选解码不失败）
        struct Response: Decodable {
            struct Cred: Decodable { let token: String; let subjectId: String }
            let familyCredential: Cred
            let displayName: String?
        }
        let deviceName = currentFamilyDeviceName()
        do {
            let res: Response = try await APIClient()
                .post("v1/me/family-credential", body: Body(deviceName: deviceName))
            set(FamilyCredential(
                token: res.familyCredential.token,
                subjectId: res.familyCredential.subjectId,
                displayName: displayName ?? res.displayName,   // 本地 profile 优先，端点回包兜底
                avatarSeed: avatarSeed
            ))
            log.info("family credential issued and stored")
        } catch {
            log.error("family credential issuance failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - 平台设备名

private func currentFamilyDeviceName() -> String {
    #if os(macOS)
    return Host.current().localizedName ?? "Mac"
    #elseif os(iOS)
    return UIDevice.current.name
    #else
    return "Device"
    #endif
}
