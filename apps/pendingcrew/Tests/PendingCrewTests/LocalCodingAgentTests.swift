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
        // `exec` 必须是首个参数（子命令位置敏感），后接 JSONL 事件流 flag。
        XCTAssertEqual(codexArgv.first, "exec",
                       "Codex argv must lead with the 'exec' subcommand")
        XCTAssertTrue(codexArgv.contains("--json"),
                      "Codex argv should include --json for a parseable JSONL event stream")
    }

    func testModelFlagThreadsIntoBothRunners() {
        func argv(for kind: LocalCodingAgentKind, model: String?) -> [String] {
            LocalCodingAgentLaunchSpec(
                kind: kind,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                taskBrief: "x",
                initialPrompt: "do thing",
                model: model
            ).argv()
        }

        // model set → `--model <slug>` appears for both runners.
        let claudeWith = argv(for: .claudeCode, model: "claude-sonnet-4")
        let codexWith = argv(for: .codex, model: "gpt-5-codex")
        for (kind, args, slug) in [("claude", claudeWith, "claude-sonnet-4"),
                                   ("codex", codexWith, "gpt-5-codex")] {
            guard let i = args.firstIndex(of: "--model") else {
                XCTFail("\(kind) argv missing --model when a model slug is set")
                continue
            }
            XCTAssertTrue(i + 1 < args.count && args[i + 1] == slug,
                          "\(kind) --model must be immediately followed by the slug")
        }

        // model nil → no `--model` flag for either runner.
        XCTAssertFalse(argv(for: .claudeCode, model: nil).contains("--model"),
                       "Claude argv must omit --model when no slug is set")
        XCTAssertFalse(argv(for: .codex, model: nil).contains("--model"),
                       "Codex argv must omit --model when no slug is set")
        // empty string is treated like nil (no flag).
        XCTAssertFalse(argv(for: .codex, model: "").contains("--model"),
                       "Codex argv must omit --model for an empty slug")
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

    // MARK: - service integration smoke

    /// 端到端验证 `MacLocalCodingAgentService.runSession()` 的 stdout 流 +
    /// exitCode Task。
    ///
    /// 用一个临时 bash 脚本当 "executable"，spec 的 argv flags（--print 等）
    /// 对 bash 来说是无害的位置参数 —— bash 会忽略 unknown flags 因为没 `-`
    /// 开头的脚本路径作为第一个参数。这里直接用 inline `bash -c <script>` 太
    /// 麻烦，写一个真正的 shebang 脚本到 tmp 让它跑。
    func testServiceRunSessionStreamsStdoutAndExits() async throws {
        // 写一个 victim 脚本：打印三行，然后 exit 0。
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingcrew-test-runner-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        # 忽略 spec 传进来的 argv (--print / --output-format=...)；
        # 我们关心的是 stdout 行流确实能传出去。
        echo "line one"
        echo "line two"
        echo "line three"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let spec = LocalCodingAgentLaunchSpec(
            kind: .claudeCode,
            executableURL: scriptURL,
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            taskBrief: "smoke",
            initialPrompt: ""
        )
        let service = MacLocalCodingAgentService()
        let runID = UUID()
        let handle = try await service.runSession(runID: runID, spec: spec)
        XCTAssertEqual(handle.runID, runID)

        // 读 stdout 全部行，并发等 exitCode。
        var lines: [String] = []
        for await line in handle.stdout {
            lines.append(line)
        }
        let exit = await handle.exitCode.value
        XCTAssertEqual(exit, 0, "victim script exits 0")
        XCTAssertEqual(lines, ["line one", "line two", "line three"])
    }

    /// 验 cancel 通过 handle 走 SIGTERM。Sleep 子进程被取消后退出码非 0。
    func testServiceRunSessionCancelKillsSleep() async throws {
        // sleep 100 — 直接用 /bin/sleep 作 executable，argv 含 --print 这种
        // claude flag 也无所谓（sleep 会拒绝并直接退出，所以改用一个 wrapper
        // 脚本）。
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingcrew-test-sleep-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        # 忽略所有参数，进入长 sleep；cancel 应在 grace 内打死。
        exec sleep 30
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let spec = LocalCodingAgentLaunchSpec(
            kind: .codex,
            executableURL: scriptURL,
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            taskBrief: "cancel-test",
            initialPrompt: ""
        )
        let service = MacLocalCodingAgentService()
        let handle = try await service.runSession(runID: UUID(), spec: spec)

        // 让子进程跑起来再 cancel。
        try await Task.sleep(nanoseconds: 200_000_000)
        let start = Date()
        await handle.cancel()
        let code = await handle.exitCode.value
        let elapsed = Date().timeIntervalSince(start)
        // SIGTERM 后 bash 应在毫秒级退出；grace 是 5s 上限。
        XCTAssertLessThan(elapsed, 6.5, "cancel should resolve within grace + slack")
        XCTAssertNotEqual(code, 0, "cancelled process should not exit 0")
    }
}
#endif
