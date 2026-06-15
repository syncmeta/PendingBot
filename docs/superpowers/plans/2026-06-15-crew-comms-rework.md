# Crew 群聊通信重做 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development 逐阶段执行。每阶段是独立可测、可合 main 的单元。Steps 用 checkbox(`- [ ]`)跟踪。
> **范围**:只动 **apps/edge**(路由/DB/迁移)+ **apps/pendingcrew**(runner/UI/MCP)。**iOS PendingBot 这块已删,本轮不碰**(将来基于 PendingCrew 成熟后重做)。

**Goal:** 让 crew 群聊从"广播 + 轮询 + @ 被丢弃"变成"双向 @ + 看得见发送者 + 可对某条消息回复(自动 @ 原发送者)+ 全程推送(本地进程内事件 / 远端复用 RealtimeHubDO),无轮询"。

**Architecture:**
- **一条通信通道,两种实现**:远端复用既有 `RealtimeHubDO("conv:<crewId>")`(DB webhook 驱动的 conv 级实时扇出),PendingCrew 写个瘦 WS 客户端连上去;本地用进程内 publisher(`LocalWhiteboardStore` append → Combine/Notification)。**不新建 DO**。
- **定向投递复用既有信箱**:`session_mailbox_items`(通用定向表,现仅被跨设备遥控喂)接上 @ —— `resolveRecipientSessions` 这个孤儿函数接进 POST /messages。
- **runner 自筛**:每个 session runner 订阅 crew hub,收到消息总是更新自己白板上下文;当消息 @我 / reply 我且我空闲 → 唤醒、作为下一轮输入(直接输入);离线没收到 → 起来时拉 mailbox 补。
- **@ 双向对称**:人→session(composer @ picker)和 session→任意人(`post_to_crew` 加 mentions)用同一套 mention 模型。

**Tech Stack:** Hono + Cloudflare Workers/Durable Objects(edge,TS,vitest);Supabase Postgres(迁移走 timestamp 前缀 + `supabase db push` + `types:db` regen);Swift / SwiftUI(PendingCrew,macOS + iPad);MCP stdio(pendingcrew-mcp)。

---

## 数据模型增量(先盘清现状,避免重复造)

**已存在、可直接用**:
- `session_mailbox_items`:`recipient_session_id` / `sender_kind` / `sender_session_id` / `message_kind` / `summary` / `payload` / `status`。定向投递的承载体。
- `create_crew_announcement_from_runner_for_subject` RPC 已收 `p_recipient_session_ids` / `p_recipient_member_ids` —— **announcement 层已支持定向收件人**,只是 post-to-crew 端点硬写了 `[]`。
- `enqueue_session_mailbox` RPC(写单条定向信箱)。
- `mark_session_mailbox_delivered` RPC。
- edge `MentionItem` zod(`{kind, target_id?}`)+ `resolveRecipientSessions`(孤儿)+ client `CrewMention`。
- `crew_announcements` / `crew_sessions` / `messages` 已经过 DB webhook 进 `RealtimeHubDO("conv:<crewId>")` 扇出(任何 INSERT/UPDATE)。

**需新增(迁移)**:
- 消息**稳定 id 对客户端可见** + **`in_reply_to`**(指向被回复消息的 id)。优先挂在 `messages`(群聊 IS messages)与 announcement payload 上,不新建表。
- **发送者身份**透出到白板读模型:announcement / 信箱条目能解析出 `sender_member_id` + `display_name`(给 UI 气泡和给 agent 看的白板渲染都要)。先确认 roster(`temporary_group_members` + `crew_sessions`)能否 join 出名字;能则在读端点 join,不能则加列回填。

> 迁移用 `supabase migration new <name>`(timestamp 前缀),应用走 `supabase db push --linked` → `bun --filter='@pendingbot/edge' run types:db` → typecheck → `chore(db): regen schema.ts`。

---

## Phase 1 — Edge:入站 @ 接通(人→session 定向 + 唤醒信号落库)

