import XCTest
@testable import PendingCrew

final class LocalCodingAgentRunnerTests: XCTestCase {
    func testCrewChatMentionTargetsIncludeMembersAndSessions() {
        let member = CrewMember(
            id: "member-1",
            conversationId: "crew-1",
            memberKind: "human",
            userId: "user-1",
            botId: nil,
            codeSessionId: nil,
            displayName: "Yanze",
            role: "owner",
            capabilities: .object([:]),
            status: "active",
            createdAt: "2026-05-24T00:00:00Z"
        )
        let session = CrewSession(
            id: "session-1",
            crewConversationId: "crew-1",
            responsibleSubjectId: "subject-1",
            runnerKind: "local_codex",
            status: "running",
            taskBrief: "整理 Crew 地基",
            progressSummary: nil,
            createdAt: "2026-05-24T00:00:00Z",
            startedAt: nil,
            finishedAt: nil
        )

        let targets = CrewChatMentionTarget.targets(sessions: [session], members: [member])

        XCTAssertEqual(targets.map(\.title), ["全员", "Yanze", "local_codex:session"])
        XCTAssertEqual(targets[1].memberId, "member-1")
        XCTAssertNil(targets[1].sessionId)
        XCTAssertEqual(targets[2].sessionId, "session-1")
        XCTAssertNil(targets[2].memberId)
    }

    func testDefaultCodexProfileRendersSessionCommand() throws {
        let session = CrewSession(
            id: "session-1",
            crewConversationId: "crew-1",
            responsibleSubjectId: "subject-1",
            runnerKind: "local_codex",
            status: "running",
            taskBrief: "整理 Crew 地基",
            progressSummary: nil,
            createdAt: "2026-05-24T00:00:00Z",
            startedAt: nil,
            finishedAt: nil
        )

        let profile = try XCTUnwrap(LocalCodingAgentProfile.defaultProfile(for: session.runnerKind, workingDirectoryPath: "/tmp/work"))
        let command = profile.renderCommand(for: session)

        XCTAssertEqual(command.executableURL.path, "/usr/bin/env")
        XCTAssertEqual(command.arguments, ["codex", "exec", "整理 Crew 地基"])
        XCTAssertEqual(command.workingDirectoryURL?.path, "/tmp/work")
    }

    func testCloudSandboxHasNoLocalProfile() {
        XCTAssertNil(LocalCodingAgentProfile.defaultProfile(for: "cloud_sandbox", workingDirectoryPath: "/tmp/work"))
    }

    func testContextPacketInjectsMailboxIntoPrompt() {
        let session = CrewSession(
            id: "session-1",
            crewConversationId: "crew-1",
            responsibleSubjectId: "subject-1",
            runnerKind: "local_codex",
            status: "running",
            taskBrief: "整理 Crew 地基",
            progressSummary: nil,
            createdAt: "2026-05-24T00:00:00Z",
            startedAt: nil,
            finishedAt: nil
        )
        let mailbox = [
            SessionMailboxItem(
                id: "mail-1",
                announcementId: "ann-1",
                crewConversationId: "crew-1",
                responsibleSubjectId: "subject-1",
                senderKind: "human",
                senderMemberId: "member-1",
                senderSessionId: nil,
                recipientSessionId: "session-1",
                messageKind: "instruction",
                summary: "只处理 API 层",
                payload: .object([:]),
                status: "unread",
                createdAt: "2026-05-24T00:00:01Z",
                readAt: nil
            )
        ]

        let prompt = LocalCodingAgentContextPacket.render(session: session, mailbox: mailbox)

        XCTAssertTrue(prompt.contains("整理 Crew 地基"))
        XCTAssertTrue(prompt.contains("只处理 API 层"))
        XCTAssertTrue(prompt.contains("不要把过程日志刷到 Crew 群聊"))
    }

    func testOutputSummaryPrefersStdoutAndTruncates() {
        let result = LocalCodingAgentProcessResult(
            exitCode: 0,
            standardOutput: String(repeating: "a", count: 120),
            standardError: "stderr",
            duration: 1.25
        )

        let summary = LocalCodingAgentOutput.finalSummary(result, maxCharacters: 40)

        XCTAssertTrue(summary.hasPrefix("本机执行完成"))
        XCTAssertTrue(summary.contains("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        XCTAssertTrue(summary.hasSuffix("..."))
    }
}
