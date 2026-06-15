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
        if let mcp = mcpServers, !mcp.isEmpty { p["mcpServers"] = mcp }
        return p
    }
    static func turnStartParams(threadId: String, text: String, whiteboard: String?) -> [String: Any] {
        var p: [String: Any] = [
            "threadId": threadId,
            "input": [["type": "text", "text": text, "text_elements": []]],
        ]
        if let wb = whiteboard, !wb.isEmpty {
            p["additionalContext"] = ["whiteboard": ["value": wb, "kind": "untrusted"]]
        }
        return p
    }
    static func turnInterruptParams(threadId: String, turnId: String) -> [String: Any] {
        ["threadId": threadId, "turnId": turnId]
    }
}
#endif
