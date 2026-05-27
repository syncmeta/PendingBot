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

    func testDeviceLoginGrantFallbackRetriesPendingBotClientOnKindMismatch() {
        XCTAssertEqual(
            DeviceLoginGrantApproval.retryPlan(after: APIError.http(
                status: 400,
                code: "invalid_body",
                message: "grant kind does not match app kind",
                body: ""
            )),
            .pendingBotClient
        )

        XCTAssertEqual(
            DeviceLoginGrantApproval.retryPlan(after: APIError.http(
                status: 400,
                code: "invalid_body",
                message: "requested scopes exceed grant kind",
                body: ""
            )),
            .pendingBotClient
        )

        XCTAssertNil(DeviceLoginGrantApproval.retryPlan(after: APIError.http(
            status: 403,
            code: "forbidden",
            message: "forbidden",
            body: ""
        )))
    }

    func testDeviceLoginLinkParsesAppKindHint() {
        XCTAssertEqual(
            DeviceLoginLink.parse("https://bot.pendingname.com/d/challenge-1?s=secret-1&k=pendingbot_macos"),
            DeviceLoginLink.Payload(
                challengeId: "challenge-1",
                secret: "secret-1",
                appKind: .pendingBotMacOS
            )
        )

        XCTAssertEqual(
            DeviceLoginLink.parse("https://bot.pendingname.com/d/challenge-2?s=secret-2")?.appKind,
            nil
        )
    }
}
