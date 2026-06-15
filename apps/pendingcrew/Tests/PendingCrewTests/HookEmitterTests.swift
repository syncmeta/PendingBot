import XCTest
// HookEmitter.swift + LocalWhiteboardStore.swift 编进 test bundle（见 project.yml）。

final class HookEmitterTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func emitter(_ store: LocalWhiteboardStore, _ dir: URL, session: String = "s") -> HookEmitter {
        HookEmitter(store: store, crewId: "c", sessionId: session, cursorDir: dir)
    }

    func testEmitsUnreadAsAdditionalContext() {
        let dir = tempDir()
        let store = LocalWhiteboardStore(directory: dir)
        store.appendUserMessage(crewId: "c", text: "@session 去做 X")
        let out = emitter(store, dir).emitAndAdvance()
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("additionalContext"))
        XCTAssertTrue(out!.contains("去做 X"))
        XCTAssertTrue(out!.contains("可信"), "必须带 trust 提示(Spike 2 副作用)")
    }

    func testSecondCallAfterReadReturnsNil() {
        let dir = tempDir()
        let store = LocalWhiteboardStore(directory: dir)
        store.appendUserMessage(crewId: "c", text: "msg")
        XCTAssertNotNil(emitter(store, dir).emitAndAdvance())
        // 游标已推进，已读完 → nil（不重复注入）。
        XCTAssertNil(emitter(store, dir).emitAndAdvance())
    }

    func testOnlyNewMessagesAfterCursor() {
        let dir = tempDir()
        let store = LocalWhiteboardStore(directory: dir)
        store.appendUserMessage(crewId: "c", text: "first")
        _ = emitter(store, dir).emitAndAdvance()
        store.appendUserMessage(crewId: "c", text: "second")
        let out = emitter(store, dir).emitAndAdvance()
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("second"))
        XCTAssertFalse(out!.contains("first"), "first 已读，不再注入")
    }

    func testEmptyWhiteboardReturnsNil() {
        let dir = tempDir()
        XCTAssertNil(emitter(LocalWhiteboardStore(directory: dir), dir).emitAndAdvance())
    }

    func testPerSessionCursorsIndependent() {
        let dir = tempDir()
        let store = LocalWhiteboardStore(directory: dir)
        store.appendUserMessage(crewId: "c", text: "广播给全员")
        _ = emitter(store, dir, session: "s1").emitAndAdvance()   // s1 读了
        let out = emitter(store, dir, session: "s2").emitAndAdvance()  // s2 仍未读
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("广播给全员"))
    }

    // MARK: - 发送者名（Phase 3：白板看得见是谁发的）

    func testSessionMessageWithNameRendersName() {
        let dir = tempDir()
        let store = LocalWhiteboardStore(directory: dir)
        store.appendSessionMessage(crewId: "c", sessionId: "sess-abcdef12",
                                   text: "我开始干活了", senderName: "小绿")
        let out = emitter(store, dir).emitAndAdvance()
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("小绿"), "有 senderName 时应渲染名字")
        XCTAssertFalse(out!.contains("session:sess-abcdef12"), "有名字时不再裸 uuid")
    }

    func testSessionMessageWithoutNameFallsBackToSessionId() {
        let dir = tempDir()
        let store = LocalWhiteboardStore(directory: dir)
        store.appendSessionMessage(crewId: "c", sessionId: "sess-9", text: "无名发言")
        let out = emitter(store, dir).emitAndAdvance()
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("session:sess-9"), "无 senderName 退回旧格式 session:<id>")
    }

    func testUserMessageWithNameRendersName() {
        let dir = tempDir()
        let store = LocalWhiteboardStore(directory: dir)
        store.appendUserMessage(crewId: "c", text: "人类留言", senderName: "阿强")
        let out = emitter(store, dir).emitAndAdvance()
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("阿强"))
    }

    func testUserMessageWithoutNameFallsBackToHuman() {
        let dir = tempDir()
        let store = LocalWhiteboardStore(directory: dir)
        store.appendUserMessage(crewId: "c", text: "人类留言")
        let out = emitter(store, dir).emitAndAdvance()
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("人类"), "无 senderName 退回旧格式「人类」")
    }
}
