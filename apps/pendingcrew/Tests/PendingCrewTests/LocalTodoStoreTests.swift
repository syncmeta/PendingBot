import XCTest

/// LocalTodoStore（task #478）：人类 Todo 列表数据层。
final class LocalTodoStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("todo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testAddAssignsIncreasingNumbersAndPendingStatus() {
        let s = LocalTodoStore(directory: tempDir())
        let a = s.add(crewId: "c", text: "修复登录")
        let b = s.add(crewId: "c", text: "写文档")
        XCTAssertEqual(a.number, 1)
        XCTAssertEqual(b.number, 2)
        XCTAssertEqual(a.status, "pending")
        XCTAssertTrue(a.responses.isEmpty)
        XCTAssertEqual(s.list(crewId: "c").map(\.text), ["修复登录", "写文档"])
    }

    func testNumbersAreScopedPerCrew() {
        let s = LocalTodoStore(directory: tempDir())
        XCTAssertEqual(s.add(crewId: "c1", text: "a").number, 1)
        XCTAssertEqual(s.add(crewId: "c2", text: "b").number, 1)
        XCTAssertEqual(s.add(crewId: "c1", text: "c").number, 2)
    }

    func testRespondAppendsAndAdvancesStatus() {
        let s = LocalTodoStore(directory: tempDir())
        _ = s.add(crewId: "c", text: "修复登录")
        let r1 = s.respond(crewId: "c", number: 1, sessionId: "sess-1",
                           senderName: "机长", text: "收到，安排中", newStatus: "in_progress")
        XCTAssertEqual(r1?.status, "in_progress")
        XCTAssertEqual(r1?.responses.count, 1)
        XCTAssertEqual(r1?.responses[0].senderName, "机长")
        XCTAssertEqual(r1?.responses[0].status, "in_progress")
        // 追加式：第二条回应不覆盖第一条。
        let r2 = s.respond(crewId: "c", number: 1, sessionId: "sess-2",
                           text: "已修好并验证", newStatus: "completed")
        XCTAssertEqual(r2?.status, "completed")
        XCTAssertEqual(r2?.responses.map(\.text), ["收到，安排中", "已修好并验证"])
    }

    func testRespondWithoutStatusKeepsStatus() {
        let s = LocalTodoStore(directory: tempDir())
        _ = s.add(crewId: "c", text: "调研方案")
        let r = s.respond(crewId: "c", number: 1, sessionId: "sess-1", text: "看了一圈，明天给结论")
        XCTAssertEqual(r?.status, "pending")
        XCTAssertNil(r?.responses[0].status)
    }

    func testRespondUnknownNumberReturnsNil() {
        let s = LocalTodoStore(directory: tempDir())
        XCTAssertNil(s.respond(crewId: "c", number: 7, sessionId: "sess-1", text: "?"))
    }

    func testPersistsAcrossInstances() {
        let dir = tempDir()
        _ = LocalTodoStore(directory: dir).add(crewId: "c", text: "持久化")
        // 另一实例（模拟 helper 子进程）读同一目录、回应后 app 实例可见。
        _ = LocalTodoStore(directory: dir).respond(
            crewId: "c", number: 1, sessionId: "s", text: "ok", newStatus: "completed")
        let rows = LocalTodoStore(directory: dir).list(crewId: "c")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].status, "completed")
        XCTAssertEqual(rows[0].responses.count, 1)
    }
}
