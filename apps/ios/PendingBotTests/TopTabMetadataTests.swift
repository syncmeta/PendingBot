import XCTest
@testable import PendingBot

final class TopTabMetadataTests: XCTestCase {
    func testTopTabOrderLabelsAndIconsMatchRootNavigation() {
        let tabs = TopTab.allCases

        XCTAssertEqual(tabs, [.message, .friends, .crew, .envelope, .me])
        XCTAssertEqual(tabs.map(\.label), ["消息", "好友", "机组", "来信", "我"])
        XCTAssertEqual(tabs.map(\.systemImage), [
            "bubble.left",
            "person.2",
            "command",
            "envelope.open",
            "person.crop.circle",
        ])
    }
}
