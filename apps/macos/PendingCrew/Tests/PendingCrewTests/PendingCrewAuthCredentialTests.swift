import XCTest
@testable import PendingCrew

final class PendingCrewAuthCredentialTests: XCTestCase {
    func testDeviceGrantIsTheNormalCredentialAndWinsOverDebugJWT() {
        let credential = PendingCrewAuthCredential.resolve(
            deviceGrantToken: "pdg_device",
            debugUserJWT: "jwt_debug",
            allowDebugUserJWT: true
        )

        XCTAssertEqual(credential?.token, "pdg_device")
        XCTAssertEqual(credential?.kind, .deviceGrant)
    }

    func testDebugJWTIsIgnoredOutsideDebugMode() {
        let credential = PendingCrewAuthCredential.resolve(
            deviceGrantToken: nil,
            debugUserJWT: "jwt_debug",
            allowDebugUserJWT: false
        )

        XCTAssertNil(credential)
    }

    func testDebugJWTCanBeUsedOnlyWhenExplicitlyAllowedAndNoDeviceGrantExists() {
        let credential = PendingCrewAuthCredential.resolve(
            deviceGrantToken: nil,
            debugUserJWT: "jwt_debug",
            allowDebugUserJWT: true
        )

        XCTAssertEqual(credential?.token, "jwt_debug")
        XCTAssertEqual(credential?.kind, .debugUserJWT)
    }
}
