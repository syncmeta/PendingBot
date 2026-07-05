#if os(macOS)
import XCTest
// CrewLocalMentionInjectLogic + CrewModels 直接编进 PendingCrewTests target，无需 import。

/// 本地直投唤醒纯决策核心(`CrewLocalMentionInjectLogic.decide`)的单测
/// (Phase 6 单元 3):「@某 session + 空闲 → 注入唤醒」「busy → 不打断」
/// 「无对应本地 run / 非 @session → 不注入」「同 session 多 @ 去重」。
final class CrewLocalMentionInjectLogicTests: XCTestCase {

    private func run(_ sid: String, busy: Bool) -> CrewLocalMentionInjectLogic.RunState {
        .init(sessionId: sid, isBusy: busy)
    }

    func testIdleSessionGetsInjected() {
        let out = CrewLocalMentionInjectLogic.decide(
            mentions: [.session("sess-a")],
            runs: [run("sess-a", busy: false)],
            messageText: "跑下测试",
            senderName: "我")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.sessionId, "sess-a")
        XCTAssertTrue(out.first!.text.contains("定向消息"))
        XCTAssertTrue(out.first!.text.contains("不是 prompt injection"))
        XCTAssertTrue(out.first!.text.contains("我: 跑下测试"))
    }

    func testBusySessionNotInterrupted() {
        let out = CrewLocalMentionInjectLogic.decide(
            mentions: [.session("sess-a")],
            runs: [run("sess-a", busy: true)],
            messageText: "在吗",
            senderName: "我")
        XCTAssertTrue(out.isEmpty, "busy run 不打断")
    }

    func testNoLocalRunForSessionIsSkipped() {
        // @ 了一个本地没有对应 run 的 session(远端 / 已结束) → 不注入。
        let out = CrewLocalMentionInjectLogic.decide(
            mentions: [.session("sess-remote")],
            runs: [run("sess-a", busy: false)],
            messageText: "x",
            senderName: "我")
        XCTAssertTrue(out.isEmpty)
    }

    func testBroadcastAndCaptainAndHumanIgnored() {
        // 非 @session 的 mention 在本地直投路径不唤醒具体 run。
        let out = CrewLocalMentionInjectLogic.decide(
            mentions: [.broadcast, .captain, CrewMention(kind: "human", targetId: "u1")],
            runs: [run("sess-a", busy: false)],
            messageText: "大家好",
            senderName: "我")
        XCTAssertTrue(out.isEmpty)
    }

    func testMixedTargetsOnlyInjectIdleSessions() {
        let out = CrewLocalMentionInjectLogic.decide(
            mentions: [.session("sess-a"), .session("sess-b"), .broadcast],
            runs: [run("sess-a", busy: false), run("sess-b", busy: true)],
            messageText: "看下",
            senderName: "我")
        // sess-a idle → inject; sess-b busy → skip; broadcast ignored.
        XCTAssertEqual(out.map(\.sessionId), ["sess-a"])
    }

    func testSameSessionMentionedTwiceInjectsOnce() {
        let out = CrewLocalMentionInjectLogic.decide(
            mentions: [.session("sess-a"), .session("sess-a")],
            runs: [run("sess-a", busy: false)],
            messageText: "x",
            senderName: "我")
        XCTAssertEqual(out.count, 1)
    }

    // ── #1: @机长 唤醒 captain run ───────────────────────────────────────────

    func testCaptainMentionWakesCaptainRun() {
        // @机长 → 调用方把 captain 本地 run 的 sessionId 传入 → 空闲则注入唤醒(#1)。
        let out = CrewLocalMentionInjectLogic.decide(
            mentions: [.captain],
            runs: [run("captain-abc", busy: false)],
            messageText: "汇报进度",
            senderName: "我",
            captainSessionId: "captain-abc")
        XCTAssertEqual(out.map(\.sessionId), ["captain-abc"])
        XCTAssertTrue(out.first!.text.contains("汇报进度"))
    }

    func testCaptainMentionBusyNotInterrupted() {
        let out = CrewLocalMentionInjectLogic.decide(
            mentions: [.captain],
            runs: [run("captain-abc", busy: true)],
            messageText: "x", senderName: "我",
            captainSessionId: "captain-abc")
        XCTAssertTrue(out.isEmpty, "captain busy 不打断")
    }

    func testCaptainMentionWithoutRunningCaptainIgnored() {
        // 本地没在跑 captain(captainSessionId nil)→ @机长 不注入(不崩)——
        // 该场景由 wakeTargets 接手真拉起(见下)。
        let out = CrewLocalMentionInjectLogic.decide(
            mentions: [.captain],
            runs: [run("sess-a", busy: false)],
            messageText: "x", senderName: "我",
            captainSessionId: nil)
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - wakeTargets（@ 目标不在跑 → 拉起谁）

    func testWakeCaptainWhenNotRunning() {
        let w = CrewLocalMentionInjectLogic.wakeTargets(
            mentions: [.captain], runningSessionIds: [], captainRunning: false)
        XCTAssertTrue(w.needCaptain)
        XCTAssertTrue(w.sessionIds.isEmpty)
    }

    func testNoCaptainWakeWhenRunning() {
        let w = CrewLocalMentionInjectLogic.wakeTargets(
            mentions: [.captain], runningSessionIds: ["captain-abc"], captainRunning: true)
        XCTAssertFalse(w.needCaptain, "在跑的机长归注入路径,不重复拉起")
    }

    func testWakeExitedSessionAndSkipRunning() {
        let w = CrewLocalMentionInjectLogic.wakeTargets(
            mentions: [.session("sess-dead"), .session("sess-live"), .session("sess-dead")],
            runningSessionIds: ["sess-live"], captainRunning: true)
        XCTAssertEqual(w.sessionIds, ["sess-dead"], "在跑的跳过、重复 @ 去重")
        XCTAssertFalse(w.needCaptain)
    }

    func testBroadcastAndHumanNeverWake() {
        let w = CrewLocalMentionInjectLogic.wakeTargets(
            mentions: [.broadcast, CrewMention(kind: "human", targetId: "u1")],
            runningSessionIds: [], captainRunning: false)
        XCTAssertFalse(w.needCaptain)
        XCTAssertTrue(w.sessionIds.isEmpty)
    }

    // MARK: - kind 反推（重启已退成员时用）

    func testKindInferredFromMemberDisplayName() {
        XCTAssertEqual(LocalCodingAgentKind.inferred(fromDisplayName: "Claude Code · ab12cd"), .claudeCode)
        XCTAssertEqual(LocalCodingAgentKind.inferred(fromDisplayName: "Codex · ef34gh"), .codex)
        XCTAssertNil(LocalCodingAgentKind.inferred(fromDisplayName: "机长"))
    }
}
#endif