**Goal:** `POST /v1/crews/:crewId/messages` 真正消费 `mentions`:@broadcast/空=全员;@session/@captain=定向落 announcement recipients + 给目标 session `enqueue_session_mailbox`。hub 扇出已自动带上(webhook)。

**Files:**
- Modify: `apps/edge/src/routes/crew-comms.ts`(POST handler L337-432 接 `resolveRecipientSessions`;把解析出的 session ids 传给 announcement RPC 的 `p_recipient_session_ids`,并对每个 enqueue mailbox)
- Test: `apps/edge/tests/crew-comms.test.ts`(扩:@session 只进目标信箱、@broadcast 不进信箱、@captain resolve 到机长 session、坏 target_id → 400)

**Approach:**
1. 先写失败测试:发 `mentions:[{kind:'session',target_id:S}]` → 断言 S 的 `session_mailbox_items` 多一行、别的 session 没有;`mentions:[]` → 无信箱写入但消息进库。
2. handler 里调 `resolveRecipientSessions(env, crewId, parsed.mentions)`;`null` = 全员(现行为,不写信箱);数组 = 对每个 id `enqueue_session_mailbox`(message_kind 取 'instruction'/'mention',summary=content 截断,payload 带 source:'crew_mention' + 原 message id)。
3. announcement/镜像消息照常写(广播仍在白板可见);定向只是**额外**的信箱推送。
4. 错误信封走 `jsonError`(invalid mention → 400 `invalid_body`)。

**Verify:** `cd apps/edge && ./node_modules/.bin/vitest run crew-comms` 全绿;`bun --filter='@pendingbot/edge' run typecheck`。

---

## Phase 2 — Edge:出站 @ + reply(session→任意人 + 对某条消息回复自动 @)

**Goal:** session 的 `post_to_crew` 能带 mentions 和 reply_to;reply_to 自动把被回复消息的发送者解析成 mention;解开 post-to-crew 端点硬写的 `recipient_session_ids:[]`。

**Files:**
- Modify: `apps/edge/src/lib/bot-reply/tool-defs.ts`(`post_to_crew` inputSchema 加 `mentions?` + `reply_to?`)
- Modify: `apps/edge/src/lib/bot-reply/tools/post-to-crew.ts`(消费 mentions/reply_to)
- Modify: `apps/edge/src/routes/crew-comms.ts`(`/:sessionId/post-to-crew` L821:`SessionPostToCrewBody` 加 mentions/reply_to;`resolveRecipientSessions` 复用;reply_to → 查原消息 sender → 追加 mention;传真实 recipient ids 给 RPC + enqueue 目标信箱)
- Test: `apps/edge/tests/crew-comms.test.ts`(session post 带 @session → 目标进信箱;reply_to 指向人类消息 → 该人类被加进 mentions 元数据;reply_to 指向另一 session → 那个 session 进信箱)

**Approach:**
1. 失败测试先行。
2. `reply_to`(被回复 message id)→ 读 `messages` 找 `role`/`user_id`/`log_payload.session_id` 定出原发送者 →:发送者是 session 则等价 `@session <id>`;是人类则 `@human`(元数据,不进信箱);把 reply_to 自身存进新消息(payload 或 `in_reply_to`)供 UI 串线。
3. recipient ids 由 `mentions + reply 推导`合并去重,传 `p_recipient_session_ids`,逐个 enqueue。

**Verify:** vitest crew-comms 绿 + typecheck。

---

## Phase 3 — 发送者身份(白板看得见谁发的)

**Goal:** UI 气泡 + 给 agent 看的白板渲染都显示发送者**显示名**,不再裸 `session:<uuid>`。

**Files:**
- Modify: `apps/edge/src/routes/crew-comms.ts`(crew 白板 GET + session inbox GET 的读模型:join roster 解析 sender → `display_name`;`CrewWhiteboardEntry` 透出 `senderName`/`senderMemberId`)
- Modify: `apps/pendingcrew/Sources/Services/CrewModels.swift`(`CrewWhiteboardEntry` 加 `senderName`)
- Modify: `apps/pendingcrew/Sources/Mcp/HookEmitter.swift`(render L33-46 用名字:`- 小绿(session): ...` 取代 `- session:<id>: ...`)
- Modify: `apps/pendingcrew/Sources/Stores/LocalWhiteboardStore.swift`(`LocalWhiteboardMessage` 带 `senderName`,append 时写入)
- Test: edge vitest(读模型含 senderName);pendingcrew `HookEmitterTests`(渲染含名字)

