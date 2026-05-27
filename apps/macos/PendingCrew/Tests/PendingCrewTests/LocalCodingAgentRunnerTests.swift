import XCTest
@testable import PendingCrew

final class LocalCodingAgentRunnerTests: XCTestCase {
    func testPendingCrewDeepLinkParsesCrewAndSessionRoute() throws {
        let route = try XCTUnwrap(PendingCrewDeepLinkRoute(url: URL(string: "pendingcrew://crew/crew-1/session/session-1")!))

        XCTAssertEqual(route.crewId, "crew-1")
        XCTAssertEqual(route.sessionId, "session-1")
    }

    func testPendingCrewDeepLinkRejectsOtherSchemes() {
        XCTAssertNil(PendingCrewDeepLinkRoute(url: URL(string: "https://pendingname.com/crew/crew-1")!))
    }

    func testCrewSidebarIndexShowsSharedChildUnderEachParent() {
        let platform = Crew(
            conversationId: "crew-platform",
            responsibleSubjectId: "subject-1",
            status: "active",
            title: "平台部",
            createdAt: "2026-05-27T00:00:00Z",
            updatedAt: "2026-05-27T00:00:00Z"
        )
        let mobile = Crew(
            conversationId: "crew-mobile",
            responsibleSubjectId: "subject-1",
            status: "active",
            title: "移动部",
            createdAt: "2026-05-27T00:00:00Z",
            updatedAt: "2026-05-27T00:00:00Z"
        )
        let api = Crew(
            conversationId: "crew-api",
            responsibleSubjectId: "subject-1",
            status: "active",
            title: "API 小组",
            createdAt: "2026-05-27T00:00:00Z",
            updatedAt: "2026-05-27T00:00:00Z"
        )
        let apiChildLink = CrewLink(
            crewConversationId: "crew-api",
            title: "API 小组",
            status: "active",
            runtimeKind: "local",
            captainBotId: "bot-api",
            captainMemberId: "captain-api",
            createdAt: "2026-05-27T00:01:00Z"
        )
        let parentLinks = CrewLinksResponse(
            parents: [],
            children: [apiChildLink],
            responsibilityShares: []
        )
        let childLinks = CrewLinksResponse(
            parents: [
                CrewLink(
                    crewConversationId: "crew-platform",
                    title: "平台部",
                    status: "active",
                    runtimeKind: "local",
                    captainBotId: nil,
                    captainMemberId: nil,
                    createdAt: "2026-05-27T00:01:00Z"
                ),
                CrewLink(
                    crewConversationId: "crew-mobile",
                    title: "移动部",
                    status: "active",
                    runtimeKind: "local",
                    captainBotId: nil,
                    captainMemberId: nil,
                    createdAt: "2026-05-27T00:01:00Z"
                )
            ],
            children: [],
            responsibilityShares: []
        )

        let rows = CrewSidebarIndex.flatten(
            crews: [platform, mobile, api],
            linksByCrew: [
                "crew-platform": parentLinks,
                "crew-mobile": parentLinks,
                "crew-api": childLinks
            ]
        )

        XCTAssertEqual(rows.map(\.title), ["平台部", "API 小组", "移动部", "API 小组"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0, 1])
        XCTAssertEqual(rows.map(\.crewId), ["crew-platform", "crew-api", "crew-mobile", "crew-api"])
        XCTAssertEqual(rows.filter { $0.crewId == "crew-api" }.count, 2)
    }

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

    func testCrewChatMentionTargetsLabelCaptainMembers() {
        let captain = CrewMember(
            id: "member-captain",
            conversationId: "crew-1",
            memberKind: "master_bot",
            userId: nil,
            botId: "bot-captain",
            codeSessionId: nil,
            displayName: "API 机长",
            role: "captain",
            capabilities: .object([:]),
            status: "active",
            createdAt: "2026-05-27T00:00:00Z"
        )

        let targets = CrewChatMentionTarget.targets(sessions: [], members: [captain])

        XCTAssertEqual(targets.map(\.title), ["全员", "机长 · API 机长"])
        XCTAssertEqual(targets[1].systemImage, "sparkles")
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
        XCTAssertTrue(prompt.contains("本次注入的机组消息"))
        XCTAssertTrue(prompt.contains("不要把过程日志刷到机组群聊"))
    }

