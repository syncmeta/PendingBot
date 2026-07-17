import XCTest
import Combine
// 不 `` —— PendingCrewTests 是 standalone bundle
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

    // MARK: - #483 解码失败 fail-loud + 逐条 lenient 解码 + 并发写防护

    private func rawFileURL(_ dir: URL, _ crewId: String) -> URL {
        dir.appendingPathComponent("\(crewId).json")
    }

    private func corruptArchives(_ dir: URL, _ crewId: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("\(crewId).json.corrupt-") }
    }

    func testCorruptFileArchivedAndWarnsInsteadOfSilentEmpty() throws {
        let dir = tempDir()
        let garbage = Data("not json at all {{{".utf8)
        try garbage.write(to: rawFileURL(dir, "c"))
        let store = LocalWhiteboardStore(directory: dir)
        let rows = store.list(crewId: "c")
        // fail-loud：白板上留一条系统警示（复用 postSystemNotice 形态），不再静默当空
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].senderKind, "session")
        XCTAssertEqual(rows[0].senderSessionId, "system")
        XCTAssertEqual(rows[0].senderName, "系统")
        XCTAssertTrue(rows[0].text.contains("损坏"))
        // 原始损坏字节归档为 .corrupt-<ts>，可人工找回
        let archived = try corruptArchives(dir, "c")
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(archived[0])), garbage)
    }

    func testHalfWrittenFileRecoveredAndAppendKeepsWarning() throws {
        // 半截写入（进程被杀在 write 中途）→ 归档 + 警示；后续 append 不清掉警示
        let dir = tempDir()
        try Data(#"[{"id":"a","senderKind":"user","te"#.utf8).write(to: rawFileURL(dir, "c"))
        let store = LocalWhiteboardStore(directory: dir)
        store.appendUserMessage(crewId: "c", text: "after")
        let rows = store.list(crewId: "c")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].senderSessionId, "system")
        XCTAssertEqual(rows[1].text, "after")
        XCTAssertEqual(try corruptArchives(dir, "c").count, 1)
    }

    func testLenientDecodeDropsOnlyBadElements() throws {
        // 外层数组合法、中间一条缺必填 text（旧二进制读新 schema 之类）→ 只丢那条，
        // 好的不连坐，也不算整文件损坏（不归档不警示）
        let dir = tempDir()
        let json = """
        [{"id":"a","senderKind":"user","text":"one","createdAt":"2026-07-17T00:00:00Z"},
         {"id":"b","senderKind":"user","createdAt":"2026-07-17T00:00:01Z"},
         {"id":"c","senderKind":"user","text":"three","createdAt":"2026-07-17T00:00:02Z"}]
        """
        try Data(json.utf8).write(to: rawFileURL(dir, "c"))
        let store = LocalWhiteboardStore(directory: dir)
        XCTAssertEqual(store.list(crewId: "c").map(\.text), ["one", "three"])
        XCTAssertTrue(try corruptArchives(dir, "c").isEmpty)
    }

    func testUnknownExtraFieldsTolerated() throws {
        // 新 schema 加字段、旧二进制混跑：未知键忽略，消息保留
        let dir = tempDir()
        let json = """
        [{"id":"a","senderKind":"user","text":"keep","createdAt":"2026-07-17T00:00:00Z","futureField":{"x":1}}]
        """
        try Data(json.utf8).write(to: rawFileURL(dir, "c"))
        XCTAssertEqual(LocalWhiteboardStore(directory: dir).list(crewId: "c").map(\.text), ["keep"])
    }

    func testAppendAfterBadElementPreservesGoodOnes() throws {
        // 曾经的致命路径：一条坏 → load 视整板为空 → append 用「空+新」重写清史。
        // 现在：append 后好消息仍在，只有坏那条被丢
        let dir = tempDir()
        let json = """
        [{"id":"a","senderKind":"user","text":"one","createdAt":"2026-07-17T00:00:00Z"},
         {"id":"b","senderKind":"user","createdAt":"2026-07-17T00:00:01Z"}]
        """
        try Data(json.utf8).write(to: rawFileURL(dir, "c"))
        let store = LocalWhiteboardStore(directory: dir)
        store.appendUserMessage(crewId: "c", text: "new")
        XCTAssertEqual(store.list(crewId: "c").map(\.text), ["one", "new"])
    }

    func testConcurrentAppendsAcrossInstancesLoseNothing() {
        // 模拟 app 与 helper 两个进程（两个实例）并发 append —— 文件锁后一条不丢
        let dir = tempDir()
        let a = LocalWhiteboardStore(directory: dir)
        let b = LocalWhiteboardStore(directory: dir)
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            (i % 2 == 0 ? a : b).appendUserMessage(crewId: "c", text: "m\(i)")
        }
        XCTAssertEqual(a.list(crewId: "c").count, 40)
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
