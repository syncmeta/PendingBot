import XCTest
// McpServer.swift + LocalWhiteboardStore.swift 编进 test bundle（见 project.yml）；
// main.swift 不编（顶层代码不进 bundle）。

final class McpServerTests: XCTestCase {
    private func tempStore() -> LocalWhiteboardStore {
        LocalWhiteboardStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-\(UUID().uuidString)"))
    }
    private func server(_ store: LocalWhiteboardStore) -> McpServer {
        McpServer(store: store, crewId: "c", sessionId: "sess-1")
    }

    func testInitializeReturnsCapabilities() {
        let r = server(tempStore()).handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.contains("\"protocolVersion\""))
        XCTAssertTrue(r!.contains("pendingcrew"))
    }

    func testToolsListHasPostAndRead() {
        let r = server(tempStore()).handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        XCTAssertTrue(r.contains("post_to_crew"))
        XCTAssertTrue(r.contains("read_whiteboard"))
    }

    func testPostToCrewWritesWhiteboard() {
        let store = tempStore()
        let r = server(store).handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"post_to_crew","arguments":{"message":"hi crew","category":"progress"}}}"#)
        XCTAssertNotNil(r)
        let msgs = store.list(crewId: "c")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].text, "hi crew")
        XCTAssertEqual(msgs[0].senderKind, "session")
        XCTAssertEqual(msgs[0].senderSessionId, "sess-1")
        XCTAssertEqual(msgs[0].category, "progress")
    }

    func testPostToCrewEmptyMessageRejected() {
        let store = tempStore()
        let r = server(store).handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"post_to_crew","arguments":{"message":"   "}}}"#)!
        XCTAssertTrue(r.contains("ERROR"))
        XCTAssertTrue(store.list(crewId: "c").isEmpty)
    }

    func testReadWhiteboardReturnsEntries() {
        let store = tempStore()
        store.appendUserMessage(crewId: "c", text: "人类说嗨")
        let r = server(store).handleLine(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_whiteboard","arguments":{}}}"#)!
        XCTAssertTrue(r.contains("人类说嗨"))
    }

    func testUnknownToolReturnsError() {
        let r = server(tempStore()).handleLine(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#)!
        XCTAssertTrue(r.contains("ERROR"))
    }

    func testNotificationInitializedNoResponse() {
        XCTAssertNil(server(tempStore()).handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testUnknownMethodWithIdReturnsError() {
        let r = server(tempStore()).handleLine(#"{"jsonrpc":"2.0","id":9,"method":"bogus/method"}"#)!
        XCTAssertTrue(r.contains("-32601"))
    }

    func testGarbageLineReturnsNil() {
        XCTAssertNil(server(tempStore()).handleLine("not json"))
        XCTAssertNil(server(tempStore()).handleLine(""))
    }
}
