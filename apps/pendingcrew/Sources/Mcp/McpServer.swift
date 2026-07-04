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
    /// quota.json 所在目录（app 的 `QuotaCenter` 定时写、`get_quota` 工具读）。
    /// 与 store/approvals/control 同 `--dir`。
    let quotaDirectory: URL

    init(store: LocalWhiteboardStore, approvals: LocalApprovalStore, control: LocalCrewControlStore,
         crewId: String, sessionId: String,
         isCaptain: Bool = false, sessionLabel: String? = nil,
         quotaDirectory: URL? = nil) {
        self.store = store
        self.approvals = approvals
        self.control = control
        self.crewId = crewId
        self.sessionId = sessionId
        self.isCaptain = isCaptain
        self.sessionLabel = sessionLabel
        self.quotaDirectory = quotaDirectory ?? LocalWhiteboardStore.defaultDirectory
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
                [
                    "name": "get_quota",
                    "description": "查本机 coding-agent 订阅额度（claude / codex 的已用百分比 + 重置时刻）。开长活前、或怀疑额度紧张时查一下用于规划：额度将尽 → 把剩余工作收尾成可交接状态，再用 schedule_wakeup 约在重置后继续；富余 → 放心跑。数据由 PendingCrew 每 ~10 分钟刷新（只有百分比和重置时刻，没有剩余 token 绝对值）。",
                    "inputSchema": ["type": "object", "properties": [String: Any]()],
                ],
                [
                    "name": "schedule_wakeup",
                    "description": "设一个定时唤醒：到点后系统会把一条带你备注的消息注入回你这个 session，把你叫醒继续干。典型用法：额度快耗尽时（get_quota 看重置时刻），把手头活收尾，然后约在额度重置后几分钟唤醒自己接着做。after_minutes 与 at 二选一；note 写清醒来该干什么（醒来时只有这条备注 + 白板可看）。",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "after_minutes": ["type": "number", "description": "多少分钟后唤醒（1–1440）。"],
                            "at": ["type": "string", "description": "ISO8601 时刻（如 2026-07-05T04:45:00+08:00）。与 after_minutes 二选一。"],
                            "note": ["type": "string", "description": "唤醒时带回给你的备注：醒来该继续什么、上下文在哪。"],
                        ],
                        "required": ["note"],
                    ],
                ],
                [
                    "name": "set_session_profile",
                    "description": "切换你自己这个 session 的模型/thinking effort（至少给一个）。用于按任务阶段调配：机械收尾活降到轻模型/低 effort 省额度，难题升 effort。claude session 立即生效（等价 /model、/effort）；codex 没有中途切换通道——会在白板收到说明，新任务请让机长用 start_session 带 model/effort 另起。claude effort: low/medium/high/xhigh/max。",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "model": ["type": "string", "description": "模型别名/slug，如 opus/sonnet/haiku。"],
                            "effort": ["type": "string", "description": "thinking effort 档位。"],
                        ],
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
                tools.append([
                    "name": "start_session",
                    "description": "（机长专用）在当前 crew 里起一个 worker session 去干一件明确的编码任务。brief 写清要干什么。runner 默认随本 crew（不填即可），可填 \"claude\"/\"codex\" 覆盖。isolation 默认 false（与你共享 crew 目录）；只有当这件事会大改文件、想隔离到独立 worktree 时才传 true。model/effort 可选：按任务难度配置——简单机械活给低 effort/轻模型省额度，难活给高 effort；不填用该 CLI 默认。起完 worker 会自己报到，你在群聊看得到。",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "brief": ["type": "string", "description": "要这个 session 干的明确任务。"],
                            "runner": ["type": "string", "enum": ["claude", "codex"]],
                            "isolation": ["type": "boolean"],
                            "model": ["type": "string", "description": "可选：模型别名/slug。claude 常用 \"opus\"/\"sonnet\"/\"haiku\"；codex 如 \"gpt-5-codex\"。不填=CLI 默认。"],
                            "effort": ["type": "string", "description": "可选：thinking effort。claude: low/medium/high/xhigh/max；codex: minimal/low/medium/high。不填=CLI 默认。"],
                        ],
                        "required": ["brief"],
                    ],
                ])
                tools.append([
                    "name": "create_child_crew",
                    "description": "（机长专用）以当前 crew 为父，建一个子 crew。**只在一块事大到该独立成组、要有自己的机长和群聊时才拆，别滥拆。**子 crew 继承本 crew 的工作目录与机长类型，会自动起自己的机长，brief 作为它的开场任务。title 可不填（自动取个地名，子机长之后自己改名）。有子 crew 深度上限，太深会被拒。",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "brief": ["type": "string", "description": "这个子 crew 要干的事（子机长的开场任务）。"],
                            "title": ["type": "string", "description": "可选：短标签名。不填自动取地名。"],
                        ],
                        "required": ["brief"],
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
        case "start_session":
            guard isCaptain else { return toolResult(id: id, text: "ERROR: 仅机长可用") }
            let brief = ((args["brief"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !brief.isEmpty else { return toolResult(id: id, text: "ERROR: brief 不能为空") }
            let runner = (args["runner"] as? String).flatMap { ["claude", "codex"].contains($0) ? $0 : nil }
            let isolation = args["isolation"] as? Bool
            // model/effort 透传字符串：有效值归 CLI 管（起不来会经 lastStartError 浮出），
            // 这里只做「单 token、非空」的卫生（防把整句话塞进 argv）。
            let model = (args["model"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty || $0.contains(" ") ? nil : $0 }
            let effort = (args["effort"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .flatMap { $0.isEmpty || $0.contains(" ") ? nil : $0 }
            control.enqueueStartSession(crewId: crewId, brief: brief, runner: runner,
                                        isolation: isolation, model: model, effort: effort)
            return toolResult(id: id, text: "已安排起 session：\(brief)。它起来后会在群聊报到。")
        case "get_quota":
            let url = quotaDirectory.appendingPathComponent("quota.json")
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(AgentQuotaFile.self, from: data) else {
                return toolResult(id: id, text: "暂无额度数据（PendingCrew 尚未完成首次刷新，稍后再查）。")
            }
            var lines: [String] = []
            for snap in [file.claude, file.codex].compactMap({ $0 }) {
                let name = snap.agent == "claude" ? "Claude Code" : "Codex"
                let windows = snap.windows.map { w in
                    "\(w.label) 已用 \(w.usedPercent)%" + (w.resetsAt.map { "（\($0) 重置）" } ?? "")
                }.joined(separator: "；")
                lines.append("\(name)：\(windows)（数据时间 \(snap.fetchedAt)）")
            }
            if lines.isEmpty { lines = ["两家 agent 均未取到额度数据。"] }
            lines.append("注：只有百分比 + 重置时刻，无剩余 token 绝对值。额度将尽时先收尾、再用 schedule_wakeup 约重置后继续。")
            return toolResult(id: id, text: lines.joined(separator: "\n"))
        case "schedule_wakeup":
            let note = ((args["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty else { return toolResult(id: id, text: "ERROR: note 不能为空 —— 醒来的你只有这条备注可依靠。") }
            let fireAt: Date
            if let mins = args["after_minutes"] as? Double, mins >= 1, mins <= 1440 {
                fireAt = Date().addingTimeInterval(mins * 60)
            } else if let atRaw = args["at"] as? String,
                      let parsed = Self.parseISO(atRaw), parsed > Date() {
                fireAt = parsed
            } else {
                return toolResult(id: id, text: "ERROR: 需要 after_minutes（1–1440）或未来的 at（ISO8601）之一。")
            }
            let iso = ISO8601DateFormatter().string(from: fireAt)
            control.enqueueScheduleWakeup(crewId: crewId, sessionId: sessionId, fireAt: iso, note: note)
            return toolResult(id: id, text: "已设定时唤醒：\(iso)。到点会把你的备注注入回本 session；若届时你已退出，会落到群聊白板由机长接手。")
        case "set_session_profile":
            let model = (args["model"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty || $0.contains(" ") ? nil : $0 }
            let effort = (args["effort"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .flatMap { $0.isEmpty || $0.contains(" ") ? nil : $0 }
            guard model != nil || effort != nil else {
                return toolResult(id: id, text: "ERROR: model / effort 至少给一个（单 token，别整句话）。")
            }
            control.enqueueSetProfile(crewId: crewId, sessionId: sessionId, model: model, effort: effort)
            let parts = [model.map { "模型→\($0)" }, effort.map { "effort→\($0)" }].compactMap { $0 }
            return toolResult(id: id, text: "已提交切换：\(parts.joined(separator: "、"))。claude 立即生效；codex 无中途切换通道（会在白板收到说明）。")
        case "create_child_crew":
            guard isCaptain else { return toolResult(id: id, text: "ERROR: 仅机长可用") }
            let brief = ((args["brief"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !brief.isEmpty else { return toolResult(id: id, text: "ERROR: brief 不能为空") }
            let rawTitle = (args["title"] as? String) ?? ""
            let title = rawTitle.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            control.enqueueCreateChildCrew(crewId: crewId, brief: brief, title: title.isEmpty ? nil : title)
            return toolResult(id: id, text: "已安排建子 crew。它起来后子机长会报到。")
        default:
            return toolResult(id: id, text: "ERROR: 未知工具 \(name ?? "nil")")
        }
    }

    /// 宽容的 ISO8601 解析：带/不带小数秒都收（agent 生成的时间串两种都常见）。
    static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f2.date(from: s)
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
