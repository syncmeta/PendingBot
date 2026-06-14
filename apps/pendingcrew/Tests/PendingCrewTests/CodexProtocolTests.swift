import XCTest
@testable import PendingCrew

final class CodexProtocolTests: XCTestCase {
    func testInitializeParamsCarryClientInfoAndExperimentalApi() {
        let p = CodexProtocol.initializeParams(clientName: "PendingCrew", version: "1.0")
        let info = p["clientInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "PendingCrew")
        XCTAssertEqual(info?["version"] as? String, "1.0")
        let caps = p["capabilities"] as? [String: Any]
        XCTAssertEqual(caps?["experimentalApi"] as? Bool, true)
        XCTAssertNotNil(caps?["optOutNotificationMethods"], "v1 should opt out of streaming deltas")
    }
    func testThreadStartCarriesCwdDevInstructionsApprovalPolicyMcp() {
        let p = CodexProtocol.threadStartParams(cwd: "/repo", model: "gpt-5.5",
            developerInstructions: "world-model",
            mcpServers: ["crew": ["command": "/bin/helper", "args": ["--mcp-serve"]]])
        XCTAssertEqual(p["cwd"] as? String, "/repo")
        XCTAssertEqual(p["model"] as? String, "gpt-5.5")
        XCTAssertEqual(p["developerInstructions"] as? String, "world-model")
        XCTAssertEqual(p["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(p["sandbox"] as? String, "workspace-write")
        XCTAssertEqual(p["approvalsReviewer"] as? String, "user")
        XCTAssertNotNil(p["mcpServers"])
    }
    func testThreadStartOmitsEmptyOptionals() {
        let p = CodexProtocol.threadStartParams(cwd: "/repo", model: nil, developerInstructions: "", mcpServers: nil)
        XCTAssertNil(p["model"]); XCTAssertNil(p["developerInstructions"]); XCTAssertNil(p["mcpServers"])
        XCTAssertEqual(p["approvalPolicy"] as? String, "on-request")   // policy always present
    }
    func testTurnStartWrapsTextAndUntrustedWhiteboard() {
        let p = CodexProtocol.turnStartParams(threadId: "thr_1", text: "go", whiteboard: "unread:1")
        XCTAssertEqual(p["threadId"] as? String, "thr_1")
        let input = p["input"] as? [[String: Any]]
        XCTAssertEqual(input?.first?["type"] as? String, "text")
        XCTAssertEqual(input?.first?["text"] as? String, "go")
        let wb = (p["additionalContext"] as? [String: Any])?["whiteboard"] as? [String: Any]
        XCTAssertEqual(wb?["kind"] as? String, "untrusted")
        XCTAssertEqual(wb?["value"] as? String, "unread:1")
    }
    func testTurnStartOmitsWhiteboardWhenNilOrEmpty() {
        XCTAssertNil(CodexProtocol.turnStartParams(threadId: "t", text: "go", whiteboard: nil)["additionalContext"])
        XCTAssertNil(CodexProtocol.turnStartParams(threadId: "t", text: "go", whiteboard: "")["additionalContext"])
    }
    func testTurnInterruptParams() {
        let p = CodexProtocol.turnInterruptParams(threadId: "thr_1", turnId: "turn_9")
        XCTAssertEqual(p["threadId"] as? String, "thr_1")
        XCTAssertEqual(p["turnId"] as? String, "turn_9")
    }
}
