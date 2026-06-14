import XCTest
@testable import PendingCrew

final class CodexThreadItemTests: XCTestCase {
    private func decode(_ json: String) throws -> CodexThreadItem {
        try JSONDecoder().decode(CodexThreadItem.self, from: Data(json.utf8))
    }

    func testDecodeAgentMessage() throws {
        let item = try decode(#"{"id":"item_1","type":"agentMessage","text":"Done.","phase":"final"}"#)
        guard case let .agentMessage(text, phase) = item.kind else { return XCTFail("expected agentMessage") }
        XCTAssertEqual(text, "Done.")
        XCTAssertEqual(phase, "final")
        XCTAssertEqual(item.id, "item_1")
    }

    func testDecodeCommandExecution() throws {
        let item = try decode(#"{"id":"item_2","type":"commandExecution","command":"ls -la","cwd":"/repo","status":"completed","aggregatedOutput":"a\nb","exitCode":0}"#)
        guard case let .commandExecution(c) = item.kind else { return XCTFail("expected commandExecution") }
        XCTAssertEqual(c.command, "ls -la")
        XCTAssertEqual(c.exitCode, 0)
        XCTAssertEqual(c.status, "completed")
    }

    func testDecodeReasoning() throws {
        let item = try decode(#"{"id":"r1","type":"reasoning","summary":"plan","content":"thinking..."}"#)
        guard case let .reasoning(summary, content) = item.kind else { return XCTFail("expected reasoning") }
        XCTAssertEqual(summary, "plan")
        XCTAssertEqual(content, "thinking...")
    }

    func testToolCallVariantsFold() throws {
        let item = try decode(#"{"id":"t1","type":"mcpToolCall","name":"post_to_crew","status":"completed"}"#)
        guard case let .toolCall(name, status) = item.kind else { return XCTFail("expected toolCall") }
        XCTAssertEqual(name, "post_to_crew")
        XCTAssertEqual(status, "completed")
    }

    func testUnknownArmDegradesNotCrashes() throws {
        let item = try decode(#"{"id":"item_9","type":"someFutureType","blob":42}"#)
        guard case let .unknown(type) = item.kind else { return XCTFail("expected unknown") }
        XCTAssertEqual(type, "someFutureType")
        XCTAssertEqual(item.id, "item_9")
    }

    func testMissingIdGetsSyntheticIdNotCrash() throws {
        let item = try decode(#"{"type":"agentMessage","text":"hi"}"#)
        XCTAssertFalse(item.id.isEmpty)   // synthesized, decode must not throw
    }

    // Additional coverage

    func testDecodeUserMessage() throws {
        let item = try decode(#"{"id":"u1","type":"userMessage","text":"Hello!"}"#)
        guard case let .userMessage(text) = item.kind else { return XCTFail("expected userMessage") }
        XCTAssertEqual(text, "Hello!")
    }

    func testDecodePlan() throws {
        let item = try decode(#"{"id":"p1","type":"plan","text":"Step 1: do X"}"#)
        guard case let .plan(text) = item.kind else { return XCTFail("expected plan") }
        XCTAssertEqual(text, "Step 1: do X")
    }

    func testDecodeFileChange() throws {
        let item = try decode(#"{"id":"f1","type":"fileChange","status":"modified","summary":"Updated README"}"#)
        guard case let .fileChange(fc) = item.kind else { return XCTFail("expected fileChange") }
        XCTAssertEqual(fc.status, "modified")
        XCTAssertEqual(fc.summary, "Updated README")
    }

    func testDecodeWebSearch() throws {
        let item = try decode(#"{"id":"w1","type":"webSearch","query":"swift codable"}"#)
        guard case let .webSearch(query) = item.kind else { return XCTFail("expected webSearch") }
        XCTAssertEqual(query, "swift codable")
    }

    func testDynamicToolCallFolds() throws {
        let item = try decode(#"{"id":"d1","type":"dynamicToolCall","name":"run_script","status":"running"}"#)
        guard case let .toolCall(name, status) = item.kind else { return XCTFail("expected toolCall") }
        XCTAssertEqual(name, "run_script")
        XCTAssertEqual(status, "running")
    }

    func testCollabAgentToolCallFolds() throws {
        let item = try decode(#"{"id":"ca1","type":"collabAgentToolCall","name":"delegate_task","status":"pending"}"#)
        guard case let .toolCall(name, status) = item.kind else { return XCTFail("expected toolCall") }
        XCTAssertEqual(name, "delegate_task")
        XCTAssertEqual(status, "pending")
    }

    func testAgentMessageMissingPhaseIsNil() throws {
        let item = try decode(#"{"id":"a2","type":"agentMessage","text":"Working..."}"#)
        guard case let .agentMessage(text, phase) = item.kind else { return XCTFail("expected agentMessage") }
        XCTAssertEqual(text, "Working...")
        XCTAssertNil(phase)
    }

    func testCommandExecutionMissingExitCodeIsNil() throws {
        let item = try decode(#"{"id":"cmd1","type":"commandExecution","command":"echo hi"}"#)
        guard case let .commandExecution(c) = item.kind else { return XCTFail("expected commandExecution") }
        XCTAssertEqual(c.command, "echo hi")
        XCTAssertNil(c.exitCode)
    }
}
