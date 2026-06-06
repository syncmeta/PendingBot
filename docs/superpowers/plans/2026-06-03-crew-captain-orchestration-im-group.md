# Plan — Crew = IM 群 + captain 编排者（落地核心模型）

**2026-06-03 用户拍板的模型**（对齐 spec §6.3 / §9 / temporary-groups）。

## 模型（钉死）

- **中栏 = 群聊**（像 IM 群，默认视图）。所有成员在群里像成员一样冒泡:**人、captain(bot)、各 session、临时 bot、子 crew 代表**。(跟 captain 私聊 = 后续 1:1 视图;默认群聊。)
- **双轨起 session**:① 人手动在右栏起(已建,保留);② 群里跟 captain 聊,captain 编排起。
- **手动起的 session 自动进群**当成员(`temporary_group_members.member_kind='code_session'`)。
- **captain(一个 bot = LLM,建 crew 时选模型)创建**:session / 子 crew / **临时 bot**(都归 captain)。captain 跑在 edge(bot-reply pipeline),被群消息唤醒(`dispatchGroupTurn`)。
- 成员模型已支持:`member_kind ∈ {human, bot, captain, code_session}`(temporary-groups spec)。

## 现状差距（2026-06-03 核过）

- session 创建（`open_crew_session` RPC）只插 `crew_sessions` + `session_events`,**不插成员行** → live DB 里 `code_session_id` 非空成员 = 0。session 没进群。
- captain bot 建出来存着但**是死的**:没人唤醒、没编排工具、不驱动任何东西。
- 右栏现在是 `人 ↔ 裸 session` 捷径,captain 不在回路。

## 阶段

### Phase H — session/captain 作为群成员 + 花名册
- **H2(先,无迁移)**:edge `GET /v1/crews/:crewId/members`(读 `temporary_group_members` active)+ API `listCrewMembers` + 中栏渲染成员花名册(顶部参与者条)。即便 session 还没进群,先把 **人 + captain** 显出来。
- **H1(需迁移)**:`open_crew_session` / `open_crew_session_for_subject` CREATE OR REPLACE,创建 session 时顺手插一条 `temporary_group_members`(`member_kind='code_session'`, `code_session_id`, display_name=brief 摘要)。session finish 时把成员置 inactive(或保留,UI 用 status 区分)。
- 结果:手动起的 session 自动进群、在花名册里出现;它发言(post_to_crew)+ 读白板(已通)都已是成员行为。

### Phase J — captain 活起来（编排者第一步:会说话）
- edge:POST `/v1/crews/:crewId/messages` 后,若消息**没 @ 具体 session**(或 @captain / 无 @),`waitUntil` → `dispatchGroupTurn` 唤醒 captain bot → 它在群里回话。
- captain 成为群里活的参与者(先只会聊 + 拆解,工具下阶段)。
- 复用我之前查的 captain-triage 那套(captain_bot_id from temporary_group_meta + dispatchGroupTurn)。交互溯源(§10.3-10.5)也并到这。

### Phase J — captain 活起来 ✅（编译/部署,真机未验）
- POST `/v1/crews/:id/messages` 写入会话 `messages` + `waitUntil(dispatchGroupTurn(captain))` → captain 走标准 bot-reply pipeline 回话。中栏 + `/inbox` 改读 `messages`(统一事实源)。
- **真机未验**:captain 真回不回、会不会 `[SILENT]`、钱包够不够。

### Phase K — captain 编排工具
- ✅ **`start_session(brief, runner?)` 已端到端落地**(编译/部署/迁移 applied,真机未验):
  - bot tool(`tool-defs` + `tool-runner` dispatch + `tools/start-session.ts`)—— 门控 crew + captain。
  - RPC `open_crew_session_by_captain`:验 bot 是本 crew captain → 建 `status='queued'` crew_session + H1 成员行。
  - **edge→Mac 通道 = Mac auto-claim 轮询**(`CrewSessionWindowView.autoClaimLoop`):poll `listCrewSessions` 看到 `queued` + 本机空闲 → claim + 用 crew 默认起。captain 在云建 queued 行,Mac 当 executor 跑。**无新 WS/DO**。
  - **无 human-confirm**(人正在跟 captain 聊,local_host 算力免费;只 LLM token 扣 crew 钱包)。
  - **真机未验**:要真 captain LLM 调到 tool + Mac 真接住跑。归 T5.3。
- ✅ **J-e 已落**(2026-06-04,`feat/crew-captain-orchestration`):`post_to_crew` 两路径(bot-reply tool + session HTTP 端点)在写 `crew_announcements` 后**也镜像一条 `messages`**(bot→role='bot'+sender_bot_id;session→role='log'+log_payload.session_id),→ session/bot 发言进群聊显示。best-effort(镜像失败不挡)。
- ✅ **captain persona 已落**(2026-06-04):`apps/edge/prompts/zh/crew-captain.md`(走 prompt-loader)+ `builder.ts` 注入,gated 在 `inGroup && temporary_kind='crew' && status='active' && captain_bot_id==bot.id`,best-effort。让机长被唤醒时知道自己是机长 + 先搞清意图 + 该动手时调 `start_session`。
- **待**:`create_child_crew`(已有 RPC `create_child_crew_inheriting_responsibility_*`)+ `recruit_temp_bot`(member_kind=`ephemeral_bot`,非责任主体)。
- **真机验(归 T5.3)**:captain 真被唤醒会不会调 start_session、Mac 接住跑、session 发言进群显示。

### Phase L（later）— 跟 captain 1:1 私聊视图（默认仍群聊）

## 验证门
- 每阶段 typecheck/build;真机:起 session → 它出现在花名册 + 群里;群里发话 → captain 回。
- captain 编排(K)要真跑 crew + bot 才能验,归 T5.3。

## 暂不做 / YAGNI
- 多 session 并行的完整管理(右栏单 active + 花名册点选切换先够用)。
- 子 crew 的完整 UI(列表 + 进入),Phase K 后。
