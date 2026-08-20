import Foundation
import Security
import Supabase

/// Auth session storage that always targets the **data-protection keychain**.
///
/// Native macOS (AppKit/SwiftUI, not Catalyst) defaults `SecItem` to the
/// legacy file-based login keychain, whose ACL is bound to the signing
/// binary. Every local rebuild changes the binary, so the OS re-prompts for
/// the login-keychain password ("大绿豆想使用你在鑰匙圈的 supabase.gotrue.swift
/// 裡儲存的機密資訊"). iOS / iPad / Mac Catalyst never hit this because their
/// default keychain *is* the data-protection keychain — entitlement-gated and
/// silent.
///
/// supabase-swift's bundled `KeychainLocalStorage` never sets
/// `kSecUseDataProtectionKeychain`, so on native macOS it lands on the legacy
/// keychain. This implementation mirrors it but flips that flag on every
/// query, putting macOS on the same silent, entitlement-gated path as iOS.
///
/// No access group is specified, so items fall into the app's default group
/// (the `application-identifier`, i.e. the first entry of the
/// `keychain-access-groups` entitlement — `M42BKJN82S.com.pendingname.pendingbot`),
/// which the app is already signed for on every platform.
///
/// Cross-platform behaviour:
/// - iOS / iPad / Catalyst already default to the data-protection keychain, so
///   the explicit flag is a no-op there — same store, same items, no logout.
/// - Native macOS migrates off the legacy keychain, so the existing Mac
///   session is abandoned once and the user re-logs in a single time; silent
///   thereafter, across rebuilds.
struct DataProtectionKeychainStorage: AuthLocalStorage {
    private let service = "supabase.gotrue.swift"

    private func baseQuery(_ key: String, data: Data? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let data {
            query[kSecValueData as String] = data
        }
        return query
    }

    func store(key: String, value: Data) throws {
        var addQuery = baseQuery(key, data: value)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(key) as CFDictionary,
                [kSecValueData as String: value] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainStorageError(status: updateStatus)
            }
        } else if addStatus != errSecSuccess {
            throw KeychainStorageError(status: addStatus)
        }
    }

    func retrieve(key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStorageError(status: status)
        }
        return result as? Data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStorageError(status: status)
        }
    }
}

struct KeychainStorageError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain operation failed (\(status)): \(message)"
    }
}
