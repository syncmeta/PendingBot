import XCTest
// McpServer.swift + LocalWhiteboardStore.swift + LocalApprovalStore.swift 编进 test
// bundle（见 project.yml）；main / McpHelperMain 顶层不进 bundle。

final class McpServerTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func server(_ dir: URL, isCaptain: Bool = false) -> McpServer {
        McpServer(store: LocalWhiteboardStore(directory: dir),
                  approvals: LocalApprovalStore(directory: dir),
                  control: LocalCrewControlStore(directory: dir),
                  crewId: "c", sessionId: "sess-1", isCaptain: isCaptain)
    }
    private func callRenameCrew(_ s: McpServer, name: String) -> String {
        s.handleLine("""
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rename_crew","arguments":{"name":"\(name)"}}}
        """) ?? ""
    }
    private func callAnswerDecision(_ s: McpServer, reqId: String, reply: String) -> String {
        s.handleLine("""
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"answer_decision","arguments":{"reqId":"\(reqId)","reply":"\(reply)"}}}
        """) ?? ""
    }

    func testInitializeReturnsCapabilities() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.contains("\"protocolVersion\""))
        XCTAssertTrue(r!.contains("pendingcrew"))
    }

    func testToolsListHasPostReadAsk() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        XCTAssertTrue(r.contains("post_to_crew"))
        XCTAssertTrue(r.contains("read_whiteboard"))
        XCTAssertTrue(r.contains("\"ask\""))
    }

    func testPostToCrewWritesWhiteboard() {
        let s = server(tempDir())
        _ = s.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"post_to_crew","arguments":{"message":"hi crew","category":"progress"}}}"#)
        let msgs = s.store.list(crewId: "c")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].text, "hi crew")
        XCTAssertEqual(msgs[0].senderKind, "session")
        XCTAssertEqual(msgs[0].senderSessionId, "sess-1")
        XCTAssertEqual(msgs[0].category, "progress")
    }

    // Phase 7：post_to_crew schema 暴露 mentions + reply_to。
    func testToolsListPostToCrewHasMentionsAndReplyTo() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        XCTAssertTrue(r.contains("mentions"))
        XCTAssertTrue(r.contains("reply_to"))
    }

    // Phase 7：带 mentions + reply_to → 不报错,且两者被记进本地白板(不静默吞)。
    func testPostToCrewPreservesMentionsAndReplyTo() {
        let s = server(tempDir())
        let r = s.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"post_to_crew","arguments":{"message":"交给你了","mentions":[{"kind":"session","target_id":"sess-2"},{"kind":"captain"}],"reply_to":"msg-orig"}}}"#)!
        XCTAssertFalse(r.contains("ERROR"))
        let msgs = s.store.list(crewId: "c")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].text, "交给你了")
        XCTAssertEqual(msgs[0].inReplyTo, "msg-orig")
        XCTAssertEqual(msgs[0].mentions?.count, 2)
        XCTAssertEqual(msgs[0].mentions?[0].kind, "session")
        XCTAssertEqual(msgs[0].mentions?[0].targetId, "sess-2")
        XCTAssertEqual(msgs[0].mentions?[1].kind, "captain")
        XCTAssertNil(msgs[0].mentions?[1].targetId)
    }

    // Phase 7：不带 mentions/reply_to 的发送仍是广播(两字段保持 nil),且坏 mention
    // (缺 kind)被丢弃而非吞掉整条。
    func testPostToCrewBroadcastLeavesMentionsNil() {
        let s = server(tempDir())
        _ = s.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"post_to_crew","arguments":{"message":"广播一下","mentions":[{"target_id":"oops"}]}}}"#)
        let msgs = s.store.list(crewId: "c")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertNil(msgs[0].mentions)   // 唯一一条坏 mention 被丢 → 空 → nil
        XCTAssertNil(msgs[0].inReplyTo)
    }

    func testPostToCrewEmptyMessageRejected() {
        let s = server(tempDir())
        let r = s.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"post_to_crew","arguments":{"message":"   "}}}"#)!
        XCTAssertTrue(r.contains("ERROR"))
        XCTAssertTrue(s.store.list(crewId: "c").isEmpty)
    }

    func testReadWhiteboardReturnsEntries() {
        let s = server(tempDir())
        s.store.appendUserMessage(crewId: "c", text: "人类说嗨")
        let r = s.handleLine(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_whiteboard","arguments":{}}}"#)!
        XCTAssertTrue(r.contains("人类说嗨"))
    }

    func testUnknownToolReturnsError() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#)!
        XCTAssertTrue(r.contains("ERROR"))
    }

    func testNotificationInitializedNoResponse() {
        XCTAssertNil(server(tempDir()).handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testUnknownMethodWithIdReturnsError() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":9,"method":"bogus/method"}"#)!
        XCTAssertTrue(r.contains("-32601"))
    }

    func testGarbageLineReturnsNil() {
        XCTAssertNil(server(tempDir()).handleLine("not json"))
        XCTAssertNil(server(tempDir()).handleLine(""))
    }

    // MARK: - ask（待决策 raise + long-poll 答复）

    func testAskEmptyQuestionRejected() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ask","arguments":{"question":"  "}}}"#)!
        XCTAssertTrue(r.contains("ERROR"))
    }

    func testAwaitReplyReturnsAnswerOnFirstPoll() {
        let s = server(tempDir())
        let id = s.approvals.raise(crewId: "c", kind: "decision", sessionId: "sess-1", summary: "q")
        s.approvals.answer(crewId: "c", id: id, reply: "选 A")
        XCTAssertEqual(s.awaitReply(reqId: id, pollInterval: 0.01), "选 A")
    }

    func testAwaitReplyTimeoutText() {
        let s = server(tempDir())
        let id = s.approvals.raise(crewId: "c", kind: "decision", sessionId: "sess-1", summary: "q")
        XCTAssertTrue(s.awaitReply(reqId: id, pollInterval: 0.01, maxWaits: 2).contains("自行判断"))
    }

    // ask 在 raise 后把问题贴到本地白板（spec §6 通知半边），答复仍走待办列表。
    func testAskPostsWhiteboardNotificationAndReturnsReply() {
        let s = server(tempDir())
        DispatchQueue.global().async {   // 后台答复，解 ask 的阻塞 long-poll
            for _ in 0..<500 {
                if let it = s.approvals.pending(crewId: "c").first {
                    s.approvals.answer(crewId: "c", id: it.id, reply: "选 A"); break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        let r = s.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ask","arguments":{"question":"选 A 还是 B?"}}}"#)
        XCTAssertTrue(r?.contains("选 A") ?? false, "ask 应拿到答复返回")
        XCTAssertTrue(s.store.list(crewId: "c").contains { $0.text.contains("🔔 待决策") && $0.text.contains("选 A 还是 B?") },
                      "ask 应往白板贴一条待决策通知")
    }

    // MARK: - answer_decision（机长专用，chunk2 T4）

    func testNonCaptainToolsListLacksAnswerDecision() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        XCTAssertFalse(r.contains("answer_decision"))
    }

    func testCaptainToolsListHasAnswerDecision() {
        let r = server(tempDir(), isCaptain: true).handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        XCTAssertTrue(r.contains("answer_decision"))
    }

    func testNonCaptainAnswerDecisionRejected() {
        let s = server(tempDir())
        let id = s.approvals.raise(crewId: "c", kind: "decision", sessionId: "w", summary: "q")
        XCTAssertTrue(callAnswerDecision(s, reqId: id, reply: "选 A").contains("仅机长可用"))
        XCTAssertEqual(s.approvals.item(crewId: "c", id: id)?.status, "pending")
    }

    func testCaptainAnswerDecisionAnswersAndUnblocksAsk() {
        let s = server(tempDir(), isCaptain: true)
        let id = s.approvals.raise(crewId: "c", kind: "decision", sessionId: "w", summary: "选 A 还是 B?")
        let r = callAnswerDecision(s, reqId: id, reply: "选 A")
        XCTAssertTrue(r.contains("已答复"))
        let item = s.approvals.item(crewId: "c", id: id)
        XCTAssertEqual(item?.status, "answered")
        XCTAssertEqual(item?.reply, "选 A")
        // 发起方 ask 的 long-poll（已预先答复）立刻拿到答复
        XCTAssertEqual(s.awaitReply(reqId: id, pollInterval: 0.01), "选 A")
    }

    func testAnswerDecisionWrongReqId() {
        let s = server(tempDir(), isCaptain: true)
        XCTAssertTrue(callAnswerDecision(s, reqId: "nope", reply: "x").contains("找不到待决策"))
    }

    func testAnswerDecisionAlreadyAnswered() {
        let s = server(tempDir(), isCaptain: true)
        let id = s.approvals.raise(crewId: "c", kind: "decision", sessionId: "w", summary: "q")
        s.approvals.answer(crewId: "c", id: id, reply: "first")
        XCTAssertTrue(callAnswerDecision(s, reqId: id, reply: "second").contains("已被答复"))
        XCTAssertEqual(s.approvals.item(crewId: "c", id: id)?.reply, "first")
    }

    func testAnswerDecisionPermissionKindRejected() {
        let s = server(tempDir(), isCaptain: true)
        let id = s.approvals.raise(crewId: "c", kind: "permission", sessionId: "w", summary: "rm?")
        XCTAssertTrue(callAnswerDecision(s, reqId: id, reply: "allow").contains("不是待决策"))
        XCTAssertEqual(s.approvals.item(crewId: "c", id: id)?.status, "pending")
    }

    func testAnswerDecisionEmptyReplyRejected() {
        let s = server(tempDir(), isCaptain: true)
        let id = s.approvals.raise(crewId: "c", kind: "decision", sessionId: "w", summary: "q")
        XCTAssertTrue(callAnswerDecision(s, reqId: id, reply: "  ").contains("reply 不能为空"))
    }

    // MARK: - rename_crew（机长专用，crew-naming）

    func testNonCaptainToolsListLacksRenameCrew() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        XCTAssertFalse(r.contains("rename_crew"))
    }

    func testCaptainToolsListHasRenameCrew() {
        let r = server(tempDir(), isCaptain: true).handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        XCTAssertTrue(r.contains("rename_crew"))
    }

    func testNonCaptainRenameCrewRejected() {
        let s = server(tempDir())
        XCTAssertTrue(callRenameCrew(s, name: "鉴权重构").contains("仅机长可用"))
        XCTAssertNil(s.control.pendingRename(crewId: "c"))
    }

    func testCaptainRenameCrewWritesControl() {
        let s = server(tempDir(), isCaptain: true)
        let r = callRenameCrew(s, name: "鉴权重构")
        XCTAssertTrue(r.contains("已把 crew 改名为「鉴权重构」"))
        XCTAssertEqual(s.control.pendingRename(crewId: "c"), "鉴权重构")
    }

    func testRenameCrewEmptyRejected() {
        let s = server(tempDir(), isCaptain: true)
        XCTAssertTrue(callRenameCrew(s, name: "   ").contains("name 不能为空"))
        XCTAssertNil(s.control.pendingRename(crewId: "c"))
    }

    // 名字收成单行标签：换行/多空白 → 单空格。
    func testRenameCrewCollapsesWhitespace() {
        let s = server(tempDir(), isCaptain: true)
        _ = callRenameCrew(s, name: "鉴权   重构")
        XCTAssertEqual(s.control.pendingRename(crewId: "c"), "鉴权 重构")
    }

    // MARK: - raise_attention / clear_attention（机长专用，crew-sidebar-status）

    private func callTool(_ s: McpServer, name: String, argsJSON: String = "{}") -> String {
        s.handleLine("""
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\(name)","arguments":\(argsJSON)}}
        """) ?? ""
    }

    func testNonCaptainToolsListLacksAttentionTools() {
        let r = server(tempDir()).handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        XCTAssertFalse(r.contains("raise_attention"))
        XCTAssertFalse(r.contains("clear_attention"))
    }

    func testCaptainToolsListHasAttentionTools() {
        let r = server(tempDir(), isCaptain: true).handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        XCTAssertTrue(r.contains("raise_attention"))
        XCTAssertTrue(r.contains("clear_attention"))
    }

    func testNonCaptainRaiseAttentionRejected() {
        let s = server(tempDir())
        XCTAssertTrue(callTool(s, name: "raise_attention", argsJSON: #"{"reason":"要人看"}"#).contains("仅机长可用"))
        XCTAssertNil(s.control.pendingAttention(crewId: "c"))
    }

    func testNonCaptainClearAttentionRejected() {
        let s = server(tempDir())
        XCTAssertTrue(callTool(s, name: "clear_attention").contains("仅机长可用"))
        XCTAssertNil(s.control.pendingAttention(crewId: "c"))
    }

    func testCaptainRaiseAttentionWritesControl() {
        let s = server(tempDir(), isCaptain: true)
        let r = callTool(s, name: "raise_attention", argsJSON: #"{"reason":"需要人类拍板部署时机"}"#)
        XCTAssertTrue(r.contains("已点亮"))
        XCTAssertEqual(s.control.pendingAttention(crewId: "c")?.reason, "需要人类拍板部署时机")
    }

    func testRaiseAttentionEmptyReasonRejected() {
        let s = server(tempDir(), isCaptain: true)
        XCTAssertTrue(callTool(s, name: "raise_attention", argsJSON: #"{"reason":"   "}"#).contains("reason 不能为空"))
        XCTAssertNil(s.control.pendingAttention(crewId: "c"))
    }

    func testCaptainClearAttentionWritesControl() {
        let s = server(tempDir(), isCaptain: true)
        _ = callTool(s, name: "raise_attention", argsJSON: #"{"reason":"有问题"}"#)
        let r = callTool(s, name: "clear_attention")
        XCTAssertTrue(r.contains("已熄灭"))
        // last-write-wins：留下的是熄灭态（reason nil）。
        let pending = s.control.pendingAttention(crewId: "c")
        XCTAssertNotNil(pending)
        XCTAssertNil(pending?.reason)
    }
}
