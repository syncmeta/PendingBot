import XCTest
// CrewComposerMentions + CrewModels 直接编进 PendingCrewTests target，无需 import。

/// composer @-mention 纯逻辑单测(Phase 6 单元 1/4):候选构建+过滤、
/// 活动 @token 检测、token 插入、staged 撤销对账、reply 自动@推导。
final class CrewComposerMentionsTests: XCTestCase {

    // MARK: - fixtures

    private func member(
        id: String,
        kind: String,
        userId: String? = nil,
        sessionId: String? = nil,
        name: String?
    ) -> CrewMember {
        CrewMember(
            id: id, memberKind: kind, userId: userId, botId: nil,
            codeSessionId: sessionId, displayName: name, role: nil,
            status: "active", representsCrewId: nil, sessionStatus: nil)
    }

    private func entry(
        id: String = "e1",
        senderKind: String,
        sessionId: String? = nil,
        userId: String? = nil,
        text: String = "hi"
    ) -> CrewWhiteboardEntry {
        CrewWhiteboardEntry(
            id: id, senderKind: senderKind, senderSessionId: sessionId,
            senderUserId: userId, senderBotId: nil, messageKind: "instruction",
            summary: text, createdAt: "2026-06-15T00:00:00Z",
            payload: nil, attachments: nil, relay: nil,
            senderDisplayName: nil, senderMemberId: nil)
    }

    // MARK: - candidates

    func testCandidatesIncludeBroadcastCaptainSessionsHumansInOrder() {
        let members = [
            member(id: "s1", kind: "code_session", sessionId: "sess-aaa", name: "小绿"),
            member(id: "h1", kind: "human", userId: "u1", name: "Alice"),
        ]
        let cands = crewMentionCandidates(
            members: members, captainBotId: "bot-cap", prefix: "", selfMemberId: nil)
        XCTAssertEqual(cands.map(\.kind),
                       [.broadcast, .captain, .session, .human])
        // broadcast / captain mentions
        XCTAssertEqual(cands[0].mention, .broadcast)
        XCTAssertEqual(cands[1].mention, .captain)
        XCTAssertEqual(cands[2].mention, .session("sess-aaa"))
        XCTAssertEqual(cands[3].mention, CrewMention(kind: "human", targetId: "u1"))
    }

    func testCandidatesDropCaptainWhenNoneAndSkipSelfHuman() {
        let members = [
            member(id: "me", kind: "human", userId: "u-me", name: "我"),
            member(id: "h1", kind: "human", userId: "u1", name: "Alice"),
        ]
        let cands = crewMentionCandidates(
            members: members, captainBotId: nil, prefix: "", selfMemberId: "me")
        // no captain candidate; self human skipped → broadcast + Alice
        XCTAssertEqual(cands.map(\.label), ["全体", "Alice"])
    }

    func testCandidatePrefixFilterIsCaseInsensitiveSubstring() {
        let members = [
            member(id: "s1", kind: "code_session", sessionId: "sess-aaa", name: "小绿"),
            member(id: "h1", kind: "human", userId: "u1", name: "Alice"),
        ]
        // prefix "al" matches "Alice" (case-insensitive), not 小绿/全体/机长.
        let cands = crewMentionCandidates(
            members: members, captainBotId: "bot", prefix: "al", selfMemberId: nil)
        XCTAssertEqual(cands.map(\.label), ["Alice"])
    }

    func testCandidateTokenIsAtLabel() {
        let members = [member(id: "s1", kind: "code_session", sessionId: "sess-aaa", name: "小绿")]
        let cands = crewMentionCandidates(
            members: members, captainBotId: nil, prefix: "小", selfMemberId: nil)
        XCTAssertEqual(cands.first?.token, "@小绿")
    }

    // MARK: - activeQuery detection

    func testActiveQueryAtTail() {
        let q = CrewComposerMentionParser.activeQuery(in: "帮我看下 @小")
        XCTAssertEqual(q?.prefix, "小")
    }

    func testActiveQueryEmptyPrefixRightAfterAt() {
        let q = CrewComposerMentionParser.activeQuery(in: "hi @")
        XCTAssertEqual(q?.prefix, "")
    }

    func testActiveQueryClosedBySpaceIsNil() {
        XCTAssertNil(CrewComposerMentionParser.activeQuery(in: "hi @小绿 在吗"))
    }

    func testActiveQueryMidWordAtIsNotMention() {
        // email-like "a@b" — the @ doesn't follow whitespace → not a mention.
        XCTAssertNil(CrewComposerMentionParser.activeQuery(in: "mail a@b"))
    }

