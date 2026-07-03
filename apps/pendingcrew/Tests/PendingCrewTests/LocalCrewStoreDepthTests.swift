import XCTest

@MainActor
final class LocalCrewStoreDepthTests: XCTestCase {
    /// 用注入目录起干净 store，直接建链：a ← b ← c(b 的父是 a…)。
    private func freshStore() -> LocalCrewStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crewdepth-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LocalCrewStore(baseDirectory: dir)
    }

    private func req(title: String) -> CreateCrewRequest {
        .make(responsibleSubjectId: "local-byok", title: title, machineId: nil,
              workingDirectory: "/tmp/x", captainAgentKind: "codex",
              captain: .systemGenerated(templateName: nil))
    }

    func testRootDepthZero() {
        let s = freshStore()
        let resp = s.createCrew(req(title: "root"))
        XCTAssertEqual(s.depth(of: resp.crewId), 0)
    }

    func testChainDepthCounts() throws {
        let s = freshStore()
        let a = s.createCrew(req(title: "a")).crewId
        let b = s.createCrew(req(title: "b")).crewId
        let c = s.createCrew(req(title: "c")).crewId
        try s.attachParent(crewId: b, parentCrewId: a)
        try s.attachParent(crewId: c, parentCrewId: b)
        XCTAssertEqual(s.depth(of: a), 0)
        XCTAssertEqual(s.depth(of: b), 1)
        XCTAssertEqual(s.depth(of: c), 2)
    }

    func testUnknownCrewDepthZero() {
        XCTAssertEqual(freshStore().depth(of: "local-nope"), 0)
    }
}
