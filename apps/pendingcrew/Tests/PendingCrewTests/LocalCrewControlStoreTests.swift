import XCTest

final class LocalCrewControlStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("crewctl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testRequestThenPeek() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestRename(crewId: "local-abc", name: "鉴权重构")
        XCTAssertEqual(s.pendingRename(crewId: "local-abc"), "鉴权重构")
    }

    func testRequestTrimsAndRejectsEmpty() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestRename(crewId: "c", name: "  深色模式  ")
        XCTAssertEqual(s.pendingRename(crewId: "c"), "深色模式")
        s.requestRename(crewId: "blank", name: "   \n  ")
        XCTAssertNil(s.pendingRename(crewId: "blank"))
    }

    func testDrainReturnsAndDeletes() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestRename(crewId: "local-abc", name: "语音重连")
        let drained = s.drainRenames()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].crewId, "local-abc")
        XCTAssertEqual(drained[0].title, "语音重连")
        // 排空后文件已删 —— 再 drain / peek 为空。
        XCTAssertNil(s.pendingRename(crewId: "local-abc"))
        XCTAssertTrue(s.drainRenames().isEmpty)
    }

    func testLastWriteWins() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestRename(crewId: "c", name: "旧名")
        s.requestRename(crewId: "c", name: "新名")
        let drained = s.drainRenames()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].title, "新名")
    }

    func testCrewsIsolated() {
        let s = LocalCrewControlStore(directory: tempDir())
        s.requestRename(crewId: "local-a", name: "甲")
        s.requestRename(crewId: "local-b", name: "乙")
        let map = Dictionary(uniqueKeysWithValues: s.drainRenames().map { ($0.crewId, $0.title) })
        XCTAssertEqual(map["local-a"], "甲")
        XCTAssertEqual(map["local-b"], "乙")
    }

    func testPersistsAcrossInstances() {
        let dir = tempDir()
        LocalCrewControlStore(directory: dir).requestRename(crewId: "c", name: "持久")
        XCTAssertEqual(LocalCrewControlStore(directory: dir).pendingRename(crewId: "c"), "持久")
    }
}
