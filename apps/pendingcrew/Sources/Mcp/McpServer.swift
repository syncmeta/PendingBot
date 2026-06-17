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
    let approvals: LocalApprovalStore
    /// crew 元数据控制通道（机长 `rename_crew` → 写待改名，app 侧 `CrewStore`
    /// 排空落地）。与 store/approvals 同 `--dir` —— 离线 helper 唯一能碰的共享文件层。
    let control: LocalCrewControlStore
    let crewId: String
    let sessionId: String
    /// 机长 session 标记（helper `--captain` flag 传入）—— 解锁机长专用工具
    /// `answer_decision`（chunk2 T4）。worker session 看不到也调不动。
    let isCaptain: Bool
    /// 本 session 的显示 label（helper `--label` flag 传入；如「机长」/「Claude Code
    /// · abc123」）。`post_to_crew` 写白板时带上 → agent 看的白板不再裸 uuid。
    /// nil（未传 label / 旧调用）→ 渲染退回 `session:<id>`，保持兼容。
    let sessionLabel: String?

    init(store: LocalWhiteboardStore, approvals: LocalApprovalStore, control: LocalCrewControlStore,
         crewId: String, sessionId: String,
         isCaptain: Bool = false, sessionLabel: String? = nil) {
        self.store = store
        self.approvals = approvals
        self.control = control
        self.crewId = crewId
        self.sessionId = sessionId
        self.isCaptain = isCaptain
        self.sessionLabel = sessionLabel
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
            var tools: [[String: Any]] = [
                [
                    "name": "post_to_crew",
                    "description": "把关键节点发到 crew 群聊白板（只发要紧的：开始/完成/卡住/交接/重要发现，别倒 IO 日志）。可带 mentions 定向 @ 某个 session/captain/人类，或 reply_to 回复某条（自动 @ 原发送者）。",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "message": ["type": "string"],
                            "category": ["type": "string", "enum": ["progress", "question", "milestone"]],
                            "mentions": [
                                "type": "array",
                                "description": "可选定向 @ 列表 —— 要某个具体对象接手/回应时带上；不填=广播给全 crew。@session 会把这条投进那个 session 的定向信箱（它优先看到）。",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "kind": ["type": "string", "enum": ["session", "captain", "human"]],
                                        "target_id": ["type": "string", "description": "kind=session 时必填：目标 session 的 id。"],
                                    ],
                                    "required": ["kind"],
                                ],
                            ],
                            "reply_to": [
                                "type": "string",
                                "description": "可选：你在回复哪条群聊消息的 id —— 给了会自动 @ 那条的原发送者。",
                            ],
                        ],
                        "required": ["message"],
                    ],
                ],
                [
                    "name": "read_whiteboard",
                    "description": "读取 crew 群聊白板的当前全部消息（按时间序）。",
                    "inputSchema": ["type": "object", "properties": [String: Any]()],
                ],
                [
                    "name": "ask",
                    "description": "向负责人提问并拿到答复（先 captain，再人类）。任何需要人 / captain 判断、决策、方向选择、澄清、授权的，都走这个 —— 不要在纯文本里问。会阻塞直到有人答。",
                    "inputSchema": [
                        "type": "object",
                        "properties": ["question": ["type": "string"]],
                        "required": ["question"],
                    ],
                ],
            ]
            if isCaptain {
                tools.append([
                    "name": "answer_decision",
                    "description": "（机长专用）答复一条待决策：用你的判断给出答复，answering 会立刻解开发起 session 的等待。",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "reqId": ["type": "string"],
                            "reply": ["type": "string"],
                        ],
                        "required": ["reqId", "reply"],
                    ],
                ])
                tools.append([
                    "name": "rename_crew",
                    "description": "（机长专用）给这个 crew 起名字。用**标签的思想**：一个短概括，不是一句描述。等你搞清楚这个 crew 在做什么再叫，例：「鉴权重构」「深色模式」「语音重连」。别写成长句、别带标点、别加前后缀。搞清楚后改一次就够，别反复改；人类要是已经起了个有意义的名字，就别动。",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "短标签（几个字的概括）。"],
                        ],
                        "required": ["name"],
                    ],
                ])
            }
            return result(id: id, ["tools": tools])
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
            // Phase 7：解析定向 @ + reply_to,记进本地白板（不静默吞）。把它们按
            // mention 投递到 edge 信箱 / 唤醒目标 session 还需 block 3 relay 同步链
            // （见 CrewRelayAgent.push）—— 本地这步只负责把信息留住。
            let mentions = parseMentions(args["mentions"])
            let replyTo = (args["reply_to"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            store.appendSessionMessage(crewId: crewId, sessionId: sessionId,
                                       text: message, category: args["category"] as? String,
                                       senderName: sessionLabel,
                                       mentions: mentions, inReplyTo: replyTo)
            return toolResult(id: id, text: "已发到 crew 群聊白板。")
        case "read_whiteboard":
            let rows = store.list(crewId: crewId).map(renderRow)
            return toolResult(id: id, text: rows.isEmpty ? "（白板为空）" : rows.joined(separator: "\n"))
        case "ask":
            let question = (args["question"] as? String) ?? ""
            guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return toolResult(id: id, text: "ERROR: question 不能为空")
            }
            // 直达人类退化路径（captain-first triage 等 chunk 2）：raise 一条待决策 →
            // 阻塞 long-poll 人类/captain 答复（spec ask-approval §3/§5）。
            let reqId = approvals.raise(crewId: crewId, kind: "decision", sessionId: sessionId, summary: question)
            // 通知半边（spec §6「PendingCrew 只做通知+列表+答复」）：把问题贴到本地群聊白板，
            // 人类/captain 在 crew chat 就看得见有个待决策（v1 降级 reporter；真正的「专门
            // reporter session 思考后 @人类」属 chunk 2）。答复仍走待办列表（approvals）。
            store.appendSessionMessage(crewId: crewId, sessionId: sessionId,
                                       text: "🔔 待决策：\(question)\n（请在 PendingCrew 待办列表里答复）",
                                       category: "question", senderName: sessionLabel)
            return toolResult(id: id, text: awaitReply(reqId: reqId))
        case "answer_decision":
            // 机长专用（chunk2 T4）：答复一条 decision，解开发起 session 的 long-poll。
            guard isCaptain else {
                return toolResult(id: id, text: "ERROR: 仅机长可用")
            }
            let reqId = (args["reqId"] as? String) ?? ""
            let reply = (args["reply"] as? String) ?? ""
            guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return toolResult(id: id, text: "ERROR: reply 不能为空")
            }
            guard let item = approvals.item(crewId: crewId, id: reqId) else {
                return toolResult(id: id, text: "ERROR: 找不到待决策 \(reqId)")
            }
            guard item.kind == "decision" else {
                return toolResult(id: id, text: "ERROR: 该条不是待决策（权限审批请人类处理）")
            }
            guard item.status == "pending" else {
                return toolResult(id: id, text: "ERROR: 该条已被答复")
            }
            approvals.answer(crewId: crewId, id: reqId, reply: reply)
            return toolResult(id: id, text: "已答复，发起的 session 将继续。")
        case "rename_crew":
            // 机长专用（crew-naming）：写一条待改名进控制通道；app 侧 CrewStore
            // 排空落地到 LocalCrewStore.setTitle 并刷新侧栏。不限长度 —— 标签思想
            // 靠描述 + prompt 引导；这里只把名字收成单行（空白/换行折成单空格）+ 拒空。
            guard isCaptain else {
                return toolResult(id: id, text: "ERROR: 仅机长可用")
            }
            let raw = (args["name"] as? String) ?? ""
            let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !name.isEmpty else {
                return toolResult(id: id, text: "ERROR: name 不能为空")
            }
            control.requestRename(crewId: crewId, name: name)
            return toolResult(id: id, text: "已把 crew 改名为「\(name)」。")
        default:
            return toolResult(id: id, text: "ERROR: 未知工具 \(name ?? "nil")")
        }
    }

    /// 阻塞 long-poll 直到待决策被答复或到上限，返回答复文本 / 超时占位。
    /// **绝不无限等**：默认 ~30min 上限（3600 × 0.5s，与 codex 审批 provider 一致）——
    /// 一个没人答的 `ask` 若一直阻塞，会让 codex 那一轮的 `tools/call` 永不返回，整个
    /// turn 卡死在「运行中…」（codex session 跑半天不出东西的根因之一）。到点返回
    /// 「自行判断」让 agent 继续。`pollInterval`/`maxWaits` 给单测调小。
    func awaitReply(reqId: String, pollInterval: TimeInterval = 0.5, maxWaits: Int = 3600) -> String {
        var waits = 0
        while waits < maxWaits {
            if let it = approvals.item(crewId: crewId, id: reqId), it.status == "answered" {
                return it.reply ?? "（已答复，无文本）"
            }
            waits += 1
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return "（暂无人响应 —— 请自行判断后继续）"
    }

    /// 把 `post_to_crew` 的 `mentions` 参数（JSON 数组）解析成本地 mention 模型。
    /// 宽容解析：丢掉缺 `kind` 的坏条目，但保留其余 —— 别因一条坏 mention 把整条
    /// 消息或全部 mention 静默吞掉。空 / 非数组 → nil（= 广播）。
    private func parseMentions(_ raw: Any?) -> [LocalWhiteboardMention]? {
        guard let arr = raw as? [[String: Any]] else { return nil }
        let parsed: [LocalWhiteboardMention] = arr.compactMap { item in
            guard let kind = item["kind"] as? String, !kind.isEmpty else { return nil }
            let target = (item["target_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return LocalWhiteboardMention(kind: kind, targetId: target)
        }
        return parsed.isEmpty ? nil : parsed
    }

    private func renderRow(_ m: LocalWhiteboardMessage) -> String {
        // 与 HookEmitter.render 同款：有显示名优先用名，无名退回旧格式。
        let who: String
        if let name = m.senderName ?? m.senderDisplayName, !name.isEmpty {
            who = name
        } else {
            switch m.senderKind {
            case "session": who = "session:\(m.senderSessionId ?? "?")"
            case "user": who = "人类"
            default: who = m.senderKind
            }
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
