import XCTest
// CockpitModel.swift 直接编进 test bundle（见 project.yml），所以不需要 @testable import。

final class CockpitRoadmapParserTests: XCTestCase {
    let sample = """
    > 路线账。阶段按文件顺序排先后。

    当前主线:v1 收口。

    ## v1 收口
    status: doing
    target: 2026-08
    目标: 本地闭环全链路真机可用。
    - pendingcrew/concepts/cockpit — 路线段本身
    - pendingcrew/concepts/local-first

    ## v1.1 远端 runner
    status: planned
    目标: fly machine 开通。
    - pendingcrew/concepts/runtime-location-and-machine
    """

    func testParsePreambleAndPhases() {
        let r = CockpitParser.parseRoadmapFile(sample)
        XCTAssertTrue(r.preamble.contains("当前主线:v1 收口。"))
        XCTAssertTrue(r.preamble.contains("路线账"))
        XCTAssertEqual(r.phases.map(\.name), ["v1 收口", "v1.1 远端 runner"])
        let p1 = r.phases[0]
        XCTAssertEqual(p1.status, "doing")
        XCTAssertEqual(p1.target, "2026-08")
        XCTAssertEqual(p1.goal, "本地闭环全链路真机可用。")
        XCTAssertEqual(p1.entries, [
            CockpitPhaseEntry(relpath: "pendingcrew/concepts/cockpit", note: "路线段本身"),
            CockpitPhaseEntry(relpath: "pendingcrew/concepts/local-first", note: ""),
        ])
        XCTAssertEqual(r.phases[1].target, "")
        XCTAssertEqual(r.phases[1].entries.count, 1)
    }

    func testParseEmptyAndNoPhases() {
        XCTAssertEqual(CockpitParser.parseRoadmapFile("").phases.count, 0)
        let r = CockpitParser.parseRoadmapFile("只有一段话,没有阶段。")
        XCTAssertEqual(r.preamble, "只有一段话,没有阶段。")
        XCTAssertTrue(r.phases.isEmpty)
    }

    func testPhaseProgressBucketsAndUnfiled() {
        func topic(_ rel: String, _ status: String) -> CockpitTopic {
            let parts = rel.split(separator: "/", maxSplits: 1).map(String.init)
            return CockpitTopic(area: parts[0], key: parts[1], status: status,
                                summary: "", evidence: "", taskIds: [], taskRaw: "")
        }
        let phase = CockpitPhase(name: "x", status: "doing", target: "", goal: "", entries: [
            CockpitPhaseEntry(relpath: "a/one", note: ""),
            CockpitPhaseEntry(relpath: "a/two", note: ""),
            CockpitPhaseEntry(relpath: "a/three", note: ""),
        ])
        let dist = cockpitPhaseProgress(phase, topics: [topic("a/one", "done"), topic("a/two", "partial, pending-qa")])
        // a/three 无现状条 → unfiled;a/two 含 pending-qa → pending-qa 桶
        XCTAssertEqual(dist, [
            CockpitStats.StatusCount(bucket: "done", count: 1),
            CockpitStats.StatusCount(bucket: "pending-qa", count: 1),
            CockpitStats.StatusCount(bucket: "unfiled", count: 1),
        ])
    }
}
