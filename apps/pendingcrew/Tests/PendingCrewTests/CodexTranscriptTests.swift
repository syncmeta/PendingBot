import XCTest
@testable import PendingCrew

@MainActor
final class CodexTranscriptTests: XCTestCase {
    func testItemCompletedAppendsThenUpsertsById() {
        let t = CodexTranscript()
        t.apply(method: "item/completed", params: ["item": ["id": "i1", "type": "agentMessage", "text": "hi"]])
        XCTAssertEqual(t.items.count, 1)
        t.apply(method: "item/completed", params: ["item": ["id": "i1", "type": "agentMessage", "text": "hi (final)"]])
        XCTAssertEqual(t.items.count, 1)   // upsert, not duplicate
        guard case let .agentMessage(text, _) = t.items[0].kind else { return XCTFail() }
        XCTAssertEqual(text, "hi (final)")
    }
    func testTwoDistinctItemsBothAppend() {
        let t = CodexTranscript()
        t.apply(method: "item/completed", params: ["item": ["id": "a", "type": "agentMessage", "text": "1"]])
        t.apply(method: "item/completed", params: ["item": ["id": "b", "type": "agentMessage", "text": "2"]])
        XCTAssertEqual(t.items.count, 2)
    }
    func testTurnLifecycleTogglesActive() {
        let t = CodexTranscript()
        t.apply(method: "turn/started", params: ["turn": ["id": "t1"]])
        XCTAssertTrue(t.turnActive); XCTAssertEqual(t.activeTurnId, "t1")
        t.apply(method: "turn/completed", params: ["turn": ["id": "t1"], "status": "completed"])
        XCTAssertFalse(t.turnActive); XCTAssertNil(t.activeTurnId)
    }
    func testIgnoredMethodsAreNoops() {
        let t = CodexTranscript()
        t.apply(method: "item/started", params: ["item": ["id": "x", "type": "agentMessage"]])
        t.apply(method: "item/agentMessage/delta", params: [:])
        t.apply(method: "thread/tokenUsage/updated", params: [:])
        XCTAssertEqual(t.items.count, 0)
        XCTAssertFalse(t.turnActive)
    }
    func testMalformedItemIsSkippedNotCrash() {
        let t = CodexTranscript()
        t.apply(method: "item/completed", params: [:])              // no "item"
        t.apply(method: "item/completed", params: ["item": "nope"]) // wrong type
        XCTAssertEqual(t.items.count, 0)
    }
}
