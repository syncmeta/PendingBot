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
}
