import XCTest

/// `CrewStore` 依赖 `AppModel`（未编进 test bundle，见 project.yml 注释），
/// 所以纯逻辑摘到 `CrewChildDepthPolicy`（Sources/Support，自包含）单测；
/// `CrewStore.shouldRejectChild` 是薄包装，行为与这里断言的一致。
final class CrewStoreChildDepthTests: XCTestCase {
    func testDepthCapBoundary() {
        XCTAssertFalse(CrewChildDepthPolicy.shouldReject(depthOfParent: 0)) // 建成 depth1
        XCTAssertFalse(CrewChildDepthPolicy.shouldReject(depthOfParent: 2)) // 建成 depth3，允许
        XCTAssertTrue(CrewChildDepthPolicy.shouldReject(depthOfParent: 3))  // 会成 depth4，拒
    }
}
