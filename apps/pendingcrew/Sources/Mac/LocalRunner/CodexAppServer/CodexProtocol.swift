#if os(macOS)
import Foundation

/// Param builders for the core-loop methods. Plain dictionaries (paired with
/// CodexRPCMessage encoding) keep this Foundation-only + unit-testable.
enum CodexProtocol {
    static func initializeParams(clientName: String, version: String) -> [String: Any] {
        // Shapes reconciled against `codex app-server generate-json-schema` (codex-cli 0.137.0):
        // ClientInfo = {name, title?, version}; InitializeCapabilities = {experimentalApi,
        // requestAttestation, optOutNotificationMethods?}. `requestAttestation` is non-optional in
        // the schema (we don't want upstream attestation → false). `item/agentMessage/delta` is a
        // real ServerNotification method, so opting out of it actually suppresses the delta stream
        // (v1 renders on `item/completed` only).
        ["clientInfo": ["name": clientName, "title": clientName, "version": version],
         "capabilities": [
             "experimentalApi": true,
             "requestAttestation": false,
             "optOutNotificationMethods": ["item/agentMessage/delta"],
         ]]
    }
    /// MCP servers register through codex's per-thread `config` override —
    /// `config.mcp_servers.<name> = { command, args, env? }` (the structured form of
    /// `-c mcp_servers.<name>...` / the `[mcp_servers.*]` config.toml table). There is
    /// **no** top-level `mcpServers` field on `thread/start`; codex silently drops
    /// unknown keys, so the old shape registered nothing and the session got zero crew
    /// tools. Verified against `codex app-server generate-json-schema` + `codex mcp add`
    /// (codex-cli 0.137.0).
    static func threadStartParams(cwd: String, model: String?, developerInstructions: String?,
                                  mcpServers: [String: Any]?) -> [String: Any] {
        var p: [String: Any] = [
            "cwd": cwd,
            "approvalPolicy": "on-request",
            "sandbox": "workspace-write",
            "approvalsReviewer": "user",
        ]
        if let model, !model.isEmpty { p["model"] = model }
        if let di = developerInstructions, !di.isEmpty { p["developerInstructions"] = di }
        if let mcp = mcpServers, !mcp.isEmpty { p["config"] = ["mcp_servers": mcp] }
        return p
    }
    /// The unread crew whiteboard rides in via **`turn/start.additionalContext`** —
    /// codex's native per-turn context channel. The field IS in the v2 schema, gated
    /// behind `#[experimental("turn/start.additionalContext")]`, which we unlock via
    /// `initialize.capabilities.experimentalApi:true` (see initializeParams). codex
    /// core dedupes by key (`AdditionalContextStore::merge` only emits a fragment when
    /// a key's value changed → a turn with no new whiteboard injects NOTHING, zero
    /// prefix churn) and renders `kind:"untrusted"` as a `role:"user"` fragment wrapped
    /// in `<external_<key>>…</external_<key>>` — injection hygiene: a teammate's message
    /// is DATA, never instructions to this agent. The user's own text stays the sole
    /// `input[]` item.
    ///
    /// History: a prior impl prepended the whiteboard as a leading `text` input item
    /// after wrongly judging the schema as lacking this field. The mistake was a
    /// name-collision — `makeWhiteboardProvider` reuses claude's `HookEmitter`, whose
    /// envelope key is *also* `additionalContext` (a plain string), and that got
    /// conflated with codex's `additionalContext` (a `{key:{value,kind}}` map). Same
    /// name, different protocol. (⚠️ needs a live codex run to confirm the field is
    /// honored — schema-shape only so far; see docs/tech-debt.md.)
    static func turnStartParams(threadId: String, text: String, whiteboard: String?) -> [String: Any] {
        var p: [String: Any] = [
            "threadId": threadId,
            "input": [["type": "text", "text": text, "text_elements": []]],
        ]
        if let wb = whiteboard, !wb.isEmpty {
            p["additionalContext"] = ["crew_whiteboard": ["value": wb, "kind": "untrusted"]]
        }
        return p
    }
    static func turnInterruptParams(threadId: String, turnId: String) -> [String: Any] {
        ["threadId": threadId, "turnId": turnId]
    }

    // MARK: - Server-initiated requests (codex → client)

    /// Classifies an inbound server-request so the backend ALWAYS answers it. Silently
    /// dropping any server-request blocks the turn forever (codex waits on our reply) —
    /// that is the codex「运行中…」转圈不结束 root cause. The real `ServerRequest` enum
    /// (codex-cli 0.137.0 `generate-json-schema`) is: three `*requestApproval` +
    /// `mcpServer/elicitation/request` + `item/tool/requestUserInput` + `item/tool/call`
    /// + `account/chatgptAuthTokens/refresh` + `attestation/generate`.
    enum ServerRequestKind: Equatable { case approval, elicitation, account, unsupported }

    static func serverRequestKind(method: String) -> ServerRequestKind {
        if method.hasSuffix("requestApproval") { return .approval }   // command / fileChange / permissions
        if method == "mcpServer/elicitation/request" { return .elicitation }
        // account/chatgptAuthTokens/refresh —— codex 要客户端刷新 ChatGPT token。
        // 我们无法代刷(回错误让 turn 继续),但这是「codex 登录态失效」的强信号,
        // 单列出来给健康感知用(此前混在 unsupported 里被静默丢,分诊第 7 点)。
        if method.hasPrefix("account/") { return .account }
        return .unsupported
    }

    /// Reply for `mcpServer/elicitation/request`. CRITICAL: in codex-cli 0.137.0 the
    /// **MCP tool-call approval prompt is delivered AS an elicitation** carrying
    /// `_meta.codex_approval_kind == "mcp_tool_call"` (verified against a live
    /// `codex app-server` turn — NOT a `*/requestApproval`). So blanket-declining every
    /// elicitation declined every crew tool call: codex marked the `mcpToolCall` failed
    /// with `error:"user rejected MCP tool call"`, which is why the codex captain's
    /// `post_to_crew` check-in was rejected and never posted.
    ///
    /// The crew comms tools (`post_to_crew`/`read_whiteboard`/`ask`/…) are the session's
    /// own trusted nervous system and must auto-approve — exactly as the claude backend
    /// excludes them from its PreToolUse gate (`LocalSessionLaunch` `permGates =
    /// "computer-use"`; crew tools never gated). A crew session only ever wires the one
    /// trusted `crew` MCP server, so accepting `mcp_tool_call` elicitations is correct
    /// here (dangerous ops — shell/file — still gate via `*/requestApproval`). Genuine
    /// input-form elicitations (no `codex_approval_kind`) keep declining: v1 has no UI to
    /// fill them, and declining lets the turn proceed instead of hanging on a reply we'd
    /// never send. Shape per `McpServerElicitationRequestResponse` =
    /// `{ action: accept|decline|cancel, content? }`; accept/decline carry no content.
    static func elicitationResult(params: [String: Any]) -> [String: Any] {
        let meta = params["_meta"] as? [String: Any]
        if (meta?["codex_approval_kind"] as? String) == "mcp_tool_call" {
            return ["action": "accept"]
        }
        return elicitationDeclineResult()
    }

    /// Bare decline reply for a genuine (non-approval) elicitation.
    static func elicitationDeclineResult() -> [String: Any] { ["action": "decline"] }
}
#endif
