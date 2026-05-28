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
@MainActor
final class AppModel: ObservableObject {
    @Published var apiBaseURL: String
    @Published private(set) var credential: PendingCrewAuthCredential?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apiBaseURL = defaults.string(forKey: DefaultsKey.apiBaseURL) ?? "https://api.pendingname.com"
        self.credential = PendingCrewAuthCredential.resolveDeviceGrant(
            KeychainStore.get(account: KeychainAccount.deviceGrant)
        )
    }

    var isAuthenticated: Bool { credential != nil }

    func saveAPIBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        apiBaseURL = trimmed
        defaults.set(trimmed, forKey: DefaultsKey.apiBaseURL)
    }

    func saveDeviceGrantToken(_ token: String) throws {
        try KeychainStore.set(token, account: KeychainAccount.deviceGrant)
        credential = PendingCrewAuthCredential.resolveDeviceGrant(token)
    }

    func clearAuth() {
        KeychainStore.delete(account: KeychainAccount.deviceGrant)
        credential = nil
    }
}

private enum DefaultsKey {
    static let apiBaseURL = "PendingCrew.apiBaseURL"
}

enum KeychainAccount {
    static let deviceGrant = "device-grant"
}