**Approach:** roster 已有 `displayName`(`listCrewMembers`)。读端点 join `temporary_group_members`/`crew_sessions` 取名;本地模式 append 时由 caller 传名字(session 自己的 display label 已知)。HookEmitter 渲染按名字。

**Verify:** edge vitest + `cd apps/pendingcrew && swift test`(HookEmitter)+ Mac build。

---

## Phase 4 — Runner 接 hub:远端推送消费 + 唤醒/注入

**Goal:** PendingCrew runner(登录模式)订阅 crew hub,实时收群聊消息 → 更新白板上下文;消息 @我/reply 我且空闲 → 唤醒、作为下一轮输入注入;读完 mark-delivered。替代"HTTP 拉白板"作为来源。

**Files:**
- 先勘察:`apps/edge/src/durable-objects/hub.ts` + realtime connect 路由 + 鉴权(device-grant 能否连 hub —— 不能则加 device-grant 入口,仿 session-proxy 的鉴权)
- Create: `apps/pendingcrew/Sources/Mac/LocalRunner/CrewRealtimeClient.swift`(瘦 WS:连 `conv:<crewId>` hub,收 row-change 事件,ping/reconnect)
- Modify: `apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift`(订阅 → 喂白板 provider;收到 @我 且 run 空闲 → `backend.send()` 注入;busy → 下一轮 turn 注入)
- Modify: `apps/pendingcrew/Sources/Services/PendingCrewAPI.swift`(mark-delivered 调用)
- Test: pendingcrew 单测(消息分发/筛选 @我 的纯逻辑可测;WS 连接走手动联调)

**Approach:** runner 已是交互式 PTY,每轮 turn 前注入未读白板(游标机制,非轮询)。本阶段把"白板来源"从被动改为 hub 推送:hub 来新消息 → 落本地白板 store(游标照常推进)。"唤醒"= 若该 run 当前 idle 且消息 addressed,则程序化 `send()` 起一轮(直接输入);busy 则等下一轮。离线兜底:run 启动时 `GET /inbox` 拉未 delivered 的 mailbox 补。

**Verify:** Mac build + 手动两 session 联调(A @ B,B 空闲被唤醒处理)。E2E 真机/双端验证记为尾巴(open task,不在骨架阶段关)。

---

## Phase 5 — 去轮询:本地进程内事件 + UI 事件驱动

**Goal:** 删掉 `CrewChatView` 的 3s `pollLoop`;本地模式 `LocalWhiteboardStore` append → 进程内 publisher → UI 即时刷新;本地 @ → 直接 `.send()` 到目标 run(同进程方法调用)。

**Files:**
- Modify: `apps/pendingcrew/Sources/Stores/LocalWhiteboardStore.swift`(append/raise 后发 `NotificationCenter` / Combine `PassthroughSubject`)
- Modify: `apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift`(L50/L86/L273-298:删 pollLoop,改订阅 store publisher;远端模式订阅 `CrewRealtimeClient`)
- Modify: `apps/pendingcrew/Sources/Mac/Views/CrewSessionWindowView.swift`(roster 的 3s 轮询同样改事件驱动 / 降级为 roster 变化时刷新)
- Test: pendingcrew 单测(append → publisher 触发一次)

**Approach:** 双轨:本地 backend 走进程内 publisher;远端 backend 走 Phase 4 的 `CrewRealtimeClient`。`CrewChatView` 统一订阅一个 `AsyncStream<Void>`(backend 暴露 `whiteboardChanges`),收到就 refresh(带 debounce)。本地 @ 目标 session 在同进程 → `runner.run(for: sessionId)?.send(text)` 直接注入,不经网络。

