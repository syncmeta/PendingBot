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

### P2 — MCP 交互工具 + runner 接线 ✅ 已落（`<this branch>`）
- **机制 spike 验通**：headless `claude -p --mcp-config` 下阻塞 MCP 工具可用；`--permission-mode auto` **自动放行 MCP 工具**，不用 `--allowedTools`。
- **真 MCP server** `apps/pendingcrew/Resources/ask-human-mcp.cjs`：`ask_human(question)` → POST `/v1/sessions/:id/interactions` → long-poll `GET .../interactions/:reqId` 等 `answered` → 返回 `reply_text`。纯 Node、`.cjs`、env 传 `PC_EDGE_URL/PC_TOKEN/PC_SESSION_ID`。**对 mock edge 实跑验过**（raise→2 次 poll→拿到回复）。
- **runner 接线**：`InteractionChannel` 写托管 mcp.json；`LocalCodingAgentLaunchSpec.claudeMcpConfigPath` → `--mcp-config` 进首回合 + resume；`CrewSessionRunner` logged-claude 时从 serverLink 建 channel（edge url + token + session id）+ bundle 里的脚本。`.cjs` 确认进 app bundle。
- **prompt** §10（zh+en）重写：告诉 agent 用 `ask_human`、何时用、captain→DAG→真人 溯源 + 阻塞返回。
- 已验：61 swift 测试 + macOS build + MCP server mock-edge 实跑 + prompt 测试。**未验**：真实 edge auth 的端到端（要登录 + 迁移 apply）。
- runner 启动时 `--mcp-config` 注入（仅 logged；BYOK 看情况）。工具实现把请求 POST 到 edge、long-poll/WS 等回复。
- session-world-model 提示词（T4.2）加一段"要人介入时调 `ask_human`"。
- session 状态加 `waiting_interaction`。

### P3 — edge：数据面 + 端点（已起步）/ captain 判断 + DAG 溯源（待）
- **✅ 数据面 + 端点已落（`<this branch>`，typecheck 绿）**：
  - 迁移 `20260602145934_crew_interaction_requests.sql`：`permission_requests` 加 `request_kind`(permission|question) + `reply_text` + status 加 `answered`；RPC `create_interaction_request` / `answer_interaction_request`（复用 T4.3 卡片 + decide 的 ACL）。
  - 路由 `apps/edge/src/routes/crew-interactions.ts`：`POST /v1/sessions/:id/interactions`（runner 发起）· `GET .../interactions/:reqId`（runner long-poll）· `POST /v1/interactions/:reqId/answer`（人答，自由文本）。untypedRpc 走法 → 不用 regen 就 typecheck 绿。
  - **⚠️ 迁移未 apply、schema.ts 未 regen**（commit 用了 LEFTHOOK=0 跳过 schema-regen 钩子）。落地前必须：从主 worktree `supabase db push` + `types:db` + 收口 untypedRpc。v1 直接发卡给责任主体（direct_to_human）。
- **待**：captain LLM 判断"自决 vs 上溯"（captain system prompt 加职责）+ 沿 crew DAG 父链冒泡溯源路由（§10.3-10.5）。

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
