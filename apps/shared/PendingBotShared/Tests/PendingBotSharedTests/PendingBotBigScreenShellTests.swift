import XCTest
@testable import PendingBotShared

final class PendingBotBigScreenShellTests: XCTestCase {
    func testDefaultBigScreenTabsKeepPendingBotOrder() {
        XCTAssertEqual(
            PendingBotBigScreenTab.allCases.map(\.title),
            ["消息", "好友", "机组", "来信", "我"]
        )
        XCTAssertEqual(PendingBotBigScreenTab.crew.systemImage, "person.3.sequence")
    }

    func testCrewSidebarRowsSortByRecentUpdateAndShowRuntime() {
        let older = PendingBotCrewSummary(
            id: "crew-older",
            title: "平台机组",
            status: "active",
            runtimeKind: .local,
            updatedAt: "2026-05-27T08:00:00Z"
        )
        let newer = PendingBotCrewSummary(
            id: "crew-newer",
            title: "移动机组",
            status: "active",
            runtimeKind: .reservedCloud,
            updatedAt: "2026-05-27T09:00:00Z"
        )

        let rows = PendingBotCrewSidebarRow.rows(for: [older, newer])

        XCTAssertEqual(rows.map(\.id), ["crew-newer", "crew-older"])
        XCTAssertEqual(rows.map(\.subtitle), ["云端预留 · active", "本地 · active"])
    }

    func testCrewRelationshipRowsGroupParentsBeforeChildren() {
        let parent = PendingBotCrewLink(
            crewId: "parent",
            title: "父机组",
            status: "active",
            runtimeKind: .local,
            captainBotId: nil,
            captainMemberId: nil,
            createdAt: "2026-05-27T09:00:00Z"
        )
        let child = PendingBotCrewLink(
            crewId: "child",
            title: "子机组",
            status: "active",
            runtimeKind: .reservedCloud,
            captainBotId: nil,
            captainMemberId: nil,
            createdAt: "2026-05-27T09:05:00Z"
        )
        let detail = PendingBotCrewDetail(
            crewId: "crew",
            parents: [parent],
            children: [child],
            responsibilityShares: [],
            sessions: [],
            members: [],
            announcements: []
        )

        let rows = PendingBotCrewRelationshipRow.rows(for: detail)

        XCTAssertEqual(rows.map(\.id), ["parent:parent", "child:child"])
        XCTAssertEqual(rows.map(\.subtitle), ["上级 · 本地 · active", "下级 · 云端预留 · active"])
    }

    func testResponsibilityShareFormatsBasisPointsAsPercent() {
        let share = PendingBotCrewResponsibilityShare(
            subjectId: "subject-1",
            shareBps: 1250,
            source: "direct"
        )

        XCTAssertEqual(share.percentText, "12.5%")
    }

    func testCrewDetailSortsSessionsAndAnnouncementsForDisplay() {
        let oldSession = PendingBotCrewSession(
            id: "session-old",
            crewId: "crew",
            responsibleSubjectId: "subject",
            runnerKind: .localCodex,
            status: "open",
            taskBrief: "Old",
            progressSummary: nil,
            createdAt: "2026-05-27T08:00:00Z",
            startedAt: nil,
            finishedAt: nil
        )
        let newSession = PendingBotCrewSession(
            id: "session-new",
            crewId: "crew",
            responsibleSubjectId: "subject",
            runnerKind: .localCodex,
            status: "open",
            taskBrief: "New",
            progressSummary: nil,
            createdAt: "2026-05-27T09:00:00Z",
            startedAt: nil,
            finishedAt: nil
        )
        let oldAnnouncement = PendingBotCrewAnnouncement(
            id: "announcement-old",
            crewId: "crew",
            responsibleSubjectId: "subject",
            senderKind: "user",
            senderMemberId: nil,
            senderSessionId: nil,
            recipientMode: "broadcast",
            messageKind: "announcement",
            boardVisible: true,
            summary: "Old",
            createdAt: "2026-05-27T08:00:00Z",
            mentions: []
        )
        let newAnnouncement = PendingBotCrewAnnouncement(
            id: "announcement-new",
            crewId: "crew",
            responsibleSubjectId: "subject",
            senderKind: "user",
            senderMemberId: nil,
            senderSessionId: nil,
            recipientMode: "broadcast",
            messageKind: "announcement",
            boardVisible: true,
            summary: "New",
            createdAt: "2026-05-27T09:00:00Z",
            mentions: []
        )
        let detail = PendingBotCrewDetail(
            crewId: "crew",
            parents: [],
            children: [],
            responsibilityShares: [],
            sessions: [oldSession, newSession],
            members: [],
            announcements: [newAnnouncement, oldAnnouncement]
        )

        XCTAssertEqual(detail.displaySessions.map(\.id), ["session-new", "session-old"])
        XCTAssertEqual(detail.displayAnnouncements.map(\.id), ["announcement-old", "announcement-new"])
    }
}
