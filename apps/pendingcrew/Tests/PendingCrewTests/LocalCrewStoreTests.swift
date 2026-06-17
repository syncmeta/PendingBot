import XCTest

@MainActor
final class LocalCrewStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("crewstore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func req(title: String?) -> CreateCrewRequest {
        .make(responsibleSubjectId: "local-byok", title: title, machineId: nil,
              workingDirectory: "/tmp/x", captainAgentKind: "codex",
              captain: .systemGenerated(templateName: nil))
    }

    func testCreateUsesProvidedTitle() {
        let s = LocalCrewStore(baseDirectory: tempDir())
        let resp = s.createCrew(req(title: "支付接入"))
        XCTAssertEqual(s.getCrew(resp.crewId)?.crew.title, "支付接入")
    }

    // 自动名（nil title）兜底成地名（测试 bundle 无 crewground_places.txt →
    // PlaceNames 回落 ["Atlantis"]）—— 关键是**不再**是「未命名 crew」。
    func testCreateNilTitleIsNotUnnamed() {
        let s = LocalCrewStore(baseDirectory: tempDir())
        let resp = s.createCrew(req(title: nil))
        let title = s.getCrew(resp.crewId)?.crew.title ?? ""
        XCTAssertFalse(title.isEmpty)
        XCTAssertNotEqual(title, "未命名 crew")
    }

    func testSetTitleUpdates() {
        let s = LocalCrewStore(baseDirectory: tempDir())
        let resp = s.createCrew(req(title: "Lisbon"))
        s.setTitle(resp.crewId, "鉴权重构")
        XCTAssertEqual(s.getCrew(resp.crewId)?.crew.title, "鉴权重构")
        XCTAssertEqual(s.listCrews().first(where: { $0.id == resp.crewId })?.title, "鉴权重构")
    }

    func testSetTitlePersistsAcrossInstances() {
        let dir = tempDir()
        let s = LocalCrewStore(baseDirectory: dir)
        let resp = s.createCrew(req(title: "Lisbon"))
        s.setTitle(resp.crewId, "深色模式")
        XCTAssertEqual(LocalCrewStore(baseDirectory: dir).getCrew(resp.crewId)?.crew.title, "深色模式")
    }

    func testSetTitleEmptyIgnored() {
        let s = LocalCrewStore(baseDirectory: tempDir())
        let resp = s.createCrew(req(title: "Lisbon"))
        s.setTitle(resp.crewId, "   ")
        XCTAssertEqual(s.getCrew(resp.crewId)?.crew.title, "Lisbon")
    }

    func testSetTitleUnknownCrewIgnored() {
        let s = LocalCrewStore(baseDirectory: tempDir())
        s.setTitle("local-does-not-exist", "x")  // 不崩即可
        XCTAssertNil(s.getCrew("local-does-not-exist"))
    }
}
