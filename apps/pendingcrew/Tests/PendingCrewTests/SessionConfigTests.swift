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
}