    func testActiveQueryAtStartOfDraft() {
        let q = CrewComposerMentionParser.activeQuery(in: "@cap")
        XCTAssertEqual(q?.prefix, "cap")
        XCTAssertEqual(q?.atOffset, 0)
    }

    // MARK: - insert

    func testInsertReplacesOpenTokenAndStages() {
        let cand = CrewMentionCandidate(
            id: "session:sess-aaa", kind: .session, label: "小绿",
            mention: .session("sess-aaa"))
        let ins = CrewComposerMentionParser.insert(candidate: cand, into: "帮我看下 @小")
        XCTAssertEqual(ins?.newDraft, "帮我看下 @小绿 ")
        XCTAssertEqual(ins?.staged, CrewStagedMention(token: "@小绿", mention: .session("sess-aaa")))
    }

    func testInsertWithNoOpenTokenReturnsNil() {
        let cand = CrewMentionCandidate(
            id: "broadcast", kind: .broadcast, label: "全体", mention: .broadcast)
        XCTAssertNil(CrewComposerMentionParser.insert(candidate: cand, into: "已经发完了 "))
    }

    // MARK: - reconcile (staged 撤销)

    func testReconcileKeepsPresentTokensDropsDeleted() {
        let staged = [
            CrewStagedMention(token: "@小绿", mention: .session("s1")),
            CrewStagedMention(token: "@机长", mention: .captain),
        ]
        // user deleted "@机长" from the draft.
        let kept = CrewComposerMentionParser.reconcile(staged: staged, draft: "@小绿 跑测试")
        XCTAssertEqual(kept, [CrewStagedMention(token: "@小绿", mention: .session("s1"))])
    }

    func testReconcileDuplicateTokensMatchedByCount() {
        let staged = [
            CrewStagedMention(token: "@小绿", mention: .session("s1")),
            CrewStagedMention(token: "@小绿", mention: .session("s1")),
        ]
        // only one "@小绿" left in the draft → keep exactly one staged entry.
        let kept = CrewComposerMentionParser.reconcile(staged: staged, draft: "@小绿 在吗")
        XCTAssertEqual(kept.count, 1)
    }

    func testMentionsToSendDeduplicates() {
        let staged = [
            CrewStagedMention(token: "@小绿", mention: .session("s1")),
            CrewStagedMention(token: "@小绿", mention: .session("s1")),
            CrewStagedMention(token: "@全体", mention: .broadcast),
        ]
        let out = CrewComposerMentionParser.mentionsToSend(staged)
        XCTAssertEqual(out, [.session("s1"), .broadcast])
    }

    // MARK: - reply target derivation

    func testReplyToSessionAutoMentionsThatSession() {
        let e = entry(id: "msg-7", senderKind: "session", sessionId: "sess-xyz", text: "我跑完了")
        let t = CrewReplyTargetBuilder.make(entry: e, senderName: "小绿")
        XCTAssertEqual(t.mention, .session("sess-xyz"))
        XCTAssertEqual(t.replyToId, "msg-7")
        XCTAssertEqual(t.quotedSender, "小绿")
        XCTAssertEqual(t.quotedSnippet, "我跑完了")
        XCTAssertEqual(t.staged, CrewStagedMention(token: "@小绿", mention: .session("sess-xyz")))
    }

    func testReplyToHumanAutoMentionsHuman() {
        let e = entry(senderKind: "user", userId: "u-bob", text: "看下这个")
        let t = CrewReplyTargetBuilder.make(entry: e, senderName: "Bob")
        XCTAssertEqual(t.mention, CrewMention(kind: "human", targetId: "u-bob"))
    }

    func testReplyToBotHasNoAutoMentionButKeepsReplyTo() {
        let e = entry(id: "msg-b", senderKind: "bot", text: "机长发言")
        let t = CrewReplyTargetBuilder.make(entry: e, senderName: "机长")
        XCTAssertNil(t.mention)
        XCTAssertNil(t.staged)
        XCTAssertEqual(t.replyToId, "msg-b")
    }

    func testReplySnippetCollapsesAndTruncates() {
        let long = String(repeating: "字", count: 200)
        let e = entry(senderKind: "user", userId: "u1", text: "第一行\n第二行 " + long)
        let t = CrewReplyTargetBuilder.make(entry: e, senderName: "X")
        XCTAssertFalse(t.quotedSnippet.contains("\n"))
        XCTAssertTrue(t.quotedSnippet.hasSuffix("…"))
        XCTAssertLessThanOrEqual(t.quotedSnippet.count, CrewReplyTargetBuilder.snippetLimit + 1)
    }
}