**Verify:** Mac + iPad build;本地模式手测发消息即时出现、不卡 3s。

---

## Phase 6 — 前端:composer @ picker + 对消息回复手势

**Goal:** composer 打 `@` → autocomplete 成员(session/captain/broadcast/human)→ staged chip;发送时构造 `mentions:[CrewMention]` 传给 `postCrewMessage`(替换硬写的 `mentions:[]`)。气泡长按/侧滑 → 回复(自动 @ 原发送者 + 带 reply_to)。

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift`(L323 send 改传真实 mentions;接 picker;气泡 reply 手势 → 预置 @ + reply_to)
- Create: `apps/pendingcrew/Sources/Mac/Views/CrewMentionPicker.swift`(@ 触发 + 成员列表 autocomplete + staged chip)
- Modify: `apps/pendingcrew/Sources/Services/PendingCrewBackend.swift` / `PendingCrewAPI.swift`(postCrewMessage 已收 mentions;补 reply_to 透传)
- Test: pendingcrew 单测(@token 解析→mentions;reply 手势→自动加 sender mention)

**Approach:** roster 来自 `listCrewMembers`(displayName/memberKind/codeSessionId/botId)。`@` 起 popover 过滤;选中 → 文本插 `@名字` + staged 一个 `CrewMention`。发送时 staged mentions 一起 POST。reply:长按气泡菜单"回复" → composer 顶部显示被回复条 + 自动 stage `@原发送者`,发送带 `reply_to=该消息id`。

**Verify:** Mac + iPad build;手测 @ 与 reply 流。

---

## Phase 7 — world-model prompt:教 session 用 @ / reply / 看发送者

**Goal:** session 世界观 prompt 说明:白板每条带发送者名;`post_to_crew` 可 `mentions` 定向 @、`reply_to` 回复某条(自动 @ 原发送者);何时该 @ 谁。

**Files:**
- Modify: `apps/pendingcrew/Resources/Prompts/session-world-model.{zh,en}.md`（§8 post_to_crew 段补 @ / reply 用法 + 发送者身份说明；canonical body 在 Langfuse，edge 无 prompts 副本）
- Modify: `apps/pendingcrew/Sources/Mcp/McpServer.swift`(`post_to_crew` inputSchema 加 `mentions?`/`reply_to?`;`read_whiteboard` 渲染带发送者名)
- Modify: 本地 prompts bundle(`LocalPromptLoader` 对应 md)
- Seed: 推更新后的 prompt 进 Langfuse production(按 `feedback_no_hardcoded_prompts` 走 prompt 通道,不内联)
- Test: edge `session-world-model.test.ts`(prompt 含 @ / reply 说明)

**Verify:** edge vitest + Mac build;prompt seeding 脚本跑通。

---

## 账本 & 收尾

- 每阶段合并时翻对应 Task(`feedback_tasksystem_source_of_truth`);用真机/双端才能 done 的(Phase 4 E2E、@ 实际唤醒)保持 open + 记 tech-debt 尾巴。
- `docs/progress.md` 顶部"最近对账"日期 + 本工作流 rollup。
- 记一条 tech-debt(若 Phase 4 device-grant 连 hub 需要新鉴权入口 / UI 轮询尾巴未全清)。
- 合并按 `docs/deploy.md` 之外的常规:edge 改 typecheck+vitest,Swift 改双端 build;迁移走 db push + regen。

## Self-Review 注记
- Spec 覆盖:5 条用户需求(出站@/看发送者/reply自动@/本地去轮询/远端推送)→ Phase 2/3/2/5/4 + 入站@(Phase 1)+ prompt(Phase 7),全有落点。
- 这是**阶段级 plan**;每阶段的 bite-sized TDD 微步由执行 subagent 在 dispatch 时按"先写失败测试→最小实现→绿→commit"细化(subagent-driven-development)。
- 依赖序:1 → 3 →(2,4,5 可并)→ 6 → 7。Phase 1/3 是其余的地基。
