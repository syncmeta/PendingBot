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
}
