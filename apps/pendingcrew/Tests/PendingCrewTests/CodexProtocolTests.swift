import XCTest


final class CodexProtocolTests: XCTestCase {
    func testInitializeParamsCarryClientInfoAndExperimentalApi() {
        let p = CodexProtocol.initializeParams(clientName: "PendingCrew", version: "1.0")
        let info = p["clientInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "PendingCrew")
        XCTAssertEqual(info?["version"] as? String, "1.0")
        let caps = p["capabilities"] as? [String: Any]
        XCTAssertEqual(caps?["experimentalApi"] as? Bool, true)
        XCTAssertNotNil(caps?["optOutNotificationMethods"], "v1 should opt out of streaming deltas")
    }
    func testThreadStartRegistersMcpUnderConfigNotTopLevel() {
        // codex `thread/start` has NO top-level `mcpServers` field — MCP registers via
        // `config.mcp_servers` (real-schema verified). Guards against the silent-drop regression.
        let p = CodexProtocol.threadStartParams(cwd: "/repo", model: "gpt-5.5",
            developerInstructions: "world-model",
            mcpServers: ["crew": ["command": "/bin/helper", "args": ["--mcp-serve"]]])
        XCTAssertEqual(p["cwd"] as? String, "/repo")
        XCTAssertEqual(p["model"] as? String, "gpt-5.5")
        XCTAssertEqual(p["developerInstructions"] as? String, "world-model")
        XCTAssertEqual(p["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(p["sandbox"] as? String, "workspace-write")
        XCTAssertEqual(p["approvalsReviewer"] as? String, "user")
        XCTAssertNil(p["mcpServers"], "must NOT use the bogus top-level field codex drops")
        let mcp = (p["config"] as? [String: Any])?["mcp_servers"] as? [String: Any]
        let crew = mcp?["crew"] as? [String: Any]
        XCTAssertEqual(crew?["command"] as? String, "/bin/helper")
        XCTAssertEqual(crew?["args"] as? [String], ["--mcp-serve"])
    }
    func testThreadStartOmitsEmptyOptionals() {
        let p = CodexProtocol.threadStartParams(cwd: "/repo", model: nil, developerInstructions: "", mcpServers: nil)
        XCTAssertNil(p["model"]); XCTAssertNil(p["developerInstructions"]); XCTAssertNil(p["config"])
        XCTAssertEqual(p["approvalPolicy"] as? String, "on-request")   // policy always present
    }
    func testTurnStartPrependsWhiteboardAsLeadingTextInput() {
        // codex has no `additionalContext` field — the whiteboard rides as a leading
        // text input item, ahead of the user's text (real-schema verified).
        let p = CodexProtocol.turnStartParams(threadId: "thr_1", text: "go", whiteboard: "unread:1")
        XCTAssertEqual(p["threadId"] as? String, "thr_1")
        XCTAssertNil(p["additionalContext"], "codex turn/start has no additionalContext field")
        let input = p["input"] as? [[String: Any]]
        XCTAssertEqual(input?.count, 2)
        XCTAssertEqual(input?.first?["type"] as? String, "text")
        XCTAssertEqual(input?.first?["text"] as? String, "unread:1")   // whiteboard first
        XCTAssertEqual(input?.last?["text"] as? String, "go")          // user text last
    }
    func testTurnStartIsSingleTextInputWhenNoWhiteboard() {
        for wb in [nil, ""] as [String?] {
            let p = CodexProtocol.turnStartParams(threadId: "t", text: "go", whiteboard: wb)
            XCTAssertNil(p["additionalContext"])
            let input = p["input"] as? [[String: Any]]
            XCTAssertEqual(input?.count, 1)
            XCTAssertEqual(input?.first?["text"] as? String, "go")
        }
    }
    func testTurnInterruptParams() {
        let p = CodexProtocol.turnInterruptParams(threadId: "thr_1", turnId: "turn_9")
        XCTAssertEqual(p["threadId"] as? String, "thr_1")
        XCTAssertEqual(p["turnId"] as? String, "turn_9")
    }

    // MARK: - Server-request handling (codex → client) — every kind must be answerable.
    // Guards the codex hang: silently dropping any server-request blocks the turn forever.

    func testServerRequestKindClassifiesEveryRealMethod() {
        // Real `ServerRequest` enum, codex-cli 0.137.0 generate-json-schema.
        XCTAssertEqual(CodexProtocol.serverRequestKind(method: "item/commandExecution/requestApproval"), .approval)
        XCTAssertEqual(CodexProtocol.serverRequestKind(method: "item/fileChange/requestApproval"), .approval)
        XCTAssertEqual(CodexProtocol.serverRequestKind(method: "item/permissions/requestApproval"), .approval)
        XCTAssertEqual(CodexProtocol.serverRequestKind(method: "mcpServer/elicitation/request"), .elicitation)
        // Everything we don't model → unsupported, but STILL answered (with an error), never dropped.
        XCTAssertEqual(CodexProtocol.serverRequestKind(method: "item/tool/requestUserInput"), .unsupported)
        XCTAssertEqual(CodexProtocol.serverRequestKind(method: "item/tool/call"), .unsupported)
        XCTAssertEqual(CodexProtocol.serverRequestKind(method: "account/chatgptAuthTokens/refresh"), .unsupported)
        XCTAssertEqual(CodexProtocol.serverRequestKind(method: "attestation/generate"), .unsupported)
    }

    func testElicitationDeclineResultMatchesRealSchema() {
        // McpServerElicitationRequestResponse = { action: accept|decline|cancel, content? };
        // decline carries no content. v1 declines so the turn never blocks on us.
        let r = CodexProtocol.elicitationDeclineResult()
        XCTAssertEqual(r["action"] as? String, "decline")
        XCTAssertNil(r["content"], "decline carries no content")
    }

    func testElicitationResultAcceptsMcpToolCallApproval() {
        // codex 0.137.0 delivers the MCP tool-call approval AS an elicitation carrying
        // _meta.codex_approval_kind == "mcp_tool_call". Auto-accept it — crew tools are
        // trusted; declining it is what rejected the captain's post_to_crew check-in.
        let params: [String: Any] = [
            "serverName": "crew",
            "message": "Allow the crew MCP server to run tool \"post_to_crew\"?",
            "_meta": ["codex_approval_kind": "mcp_tool_call", "tool_description": "post to crew whiteboard"],
        ]
        let r = CodexProtocol.elicitationResult(params: params)
        XCTAssertEqual(r["action"] as? String, "accept")
    }

    func testElicitationResultDeclinesGenuineInputForm() {
        // A real MCP elicitation (no codex_approval_kind) has no v1 UI → decline so the
        // turn proceeds instead of hanging; we never blanket-accept and submit empty input.
        let params: [String: Any] = [
            "serverName": "crew",
            "message": "What is your name?",
            "requestedSchema": ["type": "object", "properties": ["name": ["type": "string"]]],
        ]
        let r = CodexProtocol.elicitationResult(params: params)
        XCTAssertEqual(r["action"] as? String, "decline")
    }
}
