import XCTest
// McpServer.swift + LocalWhiteboardStore.swift + LocalApprovalStore.swift 编进 test
// bundle（见 project.yml）；main / McpHelperMain 顶层不进 bundle。

final class McpServerTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func server(_ dir: URL) -> McpServer {
        McpServer(store: LocalWhiteboardStore(directory: dir),
                  approvals: LocalApprovalStore(directory: dir),
                  crewId: "c", sessionId: "sess-1")
    }

    func testInitializeReturnsCapabilities() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.contains("\"protocolVersion\""))
        XCTAssertTrue(r!.contains("pendingcrew"))
    }

    func testToolsListHasPostReadAsk() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        XCTAssertTrue(r.contains("post_to_crew"))
        XCTAssertTrue(r.contains("read_whiteboard"))
        XCTAssertTrue(r.contains("\"ask\""))
    }

    func testPostToCrewWritesWhiteboard() {
        let s = server(tempDir())
        _ = s.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"post_to_crew","arguments":{"message":"hi crew","category":"progress"}}}"#)
        let msgs = s.store.list(crewId: "c")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].text, "hi crew")
        XCTAssertEqual(msgs[0].senderKind, "session")
        XCTAssertEqual(msgs[0].senderSessionId, "sess-1")
        XCTAssertEqual(msgs[0].category, "progress")
    }

    func testPostToCrewEmptyMessageRejected() {
        let s = server(tempDir())
        let r = s.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"post_to_crew","arguments":{"message":"   "}}}"#)!
        XCTAssertTrue(r.contains("ERROR"))
        XCTAssertTrue(s.store.list(crewId: "c").isEmpty)
    }

    func testReadWhiteboardReturnsEntries() {
        let s = server(tempDir())
        s.store.appendUserMessage(crewId: "c", text: "人类说嗨")
        let r = s.handleLine(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_whiteboard","arguments":{}}}"#)!
        XCTAssertTrue(r.contains("人类说嗨"))
    }

    func testUnknownToolReturnsError() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#)!
        XCTAssertTrue(r.contains("ERROR"))
    }

    func testNotificationInitializedNoResponse() {
        XCTAssertNil(server(tempDir()).handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testUnknownMethodWithIdReturnsError() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":9,"method":"bogus/method"}"#)!
        XCTAssertTrue(r.contains("-32601"))
    }

    func testGarbageLineReturnsNil() {
        XCTAssertNil(server(tempDir()).handleLine("not json"))
        XCTAssertNil(server(tempDir()).handleLine(""))
    }

    // MARK: - ask（待决策 raise + long-poll 答复）

    func testAskEmptyQuestionRejected() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ask","arguments":{"question":"  "}}}"#)!
        XCTAssertTrue(r.contains("ERROR"))
    }

    func testAwaitReplyReturnsAnswerOnFirstPoll() {
        let s = server(tempDir())
        let id = s.approvals.raise(crewId: "c", kind: "decision", sessionId: "sess-1", summary: "q")
        s.approvals.answer(crewId: "c", id: id, reply: "选 A")
        XCTAssertEqual(s.awaitReply(reqId: id, pollInterval: 0.01), "选 A")
    }

    func testAwaitReplyTimeoutText() {
        let s = server(tempDir())
        let id = s.approvals.raise(crewId: "c", kind: "decision", sessionId: "sess-1", summary: "q")
        XCTAssertTrue(s.awaitReply(reqId: id, pollInterval: 0.01, maxWaits: 2).contains("自行判断"))
    }
}
