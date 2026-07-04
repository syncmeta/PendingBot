import XCTest
// SessionHealth + CodexProtocol 直接编进 PendingCrewTests target，无需 import。

/// runner 健康感知单测（批 C，分诊第 7 点）：
/// PTY 文案扫描（去 ANSI / 跨 chunk / 每 Kind 一次）+ codex account 事件分类。
final class SessionHealthTests: XCTestCase {

    private func feed(_ scanner: SessionHealthScanner, _ s: String) -> [CrewSessionHealth] {
        let bytes = Array(s.utf8)
        return scanner.feed(bytes[...])
    }

    // MARK: - 基本命中

    func testAuthPhraseFiresAuthRequiredOnce() {
        let sc = SessionHealthScanner()
        let hits = feed(sc, "Error: Not logged in. Run claude auth login to authenticate.\n")
        XCTAssertEqual(hits.map(\.kind), [.authRequired])
        // 同一故障 TUI 反复重绘 → 不再重复报。
        XCTAssertTrue(feed(sc, "Not logged in\n").isEmpty)
    }

    func testQuotaPhraseFiresUsageLimit() {
        let sc = SessionHealthScanner()
        let hits = feed(sc, "You've reached your Fable usage limit · resets 3pm\n")
        XCTAssertEqual(hits.map(\.kind), [.usageLimit])
    }

    func testRunLoginVariantsMatch() {
        for line in ["Please run /login to sign in.", "Run /login and retry."] {
            let sc = SessionHealthScanner()
            XCTAssertEqual(feed(sc, line).map(\.kind), [.authRequired], line)
        }
    }

    // MARK: - ANSI / 控制序列剥除

    func testAnsiSgrInsidePhraseIsStripped() {
        let sc = SessionHealthScanner()
        // 短语中间插 SGR 颜色码：run \e[1m/login\e[0m
        let hits = feed(sc, "Please run \u{1b}[1m/login\u{1b}[0m to authenticate")
        XCTAssertEqual(hits.map(\.kind), [.authRequired])
    }

    func testOscTitleSequenceIsStripped() {
        let sc = SessionHealthScanner()
        // OSC 设窗口标题（BEL 结尾）里出现的短语**不该**算命中——它被整段剥掉。
        XCTAssertTrue(feed(sc, "\u{1b}]0;run /login\u{07}normal output").isEmpty)
        // 但正文里的照常命中。
        XCTAssertEqual(feed(sc, "please run /login now").map(\.kind), [.authRequired])
    }

    // MARK: - 跨 chunk 拼接

    func testPhraseSplitAcrossChunksStillMatches() {
        let sc = SessionHealthScanner()
        XCTAssertTrue(feed(sc, "You've reached yo").isEmpty)
        XCTAssertEqual(feed(sc, "ur usage limit").map(\.kind), [.usageLimit])
    }

    // MARK: - 双 Kind / 无命中

    func testBothKindsInOneChunkFireBoth() {
        let sc = SessionHealthScanner()
        let hits = feed(sc, "Invalid API key\nCredit balance is too low\n")
        XCTAssertEqual(Set(hits.map(\.kind)), [.authRequired, .usageLimit])
    }

    func testOrdinaryOutputNoFalsePositive() {
        let sc = SessionHealthScanner()
        let hits = feed(sc, "Running tests… 263 passed.\n$ git status\nnothing to commit\n")
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - codex account 事件分类

    func testCodexAccountRequestClassifiedAsAccount() {
        XCTAssertEqual(
            CodexProtocol.serverRequestKind(method: "account/chatgptAuthTokens/refresh"),
            .account)
        // 原有分类不受影响。
        XCTAssertEqual(CodexProtocol.serverRequestKind(method: "item/commandExecution/requestApproval"),
                       .approval)
        XCTAssertEqual(CodexProtocol.serverRequestKind(method: "attestation/generate"),
                       .unsupported)
    }
}
