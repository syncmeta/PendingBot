#if os(macOS)
import XCTest
// Sources compiled directly into the test bundle (see project.yml) — no module import needed.

// ─────────────────────────────────────────────────────────────────────────────
// Fixture helpers
// ─────────────────────────────────────────────────────────────────────────────

private let iso = ISO8601DateFormatter()
private func ts() -> String { "2026-01-01T00:00:00Z" }

/// Decode a `CrewWhiteboardEntry` from a minimal JSON dict.
private func makeEntry(
    id: String = "e1",
    senderKind: String,
    senderUserId: String? = nil,
    senderBotId: String? = nil,
    senderSessionId: String? = nil,
    senderDisplayName: String? = nil,
    summary: String = "hello",
    payloadKind: String? = nil
) throws -> CrewWhiteboardEntry {
    var d: [String: Any] = [
        "id": id,
        "sender_kind": senderKind,
        "message_kind": "announcement",
        "summary": summary,
        "created_at": ts()
    ]
    if let v = senderUserId { d["sender_user_id"] = v }
    if let v = senderBotId  { d["sender_bot_id"]  = v }
    if let v = senderSessionId { d["sender_session_id"] = v }
    if let v = senderDisplayName { d["sender_display_name"] = v }
    if let pk = payloadKind {
        d["payload"] = ["kind": pk]
    }
    let data = try JSONSerialization.data(withJSONObject: d)
    return try JSONDecoder().decode(CrewWhiteboardEntry.self, from: data)
}

/// Decode a `CrewMember` from a minimal JSON dict.
private func makeMember(
    id: String = "m1",
    memberKind: String,
    userId: String? = nil,
    botId: String? = nil,
    codeSessionId: String? = nil,
    displayName: String? = nil,
    sessionStatus: String? = nil
) throws -> CrewMember {
    var d: [String: Any] = [
        "id": id,
        "member_kind": memberKind,
        "status": "active"
    ]
    if let v = userId        { d["user_id"]          = v }
    if let v = botId         { d["bot_id"]           = v }
    if let v = codeSessionId { d["code_session_id"]  = v }
    if let v = displayName   { d["display_name"]     = v }
    if let v = sessionStatus { d["sessionStatus"]    = v }
    let data = try JSONSerialization.data(withJSONObject: d)
    return try JSONDecoder().decode(CrewMember.self, from: data)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

final class CrewChatAdapterTests: XCTestCase {

    // ── 1. Own user message → isMine true, groupSender nil ───────────────────

    func testOwnUserMessage_isMineAndNoGroupSender() throws {
        let entry = try makeEntry(
            id: "e-own",
            senderKind: "user",
            senderUserId: "uid-me",
            summary: "Hi there"
        )
        let members: [CrewMember] = []
        let (msg, sender) = CrewChatAdapter.adapt(
            entry, members: members, captainBotId: nil, localUserId: "uid-me")

        XCTAssertTrue(msg.isMine(currentUserId: "uid-me"),
                      "own message must report isMine = true")
        XCTAssertTrue(msg.mine, "stored mine flag must be true for own message")
        XCTAssertNil(sender, "groupSender must be nil for own messages (right-aligned)")
    }

    // ── 2. Peer bot message (captain) → correct groupSender ──────────────────

    func testCaptainBotMessage_groupSenderWithCaptainFlag() throws {
        let captainBotId = "bot-captain"
        let entry = try makeEntry(
            id: "e-bot",
            senderKind: "bot",
            senderBotId: captainBotId,
            summary: "I am the captain"
        )
        let member = try makeMember(
            id: "m-captain",
            memberKind: "captain",
            botId: captainBotId,
            displayName: "Captain Bot"
        )
        let (msg, sender) = CrewChatAdapter.adapt(
            entry, members: [member], captainBotId: captainBotId, localUserId: "uid-me")

        XCTAssertFalse(msg.mine, "bot message must not be mine")
        XCTAssertFalse(msg.isMine(currentUserId: "uid-me"))

        let s = try XCTUnwrap(sender, "captain bot message must have a groupSender")
        XCTAssertEqual(s.kind, .bot, "captain is a bot kind")
        XCTAssertEqual(s.displayName, "Captain Bot", "displayName from roster")
        XCTAssertTrue(s.isCaptain, "isCaptain shim must be true for captain")
        XCTAssertFalse(s.isSession, "isSession must be false for a bot")
    }

    // ── 3. Relay message: senderDisplayName non-nil + uid matches local ───────
    //    Even though uid == localUserId, relay messages must NOT be mine.

    func testRelayMessage_notMineEvenIfUidMatches() throws {
        // A Mac relay message: edge back-fills senderDisplayName = the Mac
        // user's label; the uid field also happens to equal localUserId.
        let entry = try makeEntry(
            id: "e-relay",
            senderKind: "user",
            senderUserId: "uid-me",         // same as localUserId!
            senderDisplayName: "Me (Mac)",  // non-nil → relay → never mine
            summary: "relayed message"
        )
        let (msg, sender) = CrewChatAdapter.adapt(
            entry, members: [], captainBotId: nil, localUserId: "uid-me")

        XCTAssertFalse(msg.mine,
                       "relay message must NOT be mine even when uid matches localUserId")
        XCTAssertFalse(msg.isMine(currentUserId: "uid-me"),
                       "isMine must return false for relay messages (CrewSenderResolver guards this)")
        XCTAssertNotNil(sender,
                        "relay message must produce a non-nil groupSender (left-aligned)")
        XCTAssertEqual(sender?.displayName, "Me (Mac)")
    }

    // ── 4. Interaction entry → isInteraction true ─────────────────────────────

    func testInteractionEntry_isInteractionTrue() throws {
        let entry = try makeEntry(
            id: "e-interaction",
            senderKind: "bot",
            senderBotId: "bot-1",
            summary: "Need approval",
            payloadKind: "interaction"
        )
        XCTAssertTrue(CrewChatAdapter.isInteraction(entry),
                      "isInteraction must be true for payload.kind == 'interaction'")
    }

    // ── 5. Session sender → isSession shim set, isMine false ─────────────────

    func testSessionMessage_isSessionShimAndNotMine() throws {
        let entry = try makeEntry(
            id: "e-session",
            senderKind: "session",
            senderSessionId: "sess-abc123",
            summary: "Running task"
        )
        let member = try makeMember(
            id: "m-session",
            memberKind: "code_session",
            codeSessionId: "sess-abc123",
            displayName: "Claude agent",
            sessionStatus: "running"
        )
        let (msg, sender) = CrewChatAdapter.adapt(
            entry, members: [member], captainBotId: nil, localUserId: "uid-me")

        XCTAssertFalse(msg.mine, "session message is never mine")
        let s = try XCTUnwrap(sender)
        XCTAssertTrue(s.isSession, "isSession shim must be true for session senders")
        XCTAssertEqual(s.kind, .bot, "session maps to .bot GroupBubbleSender.Kind")
        XCTAssertEqual(s.displayName, "Claude agent")
        // sessionStatus may or may not be populated depending on roster lookup;
        // when member is found it should be forwarded.
        XCTAssertEqual(s.sessionStatus, "running")
    }
}
#endif
