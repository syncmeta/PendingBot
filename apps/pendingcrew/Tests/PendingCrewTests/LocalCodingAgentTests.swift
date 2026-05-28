#if os(macOS)
import XCTest
// 注：LocalRunner 源码直接通过 project.yml 编进 PendingCrewTests target
// （见 project.yml 的注释），所以不需要 @testable import —— 类型已经在
// 当前 module 内可见，internal 访问级也直接可用。

final class LocalCodingAgentTests: XCTestCase {

    // MARK: - env whitelist

    func testEnvWhitelistDropsForbiddenKeys() {
        let spec = LocalCodingAgentLaunchSpec(
            kind: .claudeCode,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            taskBrief: "noop",
            initialPrompt: "",
            additionalEnv: [
                "ANTHROPIC_API_KEY": "sk-test",
                // 防御：caller 误传 PendingCrew 自己的 secret 也应被丢弃。
                "PENDINGBOT_DEVICE_GRANT": "leaked",
                "PENDINGCREW_KEYCHAIN_TOKEN": "leaked",
                "SUPABASE_SERVICE_ROLE_KEY": "leaked",
            ]
        )
        let env = spec.env()
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-test")
        XCTAssertNil(env["PENDINGBOT_DEVICE_GRANT"])
        XCTAssertNil(env["PENDINGCREW_KEYCHAIN_TOKEN"])
        XCTAssertNil(env["SUPABASE_SERVICE_ROLE_KEY"])
        // 白名单基础项必在
        XCTAssertNotNil(env["PATH"], "PATH must always be set for child process")
    }

    func testEnvWhitelistOnlyPassesThroughKnownKeys() {
        // 验：PendingCrew 父进程 env 里非白名单的 key 不会泄给子进程。
        let parent = ProcessInfo.processInfo.environment
        let spec = LocalCodingAgentLaunchSpec(
            kind: .codex,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            taskBrief: "noop",
            initialPrompt: ""
        )
        let env = spec.env()
        let nonWhitelistedParent = parent.keys.first { key in
            !LocalCodingAgentLaunchSpec.passthroughKeys.contains(key)
                && !key.hasPrefix("LC_")
                && !key.isEmpty
        }
        if let leak = nonWhitelistedParent {
            XCTAssertNil(env[leak],
                         "non-whitelisted parent env var '\(leak)' leaked into child env")
        }
    }

    // MARK: - argv

