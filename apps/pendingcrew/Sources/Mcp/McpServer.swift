import Foundation

/// 本地 crew-comms 的 MCP server 逻辑（spec local-first chunk 4）。claude 经
/// `--mcp-config` 把 `pendingcrew-mcp serve` 拉成子进程，session 用 `post_to_crew`
/// 往本地白板发、`read_whiteboard` 读 —— 全部落到与 PendingCrew app 同一份
/// `LocalWhiteboardStore`。MCP spike 已验 auto mode 自动放行（findings 文档）。
///
/// `handleLine` 是纯函数式 dispatch（一行 JSON-RPC → 应答 JSON 字符串 / nil），
/// 不碰进程/stdio —— 这样能编进 PendingCrewTests bundle 单测。stdin/stdout loop
/// 在 `main.swift`。用 `JSONSerialization`（不给每个 RPC 形状写 Codable）。
final class McpServer {
    let store: LocalWhiteboardStore
    let crewId: String
    let sessionId: String

    init(store: LocalWhiteboardStore, crewId: String, sessionId: String) {
        self.store = store
        self.crewId = crewId
        self.sessionId = sessionId
    }

    /// 处理一行 JSON-RPC。返回应答 JSON 字符串；通知（无 id / `notifications/*`）→ nil。
    func handleLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let method = obj["method"] as? String
        let id = obj["id"]

        if let method, method.hasPrefix("notifications/") { return nil }

        switch method {
        case "initialize":
            return result(id: id, [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "pendingcrew", "version": "0.1.0"],
            ])
        case "tools/list":
            return result(id: id, ["tools": [
                [
                    "name": "post_to_crew",
                    "description": "把关键节点发到 crew 群聊白板（只发要紧的：开始/完成/卡住/交接/重要发现，别倒 IO 日志）。",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "message": ["type": "string"],
                            "category": ["type": "string", "enum": ["progress", "question", "milestone"]],
                        ],
                        "required": ["message"],
                    ],
                ],
                [
                    "name": "read_whiteboard",
                    "description": "读取 crew 群聊白板的当前全部消息（按时间序）。",
                    "inputSchema": ["type": "object", "properties": [String: Any]()],
                ],
            ]])
        case "tools/call":
            let params = obj["params"] as? [String: Any]
            return handleToolCall(id: id,
                                  name: params?["name"] as? String,
                                  args: params?["arguments"] as? [String: Any] ?? [:])
        default:
            guard id != nil else { return nil }
            return error(id: id, code: -32601, message: "method not found: \(method ?? "nil")")
        }
    }

    private func handleToolCall(id: Any?, name: String?, args: [String: Any]) -> String? {
        switch name {
        case "post_to_crew":
            let message = (args["message"] as? String) ?? ""
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return toolResult(id: id, text: "ERROR: message 不能为空")
            }
            store.appendSessionMessage(crewId: crewId, sessionId: sessionId,
                                       text: message, category: args["category"] as? String)
            return toolResult(id: id, text: "已发到 crew 群聊白板。")
        case "read_whiteboard":
            let rows = store.list(crewId: crewId).map(renderRow)
            return toolResult(id: id, text: rows.isEmpty ? "（白板为空）" : rows.joined(separator: "\n"))
        default:
            return toolResult(id: id, text: "ERROR: 未知工具 \(name ?? "nil")")
        }
    }

    private func renderRow(_ m: LocalWhiteboardMessage) -> String {
        let who: String
        switch m.senderKind {
        case "session": who = "session:\(m.senderSessionId ?? "?")"
        case "user": who = "人类"
        default: who = m.senderKind
        }
        return "[\(m.createdAt)] \(who): \(m.text)"
    }

    // MARK: - JSON-RPC envelope helpers

    private func result(id: Any?, _ result: [String: Any]) -> String? {
        envelope(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func toolResult(id: Any?, text: String) -> String? {
        result(id: id, ["content": [["type": "text", "text": text]]])
    }

    private func error(id: Any?, code: Int, message: String) -> String? {
        envelope(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func envelope(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}
