#if os(macOS)
import XCTest
// 待测源码直接编进 PendingCrewTests bundle（standalone，无 app module）——
// CrewListenLogic / CrewLocalMentionInjectLogic / LocalWhiteboardStore 均见 project.yml。

/// `CrewListenLogic` 纯决策核心单测（#465 群聊收听）。
final class CrewListenLogicTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func msg(
        id: String = UUID().uuidString,
        kind: String = "user",
        sessionId: String? = nil,
        text: String = "hello",
        name: String? = nil,
        mentions: [LocalWhiteboardMention]? = nil
    ) -> LocalWhiteboardMessage {
        LocalWhiteboardMessage(
            id: id, senderKind: kind, senderUserId: kind == "user" ? "u1" : nil,
            senderSessionId: sessionId, category: nil, text: text,
            createdAt: "2027-01-15T00:00:00Z", senderName: name, mentions: mentions)
    }

    private func listener(
        _ sessionId: String = "s-listen",
        untilOffset: TimeInterval = 600,
        senders: [String]? = nil
    ) -> CrewListenLogic.Listener {
        .init(sessionId: sessionId, until: now.addingTimeInterval(untilOffset), senders: senders)
    }

    private func idleRun(_ id: String = "s-listen") -> CrewLocalMentionInjectLogic.RunState {
        .init(sessionId: id, isBusy: false)
    }

    // ── 基本投递 ──────────────────────────────────────────────────────────

    func testBroadcastDeliveredToIdleListener() {
        let out = CrewListenLogic.decide(
            entries: [msg(text: "有人看下这个吗")],
            listeners: [listener()], runs: [idleRun()], now: now)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].sessionId, "s-listen")
        XCTAssertTrue(out[0].text.contains("有人看下这个吗"))
        XCTAssertTrue(out[0].text.contains("收听"), "注入文案要点明这是收听送达")
    }

    func testBusyListenerSkipped() {
        let out = CrewListenLogic.decide(
            entries: [msg()], listeners: [listener()],
            runs: [.init(sessionId: "s-listen", isBusy: true)], now: now)
        XCTAssertTrue(out.isEmpty, "busy 不打断——靠下一轮白板注入兜底")
    }

    func testExpiredListenerSkipped() {
        let out = CrewListenLogic.decide(
            entries: [msg()], listeners: [listener(untilOffset: -1)],
            runs: [idleRun()], now: now)
        XCTAssertTrue(out.isEmpty)
    }

    func testNoRunForListenerSkipped() {
        let out = CrewListenLogic.decide(
            entries: [msg()], listeners: [listener()], runs: [], now: now)
        XCTAssertTrue(out.isEmpty)
    }

    // ── 消息过滤 ──────────────────────────────────────────────────────────

    func testOwnMessageNotDelivered() {
        let out = CrewListenLogic.decide(
            entries: [msg(kind: "session", sessionId: "s-listen")],
            listeners: [listener()], runs: [idleRun()], now: now)
        XCTAssertTrue(out.isEmpty)
    }

    func testSystemNoticeNotDelivered() {
        let out = CrewListenLogic.decide(
            entries: [msg(kind: "session", sessionId: "system", name: "系统")],
            listeners: [listener()], runs: [idleRun()], now: now)
        XCTAssertTrue(out.isEmpty)
    }

    func testMentionToOthersFilteredOut() {
        let m = msg(mentions: [LocalWhiteboardMention(kind: "session", targetId: "someone-else")])
        let out = CrewListenLogic.decide(
            entries: [m], listeners: [listener()], runs: [idleRun()], now: now)
        XCTAssertTrue(out.isEmpty, "@ 了别人的定向消息不进收听者视野")
    }

    func testMentionToListenerDelivered() {
        let m = msg(mentions: [LocalWhiteboardMention(kind: "session", targetId: "s-listen")])
        let out = CrewListenLogic.decide(
            entries: [m], listeners: [listener()], runs: [idleRun()], now: now)
        XCTAssertEqual(out.count, 1)
    }

    // ── 发送者过滤 ────────────────────────────────────────────────────────

    func testSenderFilterHumanOnly() {
        let humanMsg = msg(kind: "user", text: "主人指令")
        let peerMsg = msg(kind: "session", sessionId: "s-peer", text: "同事进展", name: "worker")
        let out = CrewListenLogic.decide(
            entries: [humanMsg, peerMsg],
            listeners: [listener(senders: ["human"])], runs: [idleRun()], now: now)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].text.contains("主人指令"))
        XCTAssertFalse(out[0].text.contains("同事进展"))
    }

    func testSenderFilterCaptain() {
        let capMsg = msg(kind: "captain", sessionId: "s-cap", text: "机长安排", name: "机长")
        XCTAssertTrue(CrewListenLogic.senderMatches(capMsg, filter: ["captain"]))
        XCTAssertFalse(CrewListenLogic.senderMatches(capMsg, filter: ["human"]))
    }

    func testSenderFilterBySessionIdPrefix() {
        let peer = msg(kind: "session", sessionId: "abc123def", name: "worker")
        XCTAssertTrue(CrewListenLogic.senderMatches(peer, filter: ["abc123"]))
        XCTAssertFalse(CrewListenLogic.senderMatches(peer, filter: ["zzz"]))
    }

    func testSenderFilterByDisplayName() {
        let peer = msg(kind: "session", sessionId: "abc123def", name: "Claude Code · abc123")
        XCTAssertTrue(CrewListenLogic.senderMatches(peer, filter: ["Claude Code · abc123"]))
    }

    // ── 多收听者 / 打包 ───────────────────────────────────────────────────

    func testMultipleListenersEachGetOwnInjection() {
        let out = CrewListenLogic.decide(
            entries: [msg()],
            listeners: [listener("s-a"), listener("s-b")],
            runs: [idleRun("s-a"), idleRun("s-b")], now: now)
        XCTAssertEqual(Set(out.map(\.sessionId)), ["s-a", "s-b"])
    }

    func testBatchBundledIntoOneInjection() {
        let out = CrewListenLogic.decide(
            entries: [msg(text: "第一条"), msg(text: "第二条")],
            listeners: [listener()], runs: [idleRun()], now: now)
        XCTAssertEqual(out.count, 1, "同批多条消息打包成一次注入")
        XCTAssertTrue(out[0].text.contains("第一条"))
        XCTAssertTrue(out[0].text.contains("第二条"))
    }
}
#endif
