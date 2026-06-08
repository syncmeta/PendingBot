import XCTest

final class LocalApprovalStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("appr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testRaiseCreatesPending() {
        let s = LocalApprovalStore(directory: tempDir())
        let id = s.raise(crewId: "c", kind: "decision", sessionId: "sess", summary: "选 A 还是 B?")
        let it = s.item(crewId: "c", id: id)
        XCTAssertEqual(it?.status, "pending")
        XCTAssertEqual(it?.kind, "decision")
        XCTAssertEqual(it?.summary, "选 A 还是 B?")
        XCTAssertEqual(s.pending(crewId: "c").count, 1)
    }

    func testAnswerMarksAnsweredWithReply() {
        let s = LocalApprovalStore(directory: tempDir())
        let id = s.raise(crewId: "c", kind: "decision", sessionId: "sess", summary: "q")
        s.answer(crewId: "c", id: id, reply: "选 A")
        let it = s.item(crewId: "c", id: id)
        XCTAssertEqual(it?.status, "answered")
        XCTAssertEqual(it?.reply, "选 A")
        XCTAssertTrue(s.pending(crewId: "c").isEmpty)
    }

    func testDecideSetsAllowDeny() {
        let s = LocalApprovalStore(directory: tempDir())
        let id = s.raise(crewId: "c", kind: "permission", sessionId: "sess", summary: "允许 computer-use?")
        s.decide(crewId: "c", id: id, decision: "deny")
        XCTAssertEqual(s.item(crewId: "c", id: id)?.decision, "deny")
        XCTAssertEqual(s.item(crewId: "c", id: id)?.status, "answered")
    }

    func testPersistsAcrossInstances() {
        let dir = tempDir()
        let id = LocalApprovalStore(directory: dir).raise(crewId: "c", kind: "decision", sessionId: "s", summary: "q")
        XCTAssertEqual(LocalApprovalStore(directory: dir).item(crewId: "c", id: id)?.status, "pending")
    }

    func testCrewsIsolated() {
        let s = LocalApprovalStore(directory: tempDir())
        _ = s.raise(crewId: "a", kind: "decision", sessionId: "s", summary: "qa")
        _ = s.raise(crewId: "b", kind: "permission", sessionId: "s", summary: "qb")
        XCTAssertEqual(s.list(crewId: "a").count, 1)
        XCTAssertEqual(s.list(crewId: "b").count, 1)
        XCTAssertEqual(s.list(crewId: "a")[0].kind, "decision")
    }
}
