import XCTest

final class PendingCrewUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsDisconnectedCrewWorkspace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--pendingcrew-ui-test"]
        app.launch()

        XCTAssertTrue(app.windows.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["未连接账号"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["创建机组"].exists)
        XCTAssertTrue(app.staticTexts["有求于你"].exists)
    }
}
