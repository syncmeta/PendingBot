#if os(macOS)
import XCTest
// LocalRunner 源码直接编进 PendingCrewTests target（见 project.yml），
// 所以 RunnerEventParser / RunnerEvent 在当前 module 直接可见，无需 import。

/// Parser tests run against **real-schema fixtures** captured from
/// `claude --output-format=stream-json` (claude-cli) and `codex exec --json`
/// (codex-cli 0.133.0). Fixtures live next to this file and are loaded via
/// `#filePath` so there's no test-bundle resource plumbing.
final class RunnerEventParserTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Claude Code stream-json

    func testClaudeStreamParsesToOrderedTranscript() throws {
        let events = RunnerEventParser.parse(
            stream: try fixture("claude_stream.jsonl"), kind: .claudeCode)

        // hook_started / rate_limit_event / post_turn_summary are dropped;
        // init → started, the rest flatten in stream order.
        XCTAssertEqual(events, [
            .started(model: "claude-sonnet-4-6", sessionId: "sess-abc"),
            .reasoning("I should list the files first."),
            .assistant("Let me check the directory."),
            .toolCall(title: "Bash", detail: "ls -la"),
            .toolResult(text: "total 0\ndrwxr-xr-x  2 user staff 64 file.txt", isError: false),
            .toolCall(title: "Read", detail: "/tmp/work/missing.txt"),
            .toolResult(text: "Error: file not found", isError: true),
            .assistant("Done — there is one file."),
            .finished(summary: "Done — there is one file.", isError: false, costUSD: 0.0393),
        ])
    }

    func testClaudeMultiBlockAssistantYieldsTextThenToolCall() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"},{"type":"tool_use","name":"Edit","input":{"file_path":"/a/b.swift"}}]}}"#
        XCTAssertEqual(RunnerEventParser.parse(line: line, kind: .claudeCode), [
            .assistant("hi"),
            .toolCall(title: "Edit", detail: "/a/b.swift"),
        ])
    }

    func testClaudeNoiseLinesDropToEmpty() {
        for line in [
            #"{"type":"system","subtype":"hook_response","output":"x"}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#,
            #"{"type":"system","subtype":"post_turn_summary"}"#,
        ] {
            XCTAssertEqual(RunnerEventParser.parse(line: line, kind: .claudeCode), [],
                           "noise line should drop to []: \(line)")
        }
    }

    // MARK: - Codex exec --json

    func testCodexStreamParsesToOrderedTranscript() throws {
        let events = RunnerEventParser.parse(
            stream: try fixture("codex_stream.jsonl"), kind: .codex)

        // turn.started + item.started are dropped; item.completed flattens.
        XCTAssertEqual(events, [
            .started(model: nil, sessionId: "019e868e-3f01-7ef1-844a-f79644379e6e"),
            .reasoning("The user wants me to inspect the repo."),
            .toolCall(title: "shell", detail: "ls -la"),
            .toolCall(title: "edit", detail: "src/main.rs"),
            .toolCall(title: "github/create_issue", detail: nil),
            .assistant("All done — one file present."),
            .finished(summary: nil, isError: false, costUSD: nil),
        ])
    }

    func testCodexErrorAndTurnFailedSurfaceAsFailed() {
        let err = #"{"type":"error","message":"token revoked"}"#
        XCTAssertEqual(RunnerEventParser.parse(line: err, kind: .codex), [.failed("token revoked")])

        let turnFailed = #"{"type":"turn.failed","error":{"message":"refresh failed"}}"#
        XCTAssertEqual(RunnerEventParser.parse(line: turnFailed, kind: .codex), [.failed("refresh failed")])
    }

    // MARK: - robustness

    func testNonJsonLineDegradesToUnknownNotCrash() {
        let raw = "warning: something printed to stdout"
        XCTAssertEqual(RunnerEventParser.parse(line: raw, kind: .codex), [.unknown(raw)])
        XCTAssertEqual(RunnerEventParser.parse(line: raw, kind: .claudeCode), [.unknown(raw)])
    }

    func testUnknownJsonTypeSurfacesAsUnknown() {
        let raw = #"{"type":"some_future_event","data":1}"#
        XCTAssertEqual(RunnerEventParser.parse(line: raw, kind: .codex), [.unknown(raw)])
        XCTAssertEqual(RunnerEventParser.parse(line: raw, kind: .claudeCode), [.unknown(raw)])
    }

    func testEmptyLineIsIgnored() {
        XCTAssertEqual(RunnerEventParser.parse(line: "   ", kind: .codex), [])
        XCTAssertEqual(RunnerEventParser.parse(line: "", kind: .claudeCode), [])
    }

    func testToolInputFallsBackToSortedCompactSummary() {
        // No preferred key (command/file_path/…) → deterministic sorted render.
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"glob":"*.swift","output_mode":"files"}}]}}"#
        XCTAssertEqual(RunnerEventParser.parse(line: line, kind: .claudeCode),
                       [.toolCall(title: "Grep", detail: "glob=*.swift output_mode=files")])
    }
}
#endif
