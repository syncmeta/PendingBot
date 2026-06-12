import XCTest
@testable import PendingCrew

final class SessionConfigTests: XCTestCase {
    func testClaudeArgvUsesAutoModeNotBypass() {
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "do the thing")
        let argv = cfg.argv()
        XCTAssertFalse(argv.contains("--dangerously-skip-permissions"),
                       "claude must NOT bypass permissions (spec §9 auto mode)")
        XCTAssertEqual(argv, ["--permission-mode", "auto", "do the thing"])
    }

    func testClaudeArgvPositionalPromptIsLast() {
        let cfg = SessionConfig(kind: .claudeCode, model: "opus", effort: "high",
                                initialPrompt: "fix bug")
        XCTAssertEqual(cfg.argv(),
                       ["--permission-mode", "auto", "--model", "opus", "--effort", "high", "fix bug"])
    }

    func testClaudeArgvOmitsEmptyOptionalsAndEmptyPrompt() {
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "")
        XCTAssertEqual(cfg.argv(), ["--permission-mode", "auto"])
    }

    func testClaudeArgvResumePrependsResumeFlag() {
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "go", resumeSessionId: "abc123")
        XCTAssertEqual(cfg.argv(),
                       ["--resume", "abc123", "--permission-mode", "auto", "go"])
    }

    func testIsolationDoesNotLeakIntoArgv() {
        let isolated = SessionConfig(kind: .claudeCode, initialPrompt: "go", isolation: true)
        let shared = SessionConfig(kind: .claudeCode, initialPrompt: "go", isolation: false)
        XCTAssertEqual(isolated.argv(), shared.argv(), "isolation 是编排参数,不是 CLI flag")
        XCTAssertEqual(isolated.argv(), ["--permission-mode", "auto", "go"])
    }

    func testCodexArgvUnchangedPlaceholder() {
        // codex PTY argv is a placeholder until the app-server plan; keep sandbox, carry prompt.
        let cfg = SessionConfig(kind: .codex, model: "gpt-5.5", initialPrompt: "ship it")
        XCTAssertEqual(cfg.argv(),
                       ["--sandbox", "workspace-write", "--model", "gpt-5.5", "ship it"])
    }

    func testClaudeArgvAppendsSystemPromptFile() {
        // 世界观注入：--append-system-prompt-file（append，不 replace；flag 已核实）。
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "go",
                                appendSystemPromptFile: "/tmp/world.md")
        XCTAssertEqual(cfg.argv(),
                       ["--permission-mode", "auto",
                        "--append-system-prompt-file", "/tmp/world.md", "go"])
    }

    func testClaudeArgvOmitsEmptyAppendFile() {
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "go", appendSystemPromptFile: "")
        XCTAssertEqual(cfg.argv(), ["--permission-mode", "auto", "go"])
    }

    func testCodexIgnoresAppendSystemPromptFile() {
        // codex 不接 --append-system-prompt-file（世界观走 app-server additionalContext）。
        let cfg = SessionConfig(kind: .codex, initialPrompt: "go", appendSystemPromptFile: "/tmp/w.md")
        XCTAssertEqual(cfg.argv(), ["--sandbox", "workspace-write", "go"])
    }

    func testClaudeArgvSettingsAndMcpConfig() {
        // 本地 comms：--settings(hook 注入未读白板) + --mcp-config(post_to_crew/read)。
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "go",
                                settingsFile: "/t/s.json", mcpConfigFile: "/t/m.json")
        XCTAssertEqual(cfg.argv(),
                       ["--permission-mode", "auto",
                        "--settings", "/t/s.json", "--mcp-config", "/t/m.json", "go"])
    }

    func testClaudeArgvAllLocalCommsFlagsOrder() {
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "go",
                                appendSystemPromptFile: "/t/w.md",
                                settingsFile: "/t/s.json", mcpConfigFile: "/t/m.json")
        XCTAssertEqual(cfg.argv(),
                       ["--permission-mode", "auto",
                        "--append-system-prompt-file", "/t/w.md",
                        "--settings", "/t/s.json", "--mcp-config", "/t/m.json", "go"])
    }

    func testCodexIgnoresSettingsAndMcpConfig() {
        let cfg = SessionConfig(kind: .codex, initialPrompt: "go",
                                settingsFile: "/t/s.json", mcpConfigFile: "/t/m.json")
        XCTAssertEqual(cfg.argv(), ["--sandbox", "workspace-write", "go"])
    }
}
