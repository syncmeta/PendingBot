import XCTest
import Combine
// 不 `@testable import PendingCrew` —— PendingCrewTests 是 standalone bundle
// （TEST_HOST=""），不链 app module；待测源码直接编进 bundle（见 project.yml
// 把 Sources/Stores/LocalWhiteboardStore.swift 列进 test target sources）。

@MainActor
final class LocalWhiteboardStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testListMissingCrewReturnsEmpty() {
        let store = LocalWhiteboardStore(directory: tempDir())
        XCTAssertTrue(store.list(crewId: "local-x").isEmpty)
    }

    func testAppendThenListReturnsEntry() {
        let store = LocalWhiteboardStore(directory: tempDir())
        store.appendUserMessage(crewId: "local-x", text: "hello")
        let entries = store.list(crewId: "local-x")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].text, "hello")
        XCTAssertEqual(entries[0].senderKind, "user")
        XCTAssertEqual(entries[0].senderUserId, LocalWhiteboardStore.localUserId)
    }

    func testOrderedByInsertion() {
        let store = LocalWhiteboardStore(directory: tempDir())
        store.appendUserMessage(crewId: "c", text: "1")
        store.appendUserMessage(crewId: "c", text: "2")
        store.appendUserMessage(crewId: "c", text: "3")
        XCTAssertEqual(store.list(crewId: "c").map(\.text), ["1", "2", "3"])
    }

    func testPersistsAcrossInstances() {
        let dir = tempDir()
        LocalWhiteboardStore(directory: dir).appendUserMessage(crewId: "c", text: "persisted")
        let reloaded = LocalWhiteboardStore(directory: dir)
        XCTAssertEqual(reloaded.list(crewId: "c").map(\.text), ["persisted"])
    }

    func testCrewsAreIsolated() {
        let store = LocalWhiteboardStore(directory: tempDir())
        store.appendUserMessage(crewId: "a", text: "in-a")
        store.appendUserMessage(crewId: "b", text: "in-b")
        XCTAssertEqual(store.list(crewId: "a").map(\.text), ["in-a"])
        XCTAssertEqual(store.list(crewId: "b").map(\.text), ["in-b"])
    }

    func testAppendSessionMessage() {
        let s = LocalWhiteboardStore(directory: tempDir())
        s.appendSessionMessage(crewId: "c", sessionId: "sess-1", text: "started", category: "progress")
        let m = s.list(crewId: "c")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].senderKind, "session")
        XCTAssertEqual(m[0].senderSessionId, "sess-1")
        XCTAssertEqual(m[0].category, "progress")
        XCTAssertEqual(m[0].text, "started")
    }

    func testEntriesAfterCursor() {
        let s = LocalWhiteboardStore(directory: tempDir())
        s.appendUserMessage(crewId: "c", text: "1")
        s.appendUserMessage(crewId: "c", text: "2")
        let all = s.list(crewId: "c")
        XCTAssertEqual(s.entries(crewId: "c", afterId: all[0].id).map(\.text), ["2"])
    }

    func testEntriesAfterNilOrUnknownReturnsAll() {
        let s = LocalWhiteboardStore(directory: tempDir())
        s.appendUserMessage(crewId: "c", text: "x")
        XCTAssertEqual(s.entries(crewId: "c", afterId: nil).map(\.text), ["x"])
        XCTAssertEqual(s.entries(crewId: "c", afterId: "no-such-id").map(\.text), ["x"])
    }

    // MARK: - changes publisher（Phase 5：去轮询 —— append 即发 tick）

    func testAppendEmitsChangeWithCrewId() {
        let s = LocalWhiteboardStore(directory: tempDir())
        var received: [String] = []
        let c = s.changes.sink { received.append($0) }
        defer { c.cancel() }
        s.appendUserMessage(crewId: "crew-a", text: "hi")
        XCTAssertEqual(received, ["crew-a"])
    }

    func testEachAppendVariantEmitsOnce() {
        let s = LocalWhiteboardStore(directory: tempDir())
        var count = 0
        let c = s.changes.sink { _ in count += 1 }
        defer { c.cancel() }
        s.appendUserMessage(crewId: "c", text: "u")
        s.appendSessionMessage(crewId: "c", sessionId: "sess", text: "s")
        s.appendRelayMessage(crewId: "c", remoteId: "r1", senderKind: "user",
                             senderDisplayName: "Bob", text: "r", createdAt: "2026-06-15T00:00:00Z")
        XCTAssertEqual(count, 3)
    }

    func testRelayDuplicateDoesNotEmit() {
        // 幂等去重命中（同 remoteId 已存在）→ no-op，不该发 tick。
        let s = LocalWhiteboardStore(directory: tempDir())
        s.appendRelayMessage(crewId: "c", remoteId: "dup", senderKind: "user",
                             senderDisplayName: nil, text: "first", createdAt: "2026-06-15T00:00:00Z")
        var count = 0
        let c = s.changes.sink { _ in count += 1 }
        defer { c.cancel() }
        s.appendRelayMessage(crewId: "c", remoteId: "dup", senderKind: "user",
                             senderDisplayName: nil, text: "second", createdAt: "2026-06-15T00:00:01Z")
        XCTAssertEqual(count, 0)
    }
}
