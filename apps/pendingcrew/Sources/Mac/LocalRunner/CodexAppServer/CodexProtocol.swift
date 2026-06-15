#if os(macOS)
import Foundation

/// Param builders for the core-loop methods. Plain dictionaries (paired with
/// CodexRPCMessage encoding) keep this Foundation-only + unit-testable.
enum CodexProtocol {
    static func initializeParams(clientName: String, version: String) -> [String: Any] {
        ["clientInfo": ["name": clientName, "title": clientName, "version": version],
         "capabilities": [
             "experimentalApi": true,
             // v1 renders on item/completed only — opt out of streaming deltas to cut wire chatter.
             // Exact method-name list is version-locked; reconcile against a real
             // `codex app-server generate-json-schema` capture (real-machine tail). Opting out of a
             // non-existent method is a harmless no-op, so this documented name is safe to ship now.
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
    /// The unread crew whiteboard rides in as a **leading `text` input item**, not a
    /// `turn/start.additionalContext` field — codex has no such field (verified against
    /// the real schema; the old shape was silently dropped, so codex sessions never saw
    /// the whiteboard despite the world-model claiming auto-injection). `wb` is already
    /// framed as trusted-teammate context by `HookEmitter.render`, so it's prepended
    /// verbatim ahead of the user's text.
    static func turnStartParams(threadId: String, text: String, whiteboard: String?) -> [String: Any] {
        var input: [[String: Any]] = []
        if let wb = whiteboard, !wb.isEmpty {
            input.append(["type": "text", "text": wb, "text_elements": []])
        }
        input.append(["type": "text", "text": text, "text_elements": []])
        return ["threadId": threadId, "input": input]
    }
    static func turnInterruptParams(threadId: String, turnId: String) -> [String: Any] {
        ["threadId": threadId, "turnId": turnId]
    }
}
#endif