    func testSessionInspectorModelSortsMailboxAndEventsForOperatorScan() {
        let session = CrewSession(
            id: "session-1",
            crewConversationId: "crew-1",
            responsibleSubjectId: "subject-1",
            runnerKind: "local_codex",
            status: "running",
            taskBrief: "把右侧 session 区推进成窗口",
            progressSummary: "正在整理事件",
            createdAt: "2026-05-27T00:00:00Z",
            startedAt: "2026-05-27T00:02:00Z",
            finishedAt: nil
        )
        let mailbox = [
            SessionMailboxItem(
                id: "mail-archived-new",
                announcementId: "ann-3",
                crewConversationId: "crew-1",
                responsibleSubjectId: "subject-1",
                senderKind: "human",
                senderMemberId: "member-1",
                senderSessionId: nil,
                recipientSessionId: "session-1",
                messageKind: "note",
                summary: "已归档但更新",
                payload: .object([:]),
                status: "archived",
                createdAt: "2026-05-27T00:06:00Z",
                readAt: "2026-05-27T00:07:00Z"
            ),
            SessionMailboxItem(
                id: "mail-unread-old",
                announcementId: "ann-1",
                crewConversationId: "crew-1",
                responsibleSubjectId: "subject-1",
                senderKind: "human",
                senderMemberId: "member-1",
                senderSessionId: nil,
                recipientSessionId: "session-1",
                messageKind: "instruction",
                summary: "先读这条",
                payload: .object([:]),
                status: "unread",
                createdAt: "2026-05-27T00:01:00Z",
                readAt: nil
            ),
            SessionMailboxItem(
                id: "mail-unread-new",
                announcementId: "ann-2",
                crewConversationId: "crew-1",
                responsibleSubjectId: "subject-1",
                senderKind: "session",
                senderMemberId: nil,
                senderSessionId: "session-2",
                recipientSessionId: "session-1",
                messageKind: "handoff",
                summary: "最新交接",
                payload: .object([:]),
                status: "unread",
                createdAt: "2026-05-27T00:05:00Z",
                readAt: nil
            )
        ]
        let events = [
            SessionEvent(
                id: "event-old",
                crewSessionId: "session-1",
                eventType: "status",
                visibility: "crew",
                summary: "启动",
                payload: .object([:]),
                createdAt: "2026-05-27T00:02:00Z"
            ),
            SessionEvent(
                id: "event-new",
                crewSessionId: "session-1",
                eventType: "status",
                visibility: "crew",
                summary: "推进中",
                payload: .object([:]),
                createdAt: "2026-05-27T00:04:00Z"
            )
        ]

        let model = SessionInspectorModel(session: session, events: events, mailbox: mailbox)

        XCTAssertEqual(model.shortSessionId, "session-1")
        XCTAssertEqual(model.progressText, "正在整理事件")
        XCTAssertEqual(model.activeMailboxCount, 2)
        XCTAssertEqual(model.sortedMailbox.map(\.id), ["mail-unread-new", "mail-unread-old", "mail-archived-new"])
        XCTAssertEqual(model.sortedEvents.map(\.id), ["event-new", "event-old"])
    }

    func testSessionOperatorStateDistinguishesActiveQueuedAndObservableSessions() {
        let active = CrewSession(
            id: "session-active",
            crewConversationId: "crew-1",
            responsibleSubjectId: "subject-1",
            runnerKind: "local_codex",
            status: "running",
            taskBrief: "本机正在执行",
            progressSummary: nil,
            createdAt: "2026-05-27T00:00:00Z",
            startedAt: "2026-05-27T00:02:00Z",
            finishedAt: nil
        )
        let queued = CrewSession(
            id: "session-queued",
            crewConversationId: "crew-1",
            responsibleSubjectId: "subject-1",
            runnerKind: "local_codex",
            status: "queued",
            taskBrief: "等待认领",
            progressSummary: nil,
            createdAt: "2026-05-27T00:01:00Z",
            startedAt: nil,
            finishedAt: nil
        )
        let observable = CrewSession(
            id: "session-observable",
            crewConversationId: "crew-1",
            responsibleSubjectId: "subject-1",
            runnerKind: "cloud_sandbox",
            status: "running",
            taskBrief: "只能观察",
            progressSummary: nil,
            createdAt: "2026-05-27T00:03:00Z",
            startedAt: "2026-05-27T00:04:00Z",
            finishedAt: nil
        )

        let activeState = SessionOperatorState(session: active, activeRunnerSessionId: "session-active")
        let queuedState = SessionOperatorState(session: queued, activeRunnerSessionId: "session-active")
        let observableState = SessionOperatorState(session: observable, activeRunnerSessionId: "session-active")

        XCTAssertEqual(activeState.mode, .activeLocalRunner)
        XCTAssertTrue(activeState.canReportProgress)
        XCTAssertTrue(activeState.canFinish)
        XCTAssertEqual(queuedState.mode, .queuedClaimable)
        XCTAssertFalse(queuedState.canReportProgress)
        XCTAssertFalse(queuedState.canFinish)
        XCTAssertEqual(observableState.mode, .observable)
        XCTAssertFalse(observableState.canReportProgress)
        XCTAssertFalse(observableState.canFinish)
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
