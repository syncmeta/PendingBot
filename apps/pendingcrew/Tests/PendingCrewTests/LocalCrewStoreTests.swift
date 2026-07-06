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

    // MARK: - Attention（机长黄点持久化）

    func testSetAttentionUpdatesSummary() {
        let s = LocalCrewStore(baseDirectory: tempDir())
        let resp = s.createCrew(req(title: "Lisbon"))
        XCTAssertNil(s.listCrews().first?.attentionReason)
        s.setAttention(resp.crewId, reason: "需要人类拍板")
        XCTAssertEqual(s.listCrews().first(where: { $0.id == resp.crewId })?.attentionReason, "需要人类拍板")
    }

    func testSetAttentionNilClears() {
        let s = LocalCrewStore(baseDirectory: tempDir())
        let resp = s.createCrew(req(title: "Lisbon"))
        s.setAttention(resp.crewId, reason: "有问题")
        s.setAttention(resp.crewId, reason: nil)
        XCTAssertNil(s.listCrews().first(where: { $0.id == resp.crewId })?.attentionReason)
    }

    func testSetAttentionBlankTreatedAsClear() {
        let s = LocalCrewStore(baseDirectory: tempDir())
        let resp = s.createCrew(req(title: "Lisbon"))
        s.setAttention(resp.crewId, reason: "有问题")
        s.setAttention(resp.crewId, reason: "   ")
        XCTAssertNil(s.listCrews().first(where: { $0.id == resp.crewId })?.attentionReason)
    }

    func testSetAttentionPersistsAcrossInstances() {
        let dir = tempDir()
        let s = LocalCrewStore(baseDirectory: dir)
        let resp = s.createCrew(req(title: "Lisbon"))
        s.setAttention(resp.crewId, reason: "app 重启不丢")
        XCTAssertEqual(
            LocalCrewStore(baseDirectory: dir).listCrews()
                .first(where: { $0.id == resp.crewId })?.attentionReason,
            "app 重启不丢")
    }

    func testSetAttentionUnknownCrewIgnored() {
        let s = LocalCrewStore(baseDirectory: tempDir())
        s.setAttention("local-does-not-exist", reason: "x")  // 不崩即可
        XCTAssertNil(s.getCrew("local-does-not-exist"))
    }

    // 旧 JSON（无 attentionReason 键）向后兼容：能解码，字段兜 nil。
    func testDecodesLegacyJSONWithoutAttentionReason() throws {
        let dir = tempDir()
        let legacy = """
        {"version":1,"crews":[{
            "id":"local-legacy",
            "title":"老 crew",
            "responsibleSubjectId":"local-byok",
            "runtimeLocation":"local_host",
            "createdAt":"2026-01-01T00:00:00Z",
            "updatedAt":"2026-01-01T00:00:00Z"
        }]}
        """
        try legacy.data(using: .utf8)!.write(to: dir.appendingPathComponent("local-crews.json"))
        let s = LocalCrewStore(baseDirectory: dir)
        let summary = s.listCrews().first(where: { $0.id == "local-legacy" })
        XCTAssertNotNil(summary)                    // 解码没炸（没走 corrupt 备份路径）
        XCTAssertEqual(summary?.title, "老 crew")
        XCTAssertNil(summary?.attentionReason)
        // 老记录也能点亮。
        s.setAttention("local-legacy", reason: "补个黄点")
        XCTAssertEqual(s.listCrews().first(where: { $0.id == "local-legacy" })?.attentionReason, "补个黄点")
    }
}