    func testArgvDiffersBetweenClaudeCodeAndCodex() {
        let claudeSpec = LocalCodingAgentLaunchSpec(
            kind: .claudeCode,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            taskBrief: "x",
            initialPrompt: "do thing"
        )
        let codexSpec = LocalCodingAgentLaunchSpec(
            kind: .codex,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            taskBrief: "x",
            initialPrompt: "do thing"
        )
        let claudeArgv = claudeSpec.argv()
        let codexArgv = codexSpec.argv()
        XCTAssertNotEqual(claudeArgv, codexArgv,
                          "Claude Code and Codex must have distinct argv shapes")
        XCTAssertTrue(claudeArgv.contains("--print"),
                      "Claude Code argv should include --print for non-interactive mode")
        XCTAssertTrue(codexArgv.contains("exec"),
                      "Codex argv should include 'exec' subcommand")
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

    // MARK: - launch error paths

    func testStartThrowsOnBogusExecutable() async {
        let spec = LocalCodingAgentLaunchSpec(
            kind: .codex,
            executableURL: URL(fileURLWithPath: "/nonexistent/binary/that/should/never/exist"),
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            taskBrief: "noop",
            initialPrompt: ""
        )
        let proc = LocalCodingAgentProcess(
            spec: spec,
            stdoutHandler: { _ in },
            stderrHandler: { _ in }
        )
        do {
            try await proc.start()
            XCTFail("start() should throw on bogus executable")
        } catch LocalCodingAgentProcess.LaunchError.executableNotExecutable {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStartThrowsOnMissingWorkingDirectory() async {
        let spec = LocalCodingAgentLaunchSpec(
            kind: .claudeCode,
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: URL(fileURLWithPath: "/nonexistent/dir/should/never/exist"),
            taskBrief: "noop",
            initialPrompt: ""
        )
        let proc = LocalCodingAgentProcess(
            spec: spec,
            stdoutHandler: { _ in },
            stderrHandler: { _ in }
        )
        do {
            try await proc.start()
            XCTFail("start() should throw on missing cwd")
        } catch LocalCodingAgentProcess.LaunchError.workingDirectoryMissing {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - cancel

    /// 写一个临时 shell 脚本作 victim：忽略 argv，挂在 `sleep 999`。
    /// LocalCodingAgentSpec.argv()（`--print` / `exec`）会被 sh 当 unknown arg 忽略 ——
    /// 因为脚本用 `exec sleep 999` 不传 $@ 进去。
    private func makeSleeperVictim(ignoreSigterm: Bool) throws -> URL {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let script = tmpDir.appendingPathComponent("crewtest-sleeper-\(UUID().uuidString).sh")
        let trapLine = ignoreSigterm ? "trap '' TERM\n" : ""
        let body = """
        #!/bin/sh
        \(trapLine)exec sleep 999
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func testCancelTerminatesSleepingProcessWithinGrace() async throws {
        let victim = try makeSleeperVictim(ignoreSigterm: false)
        defer { try? FileManager.default.removeItem(at: victim) }

        let spec = LocalCodingAgentLaunchSpec(
            kind: .codex,
            executableURL: victim,
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            taskBrief: "victim",
            initialPrompt: ""
        )
        let proc = LocalCodingAgentProcess(
            spec: spec,
            stdoutHandler: { _ in },
            stderrHandler: { _ in },
            gracePeriod: .seconds(5)  // 真实生产 grace；SIGTERM 立马应被 honor
        )
        try await proc.start()

        let started = Date()
        // 给 child 一点点时间真正 exec 进 sleep；要不然 SIGTERM 可能在 setup 阶段送
        try await Task.sleep(for: .milliseconds(200))

        // 并发：cancel + waitUntilExit
        async let exitCode = proc.waitUntilExit()
        await proc.cancel()
        let code = await exitCode
        let elapsed = Date().timeIntervalSince(started)

        // SIGTERM 被 honor 时 child 立即退；元数据上 exit code 通常是 143 (128 + SIGTERM)
        // 但 macOS 上 sleep 进程被 SIGTERM 杀，terminationStatus 反映 signal 编号。
        // 我们不卡死具体 code，只验证：在 grace 内退出（< 6s）。
        XCTAssertLessThan(elapsed, 6.0,
                          "cancel() should kill process within grace (got \(elapsed)s, code=\(code))")
    }

    func testCancelFallsBackToSigkillWhenSigtermIgnored() async throws {
        let victim = try makeSleeperVictim(ignoreSigterm: true)
        defer { try? FileManager.default.removeItem(at: victim) }

        let spec = LocalCodingAgentLaunchSpec(
            kind: .codex,
            executableURL: victim,
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            taskBrief: "stubborn-victim",
            initialPrompt: ""
        )
        // 缩短 grace 让测试不必等满 5s：用 1s grace，证 SIGKILL 在 1-2s 之间到达。
        let proc = LocalCodingAgentProcess(
            spec: spec,
            stdoutHandler: { _ in },
            stderrHandler: { _ in },
            gracePeriod: .seconds(1)
        )
        try await proc.start()
        try await Task.sleep(for: .milliseconds(300))

        let started = Date()
        async let exitCode = proc.waitUntilExit()
        await proc.cancel()
        _ = await exitCode
        let elapsed = Date().timeIntervalSince(started)

        // SIGTERM 被脚本 trap 忽略 → 1s grace 后 SIGKILL 必然送 → child 退出
        // 时间窗口：>= grace (1s) 因为要等 grace；<= grace + 几百 ms。
        XCTAssertGreaterThanOrEqual(elapsed, 0.9,
                                    "cancel should wait full grace before SIGKILL (got \(elapsed)s)")
        XCTAssertLessThan(elapsed, 3.0,
                          "SIGKILL should kill within grace + small slack (got \(elapsed)s)")
    }
}
#endif
