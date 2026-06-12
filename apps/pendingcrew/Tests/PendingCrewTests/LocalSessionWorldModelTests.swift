import XCTest
// LocalSessionWorldModel + LocalPromptLoader + PromptTemplate 都编进 test bundle；
// prompt .md 作为 test bundle 资源（见 project.yml）。

final class LocalSessionWorldModelTests: XCTestCase {
    private var renderer: LocalSessionWorldModel {
        LocalSessionWorldModel(loader: LocalPromptLoader(bundle: Bundle(for: Self.self)))
    }

    private func sampleContext() -> LocalSessionWorldModel.Context {
        LocalSessionWorldModel.Context(
            sessionTaskBrief: "修登录崩溃",
            runnerKind: "claude_code",
            crewId: "local-abc",
            crewTitle: "登录修复组",
            workingDirectory: "/tmp/proj",
            humans: [.init(displayName: "阿德", role: "owner", userId: "u-1")],
            captainName: "机长甲",
            captainBotId: "local-bot-9"
        )
    }

    func testRendersCoreFacts() throws {
        let out = try renderer.render(sampleContext())
        XCTAssertTrue(out.contains("修登录崩溃"), "task brief")
        XCTAssertTrue(out.contains("登录修复组"), "crew title")
        XCTAssertTrue(out.contains("claude_code"), "runner kind")
        XCTAssertTrue(out.contains("阿德"), "human roster")
        XCTAssertTrue(out.contains("机长甲"), "captain name")
        XCTAssertTrue(out.contains("local_host"), "local runtime")
        XCTAssertTrue(out.contains("auto mode"), "fixed auto-mode wording present")
    }

    func testNoTemplateSyntaxLeaks() throws {
        let out = try renderer.render(sampleContext())
        // 未提供的 lineage/shares/tiebreaker 槽必须被 strip，不泄漏给 agent。
        XCTAssertFalse(out.contains("{{"), "no {{ }} may leak")
    }

    func testEmptyRosterPlaceholder() {
        var ctx = sampleContext()
        ctx.humans = []
        XCTAssertEqual(renderer.buildVars(ctx)["humanRoster"], "(暂无)")
    }

    func testNoCaptainPlaceholder() {
        var ctx = sampleContext()
        ctx.captainName = nil
        ctx.captainBotId = nil
        XCTAssertEqual(renderer.buildVars(ctx)["captainBlock"], "本 crew 暂无指定 captain。")
    }

    func testBuildVarsOmitsLineageAndShares() {
        let vars = renderer.buildVars(sampleContext())
        // 这三个本地不提供 → 不在 vars 里（交给 PromptTemplate strip）。
        XCTAssertNil(vars["lineageBlock"])
        XCTAssertNil(vars["sharesBlock"])
        XCTAssertNil(vars["tiebreakerBlock"])
        XCTAssertEqual(vars["runtimeLocation"], "local_host")
    }

    func testEmptyBriefPlaceholder() {
        var ctx = sampleContext()
        ctx.sessionTaskBrief = ""
        XCTAssertEqual(renderer.buildVars(ctx)["sessionTaskBrief"], "(无任务描述)")
    }
}
