#if os(macOS)
import XCTest
// 注：LocalRunner 源码直接通过 project.yml 编进 PendingCrewTests target
// （见 project.yml 的注释），所以不需要 @testable import —— 类型已经在
// 当前 module 内可见，internal 访问级也直接可用。

final class LocalCodingAgentTests: XCTestCase {

    // MARK: - env whitelist (LocalCodingAgentEnv)

    func testEnvWhitelistDropsForbiddenKeys() {
        let env = LocalCodingAgentEnv.build(additionalEnv: [
            "ANTHROPIC_API_KEY": "sk-test",
            // 防御：caller 误传 PendingCrew 自己的 secret 也应被丢弃。
            // SUPABASE_ 是前缀封禁——新旧 key 命名都不许过。
            "PENDINGBOT_DEVICE_GRANT": "leaked",
            "PENDINGCREW_KEYCHAIN_TOKEN": "leaked",
            "SUPABASE_SERVICE_ROLE_KEY": "leaked",
            "SUPABASE_SECRET_KEY": "leaked",
            "SUPABASE_PUBLISHABLE_KEY": "leaked",
        ])
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-test")
        XCTAssertNil(env["PENDINGBOT_DEVICE_GRANT"])
        XCTAssertNil(env["PENDINGCREW_KEYCHAIN_TOKEN"])
        XCTAssertNil(env["SUPABASE_SERVICE_ROLE_KEY"])
        XCTAssertNil(env["SUPABASE_SECRET_KEY"])
        XCTAssertNil(env["SUPABASE_PUBLISHABLE_KEY"])
        // 白名单基础项必在
        XCTAssertNotNil(env["PATH"], "PATH must always be set for child process")
    }

    func testEnvWhitelistOnlyPassesThroughKnownKeys() {
        // 验：PendingCrew 父进程 env 里非白名单的 key 不会泄给子进程。
        let parent = ProcessInfo.processInfo.environment
        let env = LocalCodingAgentEnv.build(additionalEnv: [:])
        let nonWhitelistedParent = parent.keys.first { key in
            !LocalCodingAgentEnv.passthroughKeys.contains(key)
                && !key.hasPrefix("LC_")
                && !key.isEmpty
        }
        if let leak = nonWhitelistedParent {
            XCTAssertNil(env[leak],
                         "non-whitelisted parent env var '\(leak)' leaked into child env")
        }
    }

    // MARK: - billing guard (codex strips OPENAI_API_KEY)

    func testCodexEnvOmitsOpenAIApiKeyForSubscriptionBilling() {
        // An exported OPENAI_API_KEY would flip app-server to pay-as-you-go despite a
        // chatgpt auth.json. Guard: codex env must never carry it.
        let env = LocalCodingAgentEnv.build(additionalEnv: ["OPENAI_API_KEY": "sk-xxx"], kind: .codex)
        XCTAssertNil(env["OPENAI_API_KEY"])
    }

    func testClaudeEnvStillAllowsCallerKeys() {
        let env = LocalCodingAgentEnv.build(additionalEnv: ["ANTHROPIC_API_KEY": "x"], kind: .claudeCode)
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "x")
    }

    // MARK: - executable resolution

    func testResolveAgainstDiscoverAvailableIsConsistent() {
        let available = LocalCodingAgentExecutable.discoverAvailable()
        for kind in available {
            XCTAssertNotNil(LocalCodingAgentExecutable.resolve(kind),
                            "discovered kind \(kind) must be re-resolvable")
        }
        for kind in LocalCodingAgentKind.allCases where !available.contains(kind) {
            XCTAssertNil(LocalCodingAgentExecutable.resolve(kind),
                         "kind \(kind) was filtered out of discoverAvailable but resolve still returned non-nil")
        }
    }
}
#endif
