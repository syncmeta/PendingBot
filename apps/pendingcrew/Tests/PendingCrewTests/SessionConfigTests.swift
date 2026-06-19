import XCTest


final class SessionConfigTests: XCTestCase {
    func testClaudeArgvUsesAutoModeNotBypass() {
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "do the thing")
        let argv = cfg.argv()
        XCTAssertFalse(argv.contains("--dangerously-skip-permissions"),
                       "claude must NOT bypass permissions (spec §9 auto mode)")
        XCTAssertEqual(argv, ["--permission-mode", "auto", "--", "do the thing"])
    }

    func testClaudeArgvPositionalPromptIsLast() {
        let cfg = SessionConfig(kind: .claudeCode, model: "opus", effort: "high",
                                initialPrompt: "fix bug")
        XCTAssertEqual(cfg.argv(),
                       ["--permission-mode", "auto", "--model", "opus", "--effort", "high", "--", "fix bug"])
    }

    func testClaudeArgvSeparatesPromptFromVariadicMcpConfig() {
        // Regression: --mcp-config is variadic; as the LAST flag (captain has no --model)
        // it swallows the positional prompt as a second config path unless `--` terminates
        // option parsing first. This was the "MCP config file not found: <cwd>/<prompt>" crash.
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "你是机长",
                                mcpConfigFile: "/tmp/m.json")
        let argv = cfg.argv()
        XCTAssertEqual(argv.last, "你是机长")
        let dash = argv.firstIndex(of: "--")!
        XCTAssertEqual(argv[dash + 1], "你是机长", "prompt must come right after the -- terminator")
        XCTAssertLessThan(argv.firstIndex(of: "--mcp-config")!, dash, "-- must come AFTER --mcp-config")
    }

    func testClaudeArgvOmitsEmptyOptionalsAndEmptyPrompt() {
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "")
        XCTAssertEqual(cfg.argv(), ["--permission-mode", "auto"])
    }

    func testClaudeArgvResumePrependsResumeFlag() {
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "go", resumeSessionId: "abc123")
        XCTAssertEqual(cfg.argv(),
                       ["--resume", "abc123", "--permission-mode", "auto", "--", "go"])
    }

    func testIsolationDoesNotLeakIntoArgv() {
        let isolated = SessionConfig(kind: .claudeCode, initialPrompt: "go", isolation: true)
        let shared = SessionConfig(kind: .claudeCode, initialPrompt: "go", isolation: false)
        XCTAssertEqual(isolated.argv(), shared.argv(), "isolation 是编排参数,不是 CLI flag")
        XCTAssertEqual(isolated.argv(), ["--permission-mode", "auto", "--", "go"])
    }

    func testCodexArgvIsAppServerWithEffortOverride() {
        let cfg = SessionConfig(kind: .codex, effort: "high", initialPrompt: "ship it")
        // codex launches app-server; effort is deterministic via -c on spawn (spec §5).
        // initialPrompt is NOT argv for codex — it's sent as the first turn after handshake.
        XCTAssertEqual(cfg.argv(), ["-c", "model_reasoning_effort=high", "app-server"])
    }

    func testCodexArgvAppServerNoEffort() {
        let cfg = SessionConfig(kind: .codex, initialPrompt: "go")
        XCTAssertEqual(cfg.argv(), ["app-server"])
    }

    func testClaudeArgvAppendsSystemPromptFile() {
        // 世界观注入：--append-system-prompt-file（append，不 replace；flag 已核实）。
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "go",
                                appendSystemPromptFile: "/tmp/world.md")
        XCTAssertEqual(cfg.argv(),
                       ["--permission-mode", "auto",
                        "--append-system-prompt-file", "/tmp/world.md", "--", "go"])
    }

    func testClaudeArgvOmitsEmptyAppendFile() {
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "go", appendSystemPromptFile: "")
        XCTAssertEqual(cfg.argv(), ["--permission-mode", "auto", "--", "go"])
    }

    func testCodexArgvIgnoresClaudeOnlyFlags() {
        let cfg = SessionConfig(kind: .codex, initialPrompt: "go",
                                appendSystemPromptFile: "/t/w.md",
                                settingsFile: "/t/s.json", mcpConfigFile: "/t/m.json")
        XCTAssertEqual(cfg.argv(), ["app-server"])
    }

    func testClaudeArgvSettingsAndMcpConfig() {
        // 本地 comms：--settings(hook 注入未读白板) + --mcp-config(post_to_crew/read)。
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "go",
                                settingsFile: "/t/s.json", mcpConfigFile: "/t/m.json")
        XCTAssertEqual(cfg.argv(),
                       ["--permission-mode", "auto",
                        "--settings", "/t/s.json", "--mcp-config", "/t/m.json", "--", "go"])
    }

    func testClaudeArgvAllLocalCommsFlagsOrder() {
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "go",
                                appendSystemPromptFile: "/t/w.md",
                                settingsFile: "/t/s.json", mcpConfigFile: "/t/m.json")
        XCTAssertEqual(cfg.argv(),
                       ["--permission-mode", "auto",
                        "--append-system-prompt-file", "/t/w.md",
                        "--settings", "/t/s.json", "--mcp-config", "/t/m.json", "--", "go"])
    }

}
