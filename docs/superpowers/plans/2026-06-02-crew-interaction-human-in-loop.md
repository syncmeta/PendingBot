# Plan — Crew 人在回路交互（Human-in-the-loop Interaction）

权威设计见 spec v2 §10（2026-06-02 重写）。本 plan 是落地路线。

**一句话**：session 跑 claude/codex 在 **auto/bypass 模式**（CLI 直接用，不碰 SDK），平时不打扰人；只有 agent 真要人介入（computer-use 授权 / 问问题 / 要判断）时，调一个经 `--mcp-config` 注入的 **MCP 交互工具** → 阻塞 → captain 自决或沿 crew DAG 溯源到真人 @ 之 → 回复回流解阻塞。**是交互，不是逐动作审批。**

## 复用 vs 新建

- **复用**：captain（§6.3）+ crew DAG/父链（`responsible_subject_id` / attach-parent）+ crew 群聊/`post_to_crew`（T4.1）+ permission_requests 表 + iOS 卡片（T4.3，改造成"交互卡"）+ 跨端遥控 composer（§9.6，我已建的 send_prompt/steering 通道复用为回复入口）。
- **新建**：① PendingCrew 侧的 MCP 交互工具 server + `--mcp-config` 接线；② captain 的"自决 / 溯源"判断逻辑；③ DAG 溯源路由 + 两种模式；④ @-mention + "仅看@我"过滤（iOS 可能没有）。

## 阶段

### P0 — 设计定稿 ✅
spec §10 重写（本 commit）。

### P1 — 运行模式作为 session 选项（小，CLI 原生）✅ 已落（`<this branch>`）
- `AgentPermissionMode {standard, planOnly, full}`（LocalRunner）→ per-kind 映射：claude `--permission-mode {auto, plan, bypassPermissions}` / codex `--sandbox {workspace-write, read-only, danger-full-access}`；进首回合 + resume 回合 argv，默认 `.standard`。
- CreateSessionSheet picker 改成 标准 / 只读规划 / 完全放行 + 每档说明。
- **顺手修了个隐患**：runner 原来不传 `--permission-mode` → claude 落 `default` → headless 碰权限**卡死**等不存在的终端。默认 `auto` 解掉。
- **验证状态**：claude headless 实测（auto/bypass/acceptEdits 放行 Write+Bash；default/dontAsk 卡死）；**codex 只验了 flag 存在，runtime 没验**（本机 codex auth 401）——codex 真机要补验 `--sandbox workspace-write` 实跑能写。

### P2 — MCP 交互工具 + runner 接线（中）
- **✅ 机制已 spike 验通（`<this branch>`，2026-06-02）**：headless `claude -p --mcp-config <cfg> --allowedTools "mcp__ask__ask_human"` —— 写了个最小 MCP stdio server（`ask_human` 工具，`tools/call` 故意 setTimeout 1.5s 才返回模拟阻塞溯源），claude **调了工具、阻塞等到返回、用返回值继续**（模型最终只回工具给的 passcode）。证明：阻塞 MCP 工具经 `--mcp-config`（CLI 原生、无 SDK）就是 headless session "问人并等回复" 的正解。
- 待建：一个 PendingCrew 真 MCP server（`ask_human(question, context?)`），`tools/call` 里把请求 POST 到 edge、long-poll/WS 等回复再返回。
- runner 启动时 `--mcp-config` 注入（仅 logged；BYOK 看情况）。工具实现把请求 POST 到 edge、long-poll/WS 等回复。
- session-world-model 提示词（T4.2）加一段"要人介入时调 `ask_human`"。
- session 状态加 `waiting_interaction`。

### P3 — edge：captain 判断 + DAG 溯源 + 持久化（中大）
- 交互请求落库（复用/扩展 `permission_requests` 表 + RPC）。
- captain 收到请求 → LLM 判断"自决 vs 上溯"（captain 的 system prompt 加这段职责）。
- 溯源路由：沿 crew DAG 父链冒泡，按 §10.5 落点规则定位真人责任主体，在对应群聊/对话发**交互卡** + @ 真人。
- 回复回流：人/captain 答 → 写回请求行 → 通知 runner 的 MCP 工具解阻塞。

### P4 — 两种溯源模式
- crew/session 配置加 `escalation_mode`：`direct_to_human` / `tiered`。
- 路由按模式：直达=跳过中间 captain 自决、直接冒泡到最近真人；层层=每级 captain 先判。

### P5 — iOS/Mac 交互卡 + @ 过滤（中）
- T4.3 权限卡改造成交互卡：显示问题/请求 + 输入框或选项 + 提交。
- @-mention 渲染 + "仅看 @我"过滤开关（群聊 + crew 聊天）。
- 回复走 §9.6 composer / 交互卡提交。

## 验证门（不能跳）

- P1/P2 的 CLI 行为：headless 真跑确认（mode 生效、`--mcp-config` 阻塞工具可用）。
- 整链路 E2E：要登录账号 + 真实 crew/DAG + 真机（mint device-grant 要 iOS 扫码，headless 起不了）——归 T5.3 QA。

## 待定 / 开放问题

- 超时/无人响应：默认无限挂起 vs 超时后 captain 兜底自决 vs fail-loud（§10.7）。
- codex 的 `--mcp-config` 等价能力是否对齐 claude（codex 侧要单独验；可能先只 claude 验通）。
- captain 是 PendingBot bot（edge 上有 tools），它跟 session 的 claude/codex 是两个进程——交互请求从 session 的 MCP 工具出来后怎么"喂给 captain 判断"：captain 当成一条 crew 消息处理，还是专门的 RPC？（P3 第一步要定）
