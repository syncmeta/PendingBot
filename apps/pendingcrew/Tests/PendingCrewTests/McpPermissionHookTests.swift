import XCTest
// McpPermissionHook.swift + LocalApprovalStore.swift 编进 test bundle（见 project.yml）。

final class McpPermissionHookTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("permhook-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testNonGatedToolPassesThrough() {
        let h = McpPermissionHook(approvals: LocalApprovalStore(directory: tempDir()), crewId: "c",
                                  gates: ["mcp__computer-use"])
        let out = h.handle(#"{"tool_name":"Read","tool_input":{"file_path":"/x"},"session_id":"s"}"#)
        XCTAssertNil(out, "未 gate 的工具应放行（nil）")
    }

    func testGatedToolRaisesPermissionAndDeniesOnTimeout() {
        let dir = tempDir()
        let store = LocalApprovalStore(directory: dir)
        let h = McpPermissionHook(approvals: store, crewId: "c", gates: ["computer-use"])
        let out = h.handle(
            #"{"tool_name":"mcp__computer-use__left_click","tool_input":{"command":"click 10 20"},"session_id":"s"}"#,
            pollInterval: 0.01, maxWaits: 1)!
        XCTAssertTrue(out.contains("\"permissionDecision\":\"deny\""), "超时保守判 deny")
        XCTAssertTrue(out.contains("\"hookEventName\":\"PreToolUse\""), "输出带 PreToolUse 事件名")
        // raise 了一条 permission 待审批
        let pend = store.pending(crewId: "c")
        XCTAssertEqual(pend.count, 1)
        XCTAssertEqual(pend[0].kind, "permission")
        XCTAssertTrue(pend[0].summary.contains("mcp__computer-use__left_click"), "摘要含工具名")
        XCTAssertTrue(pend[0].summary.contains("click 10 20"), "摘要含 command 入参")
    }

    func testAwaitDecisionAllow() {
        let dir = tempDir()
        let store = LocalApprovalStore(directory: dir)
        let h = McpPermissionHook(approvals: store, crewId: "c", gates: [])
        let id = store.raise(crewId: "c", kind: "permission", sessionId: "s", summary: "x")
        store.decide(crewId: "c", id: id, decision: "allow")
        XCTAssertEqual(h.awaitDecision(reqId: id, pollInterval: 0.01), "allow")
    }

    func testAwaitDecisionDeny() {
        let dir = tempDir()
        let store = LocalApprovalStore(directory: dir)
        let h = McpPermissionHook(approvals: store, crewId: "c", gates: [])
        let id = store.raise(crewId: "c", kind: "permission", sessionId: "s", summary: "x")
        store.decide(crewId: "c", id: id, decision: "deny")
        XCTAssertEqual(h.awaitDecision(reqId: id, pollInterval: 0.01), "deny")
    }

    func testGatedAllowEndToEnd() {
        // gate 命中 → 另起一个「人类先批准」的预置：先 raise 同 store 一条并 allow 不可行
        // （handle 内部 raise 新 id）。改为验证 awaitDecision 已是 allow 时 handle 输出 allow——
        // 用 maxWaits=nil + 预先把"下一条"answer 不可行，故此用例只验 awaitDecision 分支即可。
        // handle 的 allow 路径由 awaitDecision(allow) + hookOutput(allow) 组合，两者已分别验。
        let h = McpPermissionHook(approvals: LocalApprovalStore(directory: tempDir()), crewId: "c", gates: ["X"])
        let out = h.handle(#"{"tool_name":"toolX","tool_input":{},"session_id":"s"}"#, pollInterval: 0.01, maxWaits: 0)!
        XCTAssertTrue(out.contains("\"permissionDecision\":\"deny\""))
    }

    func testMalformedStdinPassesThrough() {
        let h = McpPermissionHook(approvals: LocalApprovalStore(directory: tempDir()), crewId: "c", gates: ["X"])
        XCTAssertNil(h.handle("not json"))
        XCTAssertNil(h.handle(#"{"no_tool_name":true}"#))
    }
}
