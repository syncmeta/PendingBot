# 技术债 / 项目根基风险登记册

这个文件是 PendingBot 的**结构性问题登记册**，由各个 Claude Code / Codex session 在日常开发中**顺手记录**，不是一次性审计的产物。

记什么（按严重度从高到低）：

- 🔴 **根基级** — 影响整个项目、让根基不稳的问题。错误的数据模型、会随规模放大的设计错误、跨模块的隐性耦合、安全/数据一致性隐患、迁移账本漂移之类。
- 🟡 **拆东墙补西墙** — 为了让 A 跑通而硬塞进去、把代价转嫁到 B 的修复；绕过类型/校验/约束的 workaround；复制粘贴而非抽象；"先这样以后再说"的临时实现。
- 🟢 **不规范** — 偏离本仓库既定约定（见 `CLAUDE.md`）的写法、命名、结构；不致命但会慢慢腐蚀一致性。

**不记**：linter/typecheck 已经能抓的纯风格问题、个人口味、与项目健康无关的琐碎 TODO。

## 使用约定

- 发现就追加一条，**只记录、默认不顺手去修**——修一个根基问题往往是独立的一摊活，会冲散当前任务的焦点。除非用户当场要你修。
- 当前任务里如果**新引入**了一个明知是临时/将就的实现，也要主动记一条（诚实标注自己挖的坑），别让它无声沉底。
- 修掉某条后，把 `状态` 改成 `已解决` 并附 commit / 日期，不要直接删——保留它当过的坑的历史。
- 条目按严重度分组；同组内新的放上面。

## 条目格式

```
### 🔴/🟡/🟢 一句话标题
- **发现**: YYYY-MM-DD · 分支或 session
- **位置**: path/to/file.ts:line（或模块名）
- **问题**: 哪里不对
- **影响**: 为什么动摇根基 / 它在替什么遮羞
- **建议**: 该往哪个方向收（可选）
- **状态**: 待办 / 已解决（commit、日期）/ 不修（原因）
```

---

## 🔴 根基级

### 🔴 边缘读投影授权门 ↔ Supabase RLS 对齐是隐式不变量,无测试守护
- **发现**: 2026-06-07 · feat/edge-read-offload(E6 对抗式审查 E4 授权门)
- **位置**: `apps/edge/src/routes/projections.ts`(`/messages/tail` 授权门)+ `apps/edge/src/lib/conv-cache.ts:resolveConv` + `supabase/migrations/*`(`conversations` / `messages` SELECT policies)
- **问题**: 热路径(命中投影 DO)读消息尾完全靠 worker 授权门(`resolveConv` → `conversations` SELECT RLS 可见性)决定放不放行;投影 DO 的内容是 service-client 回填的(绕 RLS),所以**门是热路径唯一权威**。当前是安全的,因为 `conversations` 的两条 SELECT policy(`conversations_participant_read`=is_participant、`conversations_temporary_group_view`=can_view_temporary_group)与 `messages` 的两条 SELECT policy(`messages_participant_read`=is_participant+排除 voice_call_summary、`messages_temporary_group_read`=can_view_temporary_group)**逐条对齐** —— 能看见 conversation 行的人正好能看见它的 messages。但这个对齐是**隐式的、靠人记**:E6 审查时是手工逐条比对 migration 才确认的,没有任何测试/断言守护。
- **影响**: 谁要是以后给 `conversations` 加一条**更宽**的 SELECT policy(让某类用户能看见会话行)却忘了给 `messages` 加对应 policy(或反过来),授权门会基于"能看见 conversation"放行,而热投影把**全量消息尾**喂给一个 RLS 本不允许读消息的用户 → **静默 IDOR**,且冷回落(`tailFromSupabase` 带 user JWT 走 RLS)只在投影 RPC 失败/空时才触发,正常热命中根本不经 RLS,这个洞不会被冷路径兜住。属安全/一致性根基隐患。
- **建议**: ① 在 spec §7.2 的"RLS 可见性规则对照表"里把"`conversations` SELECT 可见性必须 ⊆ `messages` SELECT 可见性"列为显式不变量,且任何动这两表 RLS 的 migration 必须同时复核对侧。② 更硬的做法:加一个 live-DB introspection 测试(或 CI 检查)断言"对每种 conversation_type,能 SELECT conversation 的角色集 == 能 SELECT 其 messages 的角色集",把隐式不变量变成会失败的红灯。③ 或者干脆让热路径授权门改判 `is_participant`/`can_view_temporary_group` 的**成员语义**(而非"能否 SELECT conversation 行"),与 messages 可见性同源,消除两表 policy 漂移的耦合面。
- **状态**: 待办(当前实现已验证安全,这是防回归/防未来漂移的护栏)

### 🔴 welcome bonus 可被 email `+` 别名薅羊毛 — 注册无 email 规范化
- **发现**: 2026-06-04 · feat/managed-config（讨论测试账号怎么收 OTP 时逼出来的）
- **位置**: signup 链路（`auth.users` 唯一性按 email **原文**）+ `apps/edge/src/lib/billing-grant.ts:grantSignupBonus`（welcome 35 PNC ≈ $1.30）
- **问题**: 注册只按 email 原文查重，没有规范化。`user+1@gmail.com` / `user+2@...`（Gmail 还忽略 `.`：`u.s.e.r@gmail.com`）对系统是**不同用户**、对邮箱是**同一个收件箱** → 一个真实 Gmail 能注册无限账号、每个都真实收到 OTP 走完整链路。已有的 `reject_disposable_email`（迁移 0050/0053）只挡一次性邮箱**域名**，挡不住正常域名的 `+`/`.` 别名。
- **影响**: 上线**开计费（`BILLING_ENABLED`）后**，welcome bonus 变成 Sybil / 薅羊毛向量 —— 一个邮箱无限薅 $1.30/账号 的 LLM 额度，规模化就是真金白银损失。现在 kill-switch 关着、bonus 休眠未暴露（**没在烧钱**），但这是**发计费前必须堵的洞**。
- **建议**: 两层。① **抬高造号成本**：注册时 email 规范化（gmail/googlemail 去 `+后缀`+`.`、归一后查重，堵 `+`/`.` 别名；只对已知规则大商做、别误伤小众商）+ 维护 disposable 黑名单 + 注册 rate limit。② **断薅羊毛收益（根本，移动 app 标准做法）**：welcome bonus **绑设备** —— iOS **DeviceCheck / App Attest** 让一台设备只领一次 bonus，跨多少账号都无效（比 email 规范化彻底，攻击者绕不过设备指纹）；或更狠 **绑首充**。**主力做 DeviceCheck，email 规范化当辅助**。
- **决策（2026-06-04）**: 登录**留 email OTP + Apple + Google 并存**（评估过纯 OAuth，最终为不把退路交第三方/email 触达/覆盖面而保留 email）→ 所以防滥用是**明确要做的路线**，不是靠砍 email 规避。
- **状态**: 🟡 进行中 —— **email 规范化半已落**（迁移 20260604102812：`normalize_email` + `welcome_bonus_grants` dedup 账本 + billing-grant `claimWelcomeBonus`；已 push EU + typecheck/497 测试绿，commit 6ab22018）。**DeviceCheck/App Attest 主力半仍待办**（硬卡真机，见 task #252）。

## 🟡 拆东墙补西墙

### 🟡 T2 边缘读 cutover 只 build 验、runtime 从未跑过 + 两处边缘 vs Supabase 精度差
- **发现**: 2026-06-07 · feat/edge-read-cutover（T2 Phase3b）
- **位置**: `apps/pendingbot/Sources/Networking/EdgeReadSource.swift`、`ConversationFetch.list`、`MessagesFetch.latest`；edge 端 `routes/projections.ts` + 两个投影 DO
- **问题**: 会话列表 + 消息尾的读已切成 **edge-first（`/v1/conversations` & `/v1/messages/tail`）+ Supabase fallback**,但**这套边缘端点从未在 runtime 真跑过**——只有 vitest + 双端 build 绿,没有 `wrangler dev` 冒烟、没有真机/真账号验(用户当时定"直接切、build 验证、runtime 留后")。fallback 兜底(任何 error/可疑空 → 回落 Supabase)是唯一的运行期安全网。另有两处边缘行相对 Supabase 的**精度差**:① 边缘列表行无 `last_message_id`(UnreadJoin 该字段 nil;`last_activity_at` 改用 `updated_at` 不丢时间戳);② `user_user` 对端在会话 `user_id==myId` 时,合成 participant 被 `!=myId` 滤掉 → 该行本次刷新无 peer 名(本地缓存旧值或下次 Supabase 刷新补)。
- **影响**: pre-launch、无人用、有 fallback,所以不会崩;但**最终使用路径(iOS/Mac 真机 + 真 Supabase 边缘端点)未验证**——投影/delta/回填/2MB 护栏的 runtime 正确性、列表 hydration 的视觉效果都还是纸面。user_user 人类私聊的列表 peer 名可能短暂空(主要是 user-bot,影响面小)。
- **建议**: ① **runtime 冒烟**:部署 edge(或配 `.dev.vars` 跑 `wrangler dev`)+ 真 JWT 打两个端点,验投影命中/冷回填/授权门/2MB 护栏;② 真机/真账号验首屏(列表 + 开会话)走边缘路径渲染正确、fallback 触发正确;③ user_user peer:客户端映射时**保留本地缓存已有 embed**(别用边缘空值覆盖),或边缘端点解析对端;④ 押后优化:delta cursor(现 full-fetch since=0)、`{__truncated:true}` 富列懒取(现当 nil)。
- **状态**: 进行中（**2026-06-07 server 侧 runtime 已全验**:edge 部署生产(版本 4f90f3f8),用 admin generate_link+verify 拿真 JWT 打线上端点——`/v1/conversations`(冷回填返列表)、`/v1/messages/tail`(冷回填返消息+授权门放行属主)、**授权门 fail-closed 打别人会话→403**、delta(since+epoch 空增量 / 陈旧 epoch→full)、`/v1/models` cf-cache(300)、`/v1/me/account-deletion` request+cancel,全过。**并发现+修复一个真 bug**:非法 sentiment 原冒 500,改 zod 枚举→400(已复验)。**仅剩 app 首屏可视渲染**——需登录态新版 app,而模拟器登录被 CAPTCHA/Apple/OTP 挡死、无自主登录路,只能用户真账号设备做。task #262 in_progress、#265 收窄到 app 可视）

### 🟡 Langfuse prompt 分发的已知取舍（真源切 Langfuse + KV，弃用 bundled .md）
- **发现**: 2026-06-06 · chore/prompt-langfuse-kv
- **位置**: `apps/edge/src/llm/prompt-loader.ts` · `routes/langfuse-prompts.ts`（webhook）· `PROMPTS_KV`
- **问题**: prompt 真源从 bundled `.md` 迁到 Langfuse，运行时经 `PROMPTS_KV` 分发（webhook 推 + pull-on-miss），删了 `.md` 兜底、改 fail-loud。几个明知的尾巴：① **prompt 后端成硬依赖**——Langfuse keys 未配且 KV 空时 `getPrompt` 抛错（LLM 调用 5xx），无 kill-switch（`LANGFUSE_ENABLED` 现在只 gate trace 上报，不再 gate prompt 读取）；② **KV 无 TTL**——webhook 漏了某次更新则 KV 永久 stale（直到 isolate 重启或手动 `invalidatePromptCache`/重灌），`pull-on-miss` 只在 KV 完全无此 key 时触发；③ **webhook 无 version guard**——只认含 `production` label 的事件、正常 label 移动不回退，但乱序投递理论上可写旧版本；④ **发布非全网瞬时一致**——每 isolate 30s 内存 TTL + KV 最终一致传播。另：删 `.md` + Text rule 后 `wrangler deploy --dry-run` 因容器需 Docker（本地未跑）未端到端验证，JS bundle 正确性由 typecheck + 零 `.md` import + 512 vitest 保证。
- **影响**: pre-launch 单人、无真实用户，全部可接受（用户明确「空了就空了、不管中途可用性」）。有真实流量后：①是可用性单点（Langfuse/KV 故障 = prompt 不可用），②可能让线上静默跑陈旧 prompt。
- **建议**: 上线前评估：KV value 加长 TTL（如 6h）作 webhook 漏更新的兜底定期校准；webhook 加 version guard（KV 现有 version 更高则忽略）；或 cron 定期从 Langfuse 重新 seeding KV。
- **状态**: 待办（pre-launch 接受现状）

### 🟡 PendingCrew runner 生终端化 Phase 1 的尾巴
- **发现**: 2026-06-04 · feat/pendingcrew-runner-backends（runner 改内嵌真终端 Phase 1）
- **位置**: `apps/pendingcrew/Sources/Mac/{LocalRunner/AgentTerminalSession.swift, Views/{AgentTerminalView,CrewSessionWindowView}.swift, Services/CrewSessionRunner.swift}`
- **背景**: runner 从一次性 `claude --print`/`codex exec --json` 改成 SwiftTerm `LocalProcessTerminalView` 内嵌交互式 CLI（自动审批 `--dangerously-skip-permissions` / `-a never`），保订阅计费 + 完整交互。spec/plan 见 `docs/superpowers/{specs,plans}/2026-06-04-pendingcrew-runner-*`。Phase 1 只本机闭环。
- **遗留**:
  1. **跨端"看 agent 输出内容"降级**：拔掉了结构化 `RunnerEvent` 推送（旧路径没人验证过、按用户授权干净拔）。远端仍能**控**（命令），但**看不到 agent 具体输出**——待 Phase 2 把 PTY 当 SSH 式字节隧道补回（spec §5）。
  2. **首条 prompt 注入用固定 sleep**（`CrewSessionWindowView.swift` 0.6s/4s）等终端 REPL 启动——脆。正解=检测终端就绪（prompt 锚点）再注入。
  3. **自动审批=放权**：全自动跑 coding agent 有误删风险；靠工作目录 git worktree 隔离 + 真终端可人工介入兜底。
  4. **CLI flag 漂移**：claude/codex 自动审批 flag 写死，升级改名会启动失败——应 fail-loud。
  5. `PendingCrewAPI.appendSessionEvent` 现 caller-less，留作 Phase 2 复用；不用则删。
- **状态**: 待办（Phase 2 隧道补 #1）。**Phase 1 像素级真验未做**——需用户本机 claude/codex 登录态起 app 验终端托管/注入/交互。

### 🟡 captain `recruit_temp_bot` 招的 ephemeral_bot 暂无消费方
- **发现**: 2026-06-05 · feat/crew-captain-orchestration（captain 工具补全）
- **位置**: `apps/edge/src/lib/bot-reply/tools/recruit-temp-bot.ts`（写 `temporary_group_members.member_kind='ephemeral_bot'` + `ephemeral_spec`）
- **问题**: 工具结构上对（无触发器、service-role insert 安全），但招进来的 ephemeral_bot 行**没有任何 edge / iOS 代码读或渲染**——`ephemeral_bot`/`ephemeral_spec` 目前只出现在生成的 schema.ts。即招了也不会在花名册显示、更不会在群里发言/被唤醒。
- **影响**: `recruit_temp_bot` 当前是"结构有效但端到端无效"的半截工具。captain 调它不会出错，但临时 bot 不会真的参与。
- **建议**: 要让它端到端可用，需补：① 花名册渲染 ephemeral_bot 成员；② 一条让 ephemeral 参与者能被唤醒发言的 turn 路径（类似 captain dispatch）。归 captain 编排后续 + T5.3。
- **状态**: 待办（工具已落，消费方待建）

### 🟡 normalize_email 双实现（SQL + TS）须手动保持同步
- **发现**: 2026-06-04 · fix/billing-tails-email-norm（#252 email 规范化）
- **位置**: `pendingbot.normalize_email`（迁移 20260604102812）+ `apps/edge/src/lib/billing-grant.ts:normalizeEmail()`
- **问题**: 同一套规范化规则（lowercase / 去 `+tag` / gmail 去点统域）在 SQL 和 TS 各写一遍。实际跑 welcome-bonus dedup 的是 **TS 版**；SQL 版供未来 DB 侧 hook/对账。两者漂移会出现"DB 认为不同、edge 认为相同"的 Sybil 判定缺口。
- **影响**: 规则演进（新增某大邮箱商别名规则）时漏改一边 → 防薅羊毛静默漏判。
- **建议**: 长期收敛到单一事实源（纯 DB 触发器 或 纯 edge），删另一份；短期两处注释互指（已加）。
- **状态**: 待办

### 🟡 subject_wallets / group_member_billing 物理 drop 卡在多-RPC 重写（#226 尾巴）
- **发现**: 2026-06-04 · fix/billing-tails-email-norm（#226）
- **位置**: 两表 + 写它们的 live SECURITY DEFINER RPC：`open_group_conv`(0048) / 群 join RPC / `bootstrap_user_id` / `group_set_member_mute`(0045) / freeze 触发器 / `grp_create_group_subject` / `getSubjectBalance`
- **问题**: 旧 per-conversation 分摊退役后这两表已无业务读路径（invite 流已解耦，commit 75a3fd10），但仍被一批 live RPC 无脑 INSERT/UPDATE/SELECT，直接 DROP 会断建群/加群/静音/群账号创建。A 段孤儿清理 20260603112148 当初正因此把它们留给 #226。
- **影响**: 迁移账本留两张"僵而不死"的表 + 一摊写它们的死路径，长期 dead-weight + 账本噪声。
- **建议**: 独立 chore —— 先重写这批 RPC 去掉对两表的写/读，再发 DROP 迁移。别夹在别的 lane 顺手做。
- **状态**: 待办（#226 物理 drop 专项）

### 🟡 PendingCrew 群聊 user 作者无法区分是哪个人 — AppModel 不暴露登录 user id — ✅ 已解决 2026-06-05（feat/crew-captain-orchestration）
- **解决**: `GET /v1/me/subject` 新增 `user_id`(device grant → `granted_by_user_id`;user JWT → `c.var.userId`);iOS `UserSubject.userId` 透出,`CrewStore.refreshSubjects` 回填 `AppModel.currentUserId`,`CrewChatView.localUserId` 改指过去。多人 crew 现可区分自己 vs 其他人类。
- **发现**: 2026-06-04 · feat/pendingcrew-chat-align（中栏群聊 UI 对齐，Task 12）
- **位置**: `apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift`（`localUserId` 取 nil）；根因 `apps/pendingcrew/Sources/Stores/AppModel.swift` + `PendingCrewAuthCredential.swift`（只有 `kind`+`token`，opaque `pdg_` device-grant，无 user id）
- **问题**: 新群聊行 `CrewSenderResolver.resolve(...)` 设计支持用 `sender_user_id == localUserId` 区分"我"vs 其他人类成员（左右对齐 + 头像）。但 PendingCrew 的 `AppModel` 没暴露当前登录 user 的 id（device-grant token 不可解出 sub），故 `localUserId` 只能传 nil → **所有 `user` 作者一律落"我"/右对齐**。
- **影响**: BYOK 单人场景**正确**（就一个 human）；但 crew 里有多个真人成员时，别人发的话也会显示成"我"右对齐、不显头像/名字——多人群里人类作者归属错。edge 已把 `sender_user_id` 透出（白板序列化），缺口纯在客户端拿不到本地 user id。
- **建议**: 让 `AppModel` 暴露 `currentUserId`（device-grant 换 token 时一并取/存 user id，或加一个 `/me` 拉一次缓存），再把 `CrewChatView.localUserId` 指过去即可——解析逻辑已就位。
- **状态**: ✅ 已解决（走 `/v1/me/subject` 的 `user_id` 通道,best-effort 在 refreshSubjects 时回填）

### 🟢 bi_ro BI 角色读不了 RLS 受限表 — ✅ 已解决 2026-06-04（#246：security-definer 视图全覆盖 bi_cost_by_category/bi_subjects/bi_group_pool_*；角色已正名 bi_ro）
- **发现**: 2026-06-03 · chore/dashboard-sql-repoint（#238 看板重指 Polar schema）
- **位置**: `supabase/migrations/20260602051354_metabase_readonly_role.sql`（角色 NOBYPASSRLS + 无函数 EXECUTE）;受影响表 `group_pledges`/`group_pools`/`group_contributions`/`bots`/`group_join_requests` 的成员域 RLS policy
- **问题**: `bi_ro`（Grafana Postgres 数据源连接角色，pooler 形式 `bi_ro.<ref>`）是 NOBYPASSRLS,且没有 grant 任何函数 EXECUTE。这些表的 RLS policy 要么 `TO authenticated`(无 auth.uid() 时 0 行匹配),要么 `USING <fn>(...)` 调 `_grp_caller_role`/`is_bot_invitee`/`is_participant`(角色无 EXECUTE → SELECT 直接 42501 报错)。实测:`group_pools`/`group_contributions` 返回 200 但**永远 0 行**;`group_pledges`/`bots`/`group_join_requests` 直接 **500 permission denied for function**。
- **影响**: 看板 03(群池/认缴/实缴)在补 policy 前**全空或报错**;看板 05 的"创建 bot""加入群"两 stage 也一直报错(早于本次改动、与计费重指无关)。BI"看(只读)和改(可写)分家"的设计在 RLS 表上没打通——只读角色拿不到聚合数据。
- **建议**: 已起草 `supabase/migrations/20260603094114_bi_ro_group_billing_read.sql`(给 bi_ro 在 3 张群计费表加 `FOR SELECT TO bi_ro USING (true)` 的宽松读 policy),但 `db push` 被 auto-mode 当作未授权的生产权限变更拦下,**未 apply**(文件留在主 worktree `/dev` 未跟踪,待用户审阅)。`bots`/`group_join_requests` 同类问题需另起一摊(本任务范围外)。决策口径:要么给 bi_ro 逐表加只读 policy + grant 相关函数 EXECUTE,要么为 BI 单独建 `security definer` 聚合视图。
- **状态**: 待办（看板 SQL 已按真实 schema 写对并重导;数据落地等 RLS 读权限收口）

### 🟡 Mac 端消息历史查询仍是 iOS inline 的手抄复刻（其余 4 条已收口）
- **发现**: 2026-06-03 · feat/t45-ios-viewer（#212 真复用收口）
- **位置**: `apps/pendingbot/Sources/Networking/ChatDataSource.swift:loadMessages`；对照 iOS `Features/Message/ConversationView+Loading.swift:402`（18 列超集 → `Row` → cache）
- **问题**: #212 把 Mac 复刻的查询往「共享 fetch、iOS 也改用」方向收口，**已收口 5 块**：实时通道（`RealtimeManager`/`RealtimeSocket` 去 gate，两端同一条自建 RealtimeHubDO，删了 Mac 轮询）、会话列表（`ConversationFetch.list()`）、bot 好友（`BotContactsFetch.list()`）、人类好友（`ContactsFetch.fetch()` + 中性 `ContactProfile`，iOS `ContactsAPI` 改成映射它）、来信（`EnvelopeFetch.list/get`，`EnvelopeRun` 从 iOS-only 移到共享）—— iOS 缓存/富渲染层叠在共享 fetch 上、Mac 投影薄 summary，查询形状单一来源。**仅剩 1 条仍复刻**：消息历史 —— iOS 是 18 列超集喂 GRDB 缓存 + recall/voice-recap/citations/tool-trace/attachments 派发的重管线（#145-147/#150 验证过的最易碎路径），Mac 是 4 列轻读（id/role/content/message_seq）只渲染纯气泡，两者**合理地不同**，强行统一要么逼 Mac 扛它不渲染的 14 列、要么动那条脆弱管线。
- **影响**: 这条查询形状两边各存一份，列漂移时不会编译报错、只在运行期错——属"复制粘贴而非抽象"。但风险被 Mac 只读核心稳定列（id/role/content/message_seq）压低；真正的根治时机是 Mac 渲染富内容（附件/citations）时，那时 Mac 自然需要 iOS 超集行，顺势抽 `MessagesFetch` 最划算。
- **建议**: 等 Mac 接附件/citations 渲染时，把 `ConversationView+Loading` 的 `Row`+查询抽进共享 `MessagesFetch`（iOS 缓存派发叠在上、Mac 投影），收口时进模拟器验 iOS 不回归。
- **状态**: ✅ **已解决（2026-06-03）** —— Mac 接图片附件渲染时顺势收口:新增 `Networking/MessagesFetch.swift`（`MessageRow` 18 列超集 + `AttachmentRef` 从 iOS-only 移来 + `latest()` + `attachmentMeta()`）;iOS `ConversationView+Loading` 改调它（删局部 Row + 内联 attachments 查询,200 行 dispatch 字节级不变）;Mac `ChatDataSource` 改调 + 投影 + 滤 log/deleted/语音 recap + 解析图片附件。**至此 Mac 5 条查询（会话/bot好友/人类好友/来信/消息）全部两端同一份,零手抄复刻**。两端编译过;iOS 消息列表模拟器冒烟无回归（会话内消息因无 tap 工具未点验,改动逐字搬迁+dispatch 未动,风险极低）。剩余 Mac 缺口:bot/会话/来信头像（数据层补 avatar_path）、非图片附件的 icon+name chip、Mac 全屏看图 viewer。

### 🟡 Mac 聊天附件 / 群聊补全 — 未真机验 + 三处未对齐 iOS
- **发现**: 2026-06-04 · feat/mac-login-align（#212 聊天补全：附件 + 群聊）
- **位置**: `apps/pendingbot/Sources/Mac/Views/MacMessagesView.swift`（MacChatView）；`apps/pendingbot/Sources/Networking/ChatDataSource.swift`（`upload`/`loadGroupSenders`/`conversationType`/`sendPeerMessage`/`sendMessage(attachmentIds:)`）
- **问题**: Mac 端补了图片/文件附件（NSOpenPanel → 复用跨平台 `/v1/upload`）+ 群聊渲染（发送者抬头 + 按 type 路由发送：user_bot/self/group 走 SSE，user_user 直插 Supabase）。双端编译过，但**只做了编译校验，没进真机/真账号验**：附件上传回合、群消息收发、user_user 直插的 canonical realtime 行回填都是写操作回合，headless build 回落 ad-hoc 签名跑不了登录态，需 Xcode GUI 构建 + 真账号点验。三处刻意**未对齐 iOS**：(1) 上传图片**无客户端压缩**——iOS `encodeImageForUpload` 把库内 HEIC/大图降到 2048px JPEG，Mac 直传原图（大图慢 + 可能超 vision 内联上限，bot 看不到图但 chip 仍在）；(2) **无 @提及**（iOS 这块也未定型，本轮明确不做）；(3) **无附件全屏查看器**（iOS 有 `ImageViewer` 但 iOS-only，Mac 点图不放大）。另外群发送者 `loadGroupSenders` 无本地缓存预热（iOS 有 GRDB `hydrateGroupSendersFromCache` 先画再网络刷新），Mac 首帧群抬头会闪一下 seed 头像再补真名。
- **影响**: 中。附件/群聊的"骨架可用"已具备且复用经验证的后端通道，但 (a) 整条写路径未真机验，(b) 无图片压缩在弱网/大图下体验差且可能触发"上传了但 bot 看不见"的隐性失败。
- **建议**: 真机验三条写回合（附件发送、群收发、user_user 1:1）；把 iOS `encodeImageForUpload` 的 2048px JPEG 压缩抽成跨平台 helper（用 `PlatformImage` / CoreGraphics，避开 UIKit），Mac 上传图片前走它；@提及 / 全屏看图待 iOS 这两块定型后再镜像。
- **状态**: 待真机验 + 三处对齐缺口未补

## 🔴 根基级

### 🔴 Bot 公开分享链路被 `bots` 表 RLS 堵死 — 陌生人扫码/点链接解析 public_invite bot 命中 0 行
- **发现**: 2026-06-01 · chore/progress-ledger（对账 task #121-128 时实测）
- **位置**: `supabase/migrations/20260527091508_drop_public_open_visibility.sql:56`（`bots_visible_read` policy）、`supabase/migrations/0022_fix_bots_rls_recursion.sql:15`（`is_bot_invitee`）、`apps/pendingbot/Sources/Features/Friends/FriendsTabView.swift:1944`（`runLookup` 直查 supabase）
- **问题**: bot 分享功能（slug / 二维码 / Universal Link，task #121-128）代码已几乎全做完且提交，但 iOS 解析 slug 是**直接查 Supabase** `bots` 表、靠 RLS 控可见性。唯一的 SELECT policy `bots_visible_read` 对 `public_invite` bot 要求 `is_bot_invitee(id, auth.uid())` —— 而该函数只在 `bot_invites` 表有预先邀请行时为真（邀请只能由 bot 主人按 handle 主动塞）。陌生人扫码/点分享链接时**还不是被邀请人** → SELECT 命中 0 行 → iOS 显示"找不到这个机器人,或者它不允许你加入"。
- **影响**: 整个分享链路（slug→二维码→扫码→universal link→AddBotPreviewPage）对"非预先邀请者"全部走不通 —— 而分享功能的**全部意义**就是给陌生人加。UI 文案还写着"别人按这个标识、链接或二维码加你的机器人",与 RLS 实际行为直接矛盾。这是个"iOS+edge 表层都做了、DB 授权层没跟上"导致的 ship 即坏缺口。edge 侧也确认没有任何按 slug 解析 bot 的路由（纯靠 client 直查）。
- **建议**: 二选一：(a) 放宽 `bots_visible_read`，让 `visibility='public_invite'` 对所有 authenticated 可 SELECT（public 的本意就是可被发现自加）；(b) 加一个 service-role 的 `GET /b/:slug` 解析端点，绕开 client 直查 + RLS。改完跑 #128 验证（含真机扫码闭环），通后翻 #121-128 状态。注意 `is_bot_invitee` 的"单向门"语义要和 spec `project_bot_visibility` 对齐确认。
- **状态**: ✅ **已解决/被取代（2026-06-03 核实）** —— 旧的「client 直查 bots 表靠 RLS」分享路径已被**邀请链接模型**(decisions.md D1，task #191-194)整体取代：`bot_invite_links` 表 + `apps/edge/src/routes/bot-invites.ts` 的 `GET /v1/bot-invites/:token`(service-role RPC `bot_invite_link_resolve` 预览) + `POST /:token/redeem`(`bot_invite_link_redeem` 授予)。iOS 走 `resolveBotInvite`/`redeemBotInvite` 经 worker，**不再 client 直查 bots 表**，所以 RLS 堵死的结构性病根消失(redeem 由 service-role 写，bots/user_bot_contacts RLS 保持严格)。注:这是「结构性 blocker 消失」，完整的陌生人扫码闭环真机 QA 仍未单独跑(并入分享功能整体验证)。

### 🔴 PendingBot Mac 端业务接入只覆盖 5 tab 中的 1 个,其余仍是 placeholder
- **发现**: 2026-05-29 · feat/mac-multiplat-t01-p0(worktree wf_bb2bdb07-141-5)
- **位置**: `apps/pendingbot/Sources/Mac/MacRootView.swift`、`apps/pendingbot/Sources/Features/**`、`apps/pendingbot/project.yml`
- **问题**: T0.1 P0 把 `project.yml` 里的 `EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]` 大锅排除摘掉了,改用 `#if os(iOS) ... #endif` 包住每个 iOS-only 文件。但实际包了 `Sources/Components/*` + `Sources/Features/*` 整两层目录(再加 Networking 里 7 个文件),原因是这些目录里的 UI 类全部转性依赖 UIKit / PushKit / CallKit / Theme(UIColor) / Haptics(UIKit)。Mac build 现在能过,但能拿来用的 Mac 真实视图只有 `MacMeView`(账号信息 + 退出登录),消息 / 好友 / Crew / 来信 4 个 tab 仍是 `MacTabPlaceholder`。
- **影响**: 用户在 Mac 端只能看自己账号 + 登出,看不到任何聊天、好友、Crew、来信内容 — Mac 端基本不可用。后续 T0.1 P1+P2 真正接业务时,要把 iOS 业务里 UIKit-tied 的小部件抽成 cross-platform 等价物(`UIImage`→`Image+platform helper`、`UIPasteboard`→`NSPasteboard`、`Haptics`→Mac noop、`UIViewRepresentable` 桥不能用要找 SwiftUI 等价或 Mac-only 重写),工作量按文件数估在 30+ 文件级别;短期不可能"开关一拨就好"。
- **建议**: T0.1 P1 — 先把 Models / Storage / Networking 里已 cross-platform 的部分往上抽通用 `Theme` / `PlatformColor` / `PlatformImage` 抽象层,让 `Sources/Components/` 里小部件(`UserAvatar` / `BotAvatar` / `Theme` / `Haptics` / `Platform` / `RelativeMessageTime` / `EmptyHint`)能不带 `#if os(iOS)` 编译过 Mac;T0.1 P2 — 接 `MessageTabView` 等价物(读 supabase `conversations` + 走 `ChatStream` 已是纯 Foundation),把"消息" tab 做出来。Crew / Call 强依赖 PushKit/CallKit 的,Mac 端等 v2 再说。
- **状态**: 部分完成（P0 + P1 好友 tab — 2026-05-30。P1: ContactsAPI 解耦成 view-independent `ContactProfile`(Networking 现可在 Mac 编译)、`HumanPick(_:ContactProfile)` 映射、`MacFriendsView` 接入好友 tab 显示真实联系人,替换 placeholder;Mac+iOS build 双绿。剩余 P2: 消息 / Crew / 来信 3 个 tab 仍 placeholder — 消息 tab 依赖 `Features/Message/*` 的 UIKit 拆层,工作量最大。见 commit 388f24fd/4eff9d8e(P0) + 本轮 Mac IM merge。）

### ✅ Apple IAP JWS 验证未实现 — IAP 路由当前 fail-closed
- **发现**: 2026-05-29 · feat/billing-v2-webhooks
- **位置**: `apps/edge/src/lib/billing-v2-iap.ts:verifyAppleJws`
- **问题**: `/v1/billing/iap/purchase` 和 `/v1/billing/iap/notify` 已经接入了数据流（idempotency、pack 发放、refund_events、handler 分发），但 JWS 签名校验函数直接 `throw new Error('apple_jws_verification_not_implemented')`，所有 Apple 路径目前返回 501。原因：Workers 没有内置 X.509 解析，要实现 Apple ASN V2 完整链验证需要手写 ASN.1/DER 解码 + ECDSA P-256 链验证 + Apple Root CA G2/G3 指纹固定化，工作量不小。
- **影响**: 上 iOS IAP 之前必须先解决，否则要么 Apple 充值彻底跑不通、要么用环境变量 bypass 验证（已被显式拒绝写入代码以避免静默旁路）。Lemon Squeezy（HMAC-SHA256）已完整实现，所以上架顺序可以先 LS / Web、再补 Apple。
- **建议**: 实现路径已写在 `verifyAppleJws` 函数注释里：(1) 解 JWS header.x5c → 3 张 DER cert；(2) ASN.1 解 X.509 取 SPKI + issuer；(3) 链验证（leaf signed by intermediate, intermediate by root, ECDSA-P256）；(4) Root SHA-256 比对 Apple Root CA G2 / G3 内嵌指纹；(5) 校验 NotBefore/NotAfter；(6) importKey('spki', leaf.spki, 'ECDSA P-256') + verify on signing input；(7) 校验 `iss==='Apple Inc.'` 和 `bundleId === env.APPLE_IAP_BUNDLE_ID`。落地后，本文件这条状态置为已解决。
- **状态**: ✅ 已修复（2026-05-30 · 零依赖手写 DER/ASN.1。新增 `apps/edge/src/lib/billing-v2-iap-verify.ts`：`verifyAppleJwsChain` 做 x5c 链解码 → 每张 cert 解析（SPKI/validity/ECDSA 签名 DER→JOSE raw）→ **Apple Root CA G3 SHA-256 根固定**（常量已用 openssl 双工具核对官方 cert）→ validity 窗口 → 链验证（leaf←intermediate←root + root 自签）→ SubtleCrypto ES256 验 `header.payload` → decode payload。`verifyAppleJws` 改为调它 + `bundleId===env.APPLE_IAP_BUNDLE_ID` 断言，函数签名不变、三个 caller 零改动。单测 `billing-v2-iap.test.ts` 用 SubtleCrypto 现造 P-256 三级链 + DER builder，覆盖 happy/篡改/错根/断链/过期/非ES256/默认pin拒自签根/签名输入字节——14 测全绿，typecheck 0 error。**仍待真机**：无真实 Apple sandbox JWS，端到端未跑，首次接 iOS IAP 时需用 sandbox 交易回归一次。）

### 🔴 计费事实源、成本字段和销售 markup 混在旧 credits 框架里
- **发现**: 2026-05-29 · codex/billing-v2-design
- **位置**: `apps/edge/src/llm/router.ts`、`apps/edge/src/lib/billing.ts`、`apps/edge/src/lib/ai-gateway.ts`、`supabase/migrations/20260514065304_local_cost_billing.sql`、`supabase/migrations/20260516042918_drop_audit_observability.sql`
- **问题**: 现有计费路径把 provider-reported cost、AI Gateway cost、本地价格表估算、voice 本地计算、web tool 成本和 runtime markup 折进 `audit_log.cost_usd` / `tool_cost_usd` / `cost_credits` 这组旧字段里。历史迁移曾把 `cost_usd` 从“provider cost”改成“local pricebook cost”，后续又删掉 `provider_cost_usd` 和 raw model call 表并转向 AI Gateway 作为事实源，导致字段名、注释和实际结算语义互相打架。
- **影响**: 新增服务计费时容易继续塞进 parent audit 单列，无法清楚解释“供应商真实成本、用户扣减单位、销售利润”三者关系；余额门槛也只能用粗糙固定阈值，无法按服务预授权。当前已出现有 token 且 Gateway 有成本但落成 `skipped` 的行，说明计费链路缺少明确的 settling/failure 状态。
- **建议**: 以 `docs/billing-v2-design.md` 为目标态重做：PNC 作为成本单位，`27 PNC = 1 USD`；运行时不加 markup，销售 pack 时加 markup；用 usage events + pack ledger + reserve/settle 替代单列 `cost_credits`；所有 LLM、工具、语音、RealtimeKit、sandbox、存储等变量成本都进入统一 usage event。
- **状态**: 待办

### 🟡 Sandbox runtime usage_event 暂以 vendor_cost_usd=0 落账
- **发现**: 2026-05-29 · worktree-wf_bb2bdb07-141-3 (#183 billing v2 sandbox 接入)
- **位置**: `apps/edge/src/lib/sandbox.ts` (`runPython`)
- **问题**: billing v2 给 sandbox 加上了 `sandbox_runtime` usage_event 行（记录 elapsed seconds + conversation/owner），但 Cloudflare Sandbox 的 per-second container 价格目前没在 worker 里维护，所以 `vendor_cost_usd` 暂时硬写 0、`cost_source='manual'`。usage_event 行存在、ledger 不扣钱。
- **影响**: pre-launch 没有真实滥用流量，先记录形态再补价格是合理的折中；但发布前必须有真实价目，否则用户跑无限循环代码不计费。同样的 hole 也存在于 storage_transfer / push_delivery，这两类目前完全没接入。
- **建议**: (1) 把 Cloudflare Sandbox 的 container 价格表（memory-seconds + disk + network egress）建成 `sandbox_prices` 表，跟 `web_tool_prices` 同一个模式；(2) `runPython` 里改用真实价目算 `vendor_cost_usd`；(3) 顺手把 R2 上传/下载/转码、APNs 短信/邮件按同样的 usage_event + pricebook 模式补齐。
- **状态**: 部分迁移（2026-06-02 · billing P2 Phase F）。`runPython` 已从旧 billing-v2 `settleUsage(vendor_cost_usd=0)` 改为接 WalletDO（`wallet.gate` 前置门禁 + `wallet.debit('sandbox_runtime')` 后置扣费），不再写 0。但**价格仍是占位**（见下方新条目「sandbox 真实单价 + 计量维度待定」），核心 hole（无真实价目）未关。

### 🔴 Edge 用户态路由里 service-role 鉴权边界过于分散
- **发现**: 2026-05-25 · codex/security-architecture-audit
- **位置**: `apps/edge/src/routes/messages.ts`、`apps/edge/src/routes/groups.ts`、`apps/edge/src/routes/group-voice.ts`、`apps/edge/src/routes/contacts.ts`、`apps/edge/src/routes/friend-requests.ts`
- **问题**: 多个用户可调用的 route 在 `requireSession()` 后直接使用 `serviceClient()` 绕过 RLS，再在 handler 内用本地查询、RPC 或 if 分支证明 membership/admin/owner。单个点大多有检查，但检查语义分散在大文件里，缺少统一的“以用户身份解析资源 + 明确提升到 service-role 写派生状态”的边界。
- **影响**: 越权风险会随功能增长放大：新增分支很容易漏掉某一种 conversation type、subject role、deleted/withdrawn 状态或 billing ownership；审计也只能逐个 handler 追踪，难以证明最小权限。
- **建议**: 收敛出 route 级授权层，例如 `loadConversationForUser`、`requireGroupRole`、`requireSubjectRole`、`withServiceWriteAfterAuthz`，并为每类资源维护一套负向授权测试；优先拆 `messages.ts`、`groups.ts`、`group-voice.ts` 这种 800+ 行入口。
- **状态**: 部分修复（2026-05-25 · 新增 `apps/edge/src/lib/route-authz.ts` 和 `route-authz.test.ts`，`groups.ts` / `group-voice.ts` 的 group conversation、human/bot participant、owner/admin 检查已迁入共享 helper；`contacts.ts` 的 singleton `user_user` 会话查找已收敛到 `findSharedUserUserConversation`，`open-chat` 创建已下沉到带 advisory lock 的 `open_user_user_conv` RPC，防止多设备并发创建重复 1v1 会话；`messages.ts` 的 hard delete 权限已迁入 `authorizeMessageDelete`，recall 权限已迁入 `authorizeMessageRecall`，普通发消息会话/peer-gone 检查已迁入 `authorizeMessageSendConversation`，附件所有权检查已迁入 `authorizeAttachmentOwnership` 并复用于普通发送和首轮 `/messages/start`，并修复“群主硬删别人群消息”的越权边界；`friend-requests.ts` 的 peer-id 加好友必须带 source group 并验证双方同群；`messages.ts` normal send / regenerate 共用 `authorizeBotUse`，修复 regenerate 漏掉 revoked `public_invite` 复核的问题；runner host 执行面已收敛为 device-grant only，旧 user-JWT runner register/heartbeat/claim/event/finish RPC 从 authenticated 撤权；`messages.ts` 三条 bot turn 路径的 pinned model / arena random routing 已收敛到 `resolveMessageBotTurnRoute`，余额 402 payload 与 auto-lookback parent lookup 已抽成本地 helper。剩余主要是继续把普通发送 Phase 2 前置阶段拆成更小的可测试 primitive。）

### 🔴 线上 `pendingbot` exposed schema 有 `SECURITY DEFINER` 函数对 anon 可执行
- **发现**: 2026-05-24 · codex/security-architecture-audit
- **位置**: supabase/migrations/0033_billing.sql、supabase/migrations/0034_billing_admin_rpcs.sql、Supabase live advisors
- **问题**: 线上库里多组 `SECURITY DEFINER` 函数在暴露给 PostgREST 的 `pendingbot` schema 下仍允许 `anon`/`authenticated` 执行，包括 `billing_admin_grant`、`billing_credit`、`billing_debit`、`billing_issue_codes`、`start_user_bot_turn`、`open_self_conv` 等。Supabase advisor 和 `has_function_privilege()` 查询都确认这不是静态误报。
- **影响**: 任何漏掉内部鉴权的 definer RPC 都会绕过 RLS 直接以 owner 权限写账本、开会话或改业务状态；这违反最小权限原则，是计费和越权面的最高优先级风险。
- **建议**: 新增权限收敛迁移：先 `REVOKE EXECUTE ON FUNCTION ... FROM PUBLIC, anon, authenticated`，只给确需客户端调用的 RPC 授权；内部/触发器/worker-only 函数移到未暴露 schema 或仅授予 `service_role`；同时为 definer 函数固定 `search_path` 并跑 Supabase security advisors 验证清零。
- **状态**: 已修复（2026-05-25 · 新增 `20260524175632_harden_function_execute_privileges.sql`，默认撤销 exposed schemas 的函数执行权，仅给客户端必需 RPC 重新授权，billing/bootstrap/trigger/internal 函数仅保留 `service_role`。仍需部署后跑 Supabase advisor 复核现网。）

### ✅ 设备授权审批可由客户端请求体放大 scope
- **发现**: 2026-05-24 · codex/security-architecture-audit
- **位置**: apps/edge/src/routes/device-login.ts:52、apps/edge/src/routes/device-login.ts:237、apps/edge/src/lib/device-grants.ts:83、supabase/migrations/20260524122559_subject_device_login_grants.sql
- **问题**: `/device-login/challenges/:id/approve` 只按 `grantKind` 调 `subject_can_authorize_device_grant`，但最终写入的 `requested_scopes` 直接来自 approve 请求体。`pendingcrew_control` 这类授权通过后，客户端仍可提交 `runner:write` / `runner:read`，后续 `requireSubjectAuth()` 只信任 grant row 的 scopes。
- **影响**: 用户只具备 crew 控制能力时，可能铸出 runner 能力 token，越过 `subject_can_manage_runners` 的意图边界。
- **建议**: 服务端按 `grantKind` 和 subject role 派生允许的 scope 集合，拒绝任何超集；或把 scope 校验下沉到 `subject_can_authorize_device_grant` / consume RPC，保证数据库里永远不会落入过宽 grant。
- **状态**: 已修复（2026-05-25 · `device-login.ts` 按 `grantKind` 限制 scope，且批准 scope 必须是原 challenge 请求 scope 的子集；`device-login.test.ts` 覆盖 control grant 不能带 runner scope、app/grant mismatch、consume 后 token scope。）

### 🔴 群聊计费跳过用户后没有落库排除状态
- **发现**: 2026-05-24 · codex/security-architecture-audit
- **位置**: apps/edge/src/lib/group-billing.ts:17、apps/edge/src/lib/group-billing.ts:183、supabase/migrations/0045_group_chat_rpcs.sql:1046、supabase/migrations/0066_group_member_freeze_and_default_handle.sql
- **问题**: 初次审计只看了 0045 里的旧函数体，那里 `apply_audit_split` 确实只在 `debited` 时更新 `group_member_billing`；但后续 0066 已用 `CREATE OR REPLACE FUNCTION` 覆盖该函数，并在 `skipped_overdrawn` / `skipped_capped` 时设置 `overdrawn=true`。
- **影响**: 已核实线上函数体包含 skipped 分支，当前不再是 live 风险；保留该条作为“旧函数体容易误判/回归”的历史记录。
- **建议**: 保留回归测试覆盖“迁移历史最终函数体包含 skipped 状态处理”，后续如果重写 `apply_audit_split` 必须同时保留这个分支。
- **状态**: 已解决（0066 已覆盖；2026-05-25 线上 `pg_get_functiondef` 确认）

### ✅ 附件 RLS 与 Worker 下载口径不一致，可能泄露附件元数据
- **发现**: 2026-05-24 · codex/security-architecture-audit
- **位置**: apps/edge/src/routes/upload.ts:331、supabase/migrations/0063_attachments_rls_avatar_visibility.sql:18
- **问题**: Worker 下载路径要求“上传者或当前参与者且存在未删除消息引用该附件”，但最新附件 RLS 允许任意当前会话参与者按 `attachments.conversation_id` 读取 attachment 行，和消息引用/删除状态无关。
- **影响**: 直接 PostgREST 读取可能暴露附件文件名、mime、大小、摘要、tags、`r2_key` 等元数据；消息撤回/删除后 raw bytes 仍由 Worker 挡住，但 DB 元数据隐私语义已经漂移。
- **建议**: 恢复 chat attachment 的 DB 读取为 uploader-only 或基于未删除 message reference 的 policy；头像可拆独立公开字段/头像表，不要把头像例外扩大到所有 conversation-bound 附件。
- **状态**: 已修复（2026-05-25 · `20260524175919_tighten_attachment_read_policy.sql` 将 DB metadata SELECT 收敛到 uploader、头像引用、或当前参与者可见的未删除消息引用；`migrations-security.test.ts` 覆盖 message reference / non-deleted / participant 条件。仍需部署后复核现网 policy。）

### ✅ Crew / 临时群 subject 钱包尚未接入 LLM 审计扣费分支
- **发现**: 2026-05-24 · codex/security-architecture-audit
- **位置**: apps/edge/src/llm/router.ts:386、docs/superpowers/specs/2026-05-24-crew-temporary-groups-design.md
- **问题**: 审计扣费当前只识别 `conversation_type = 'group'` 走 split，或 `opts.userId` 走单用户扣费；`temporary_group` / `crew` 的 `responsible_subject_id` 与 `billing_debit_subject` 尚未进入统一 audit billing 分支。
- **影响**: 如果 Crew / 临时群的模型或工具调用只带 `conversationId` 而不带 `userId`，初始状态会落到 `free`；如果临时补传某个人类 `userId`，又会绕过 subject wallet 的责任主体设计。
- **建议**: audit 层解析 billable subject：1v1 user、普通群 split、Crew/临时群 responsible subject 三类互斥；账本行记录 subject snapshot，避免以后靠调用方散落传参兜底。
- **状态**: 已修复（2026-05-25 · `apps/edge/src/llm/router.ts` 现在按 conversation type 解析 group split / responsible subject / legacy user；Crew 与临时群走 `billing_debit_subject`，audit metadata 记录 billing target。）

### ✅ definer helper 可被直接 RPC 传入别人的 user id 做关系探测
- **发现**: 2026-05-25 · codex/security-architecture-audit
- **位置**: `subject_has_user_access`、`subject_user_has_role`、`subject_can_authorize_device_grant`、Crew/runner/temporary-group view helpers
- **问题**: 这些函数为了给 RLS policy 使用而授予 authenticated 执行权；policy 里传的是 `auth.uid()`，但直接 `/rpc` 调用可传入任意 `p_user_id`，从而探测别人是否能看某个 subject / crew / runner 资源。
- **影响**: 不直接泄露业务行内容，但泄露成员关系、权限关系和资源存在性；如果后续 helper 扩展返回更细信息，风险会放大。
- **建议**: helper 内部绑定调用者：service_role 允许显式 user id；普通 authenticated 调用必须满足 `p_user_id = auth.uid()`。
- **状态**: 已修复（2026-05-25 · `20260524180643_bind_definer_helpers_to_auth_uid.sql`）

### ✅ legacy helper / trigger 函数缺少固定 search_path
- **发现**: 2026-05-25 · codex/security-architecture-audit
- **位置**: `uuidv7`、preset handle helpers、`bootstrap_new_user_trigger`、group billing freeze trigger 等 Supabase advisor 报告项
- **问题**: 部分早期函数没有 `SET search_path`，执行时受 role-level search_path 影响。
- **影响**: 对 definer/trigger 函数来说这是对象解析劫持面；当前多数函数体已 schema-qualified，但 advisor 仍会持续报警，且未来函数体改动容易踩坑。
- **建议**: 对存量函数统一 `ALTER FUNCTION ... SET search_path`，新函数默认在定义里写死 search_path。
- **状态**: 已修复（2026-05-25 · `20260524181807_pin_legacy_function_search_path.sql`）

### ✅ Realtime metering 诊断日志记录了完整上游 session 事件
- **发现**: 2026-05-25 · codex/security-architecture-audit
- **位置**: `apps/edge/src/durable-objects/realtime-meter.ts`
- **问题**: `session.created` / `session.updated` 事件被 `JSON.stringify(msg)` 后写入日志；这些事件可能包含由机器人记忆、备注、技能和会话上下文拼出的 realtime instructions。
- **影响**: Cloudflare logs / `wrangler tail` 可能暴露用户私密上下文或机器人内部提示词；这属于排障便利性覆盖隐私边界。
- **建议**: 语音/模型上游事件日志只允许字段白名单；需要调试 payload 时走短期、显式、脱敏的诊断开关。
- **状态**: 已修复（2026-05-25 · RealtimeMeter 只记录事件类型、session id、model、错误 code/type，并新增 `privacy-logging.test.ts` 防止整包日志回归。）

## 🟡 拆东墙补西墙

### 🟡 Mac 端整体业务子树被 build settings 排除，三端 IM 实质上还是 iOS-only
- **发现**: 2026-05-29 · feat/mac-3col-shell
- **位置**: `apps/pendingbot/project.yml`（`EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]`：`Components/* Features/* Models/* Networking/* Storage/*`）、`apps/pendingbot/Sources/Mac/MacRootView.swift`、`apps/pendingbot/Sources/Features/Message/*`（顶层 `import UIKit` + `UIViewRepresentable` + `UIImagePickerController` + `UIScreen.main`，无 `#if os(iOS)` 门）
- **问题**: spec v2 §11 三端齐目标要求 Mac 端跑通普通 IM，但当前为了让 Mac 能 build，`project.yml` 一刀把 `Features/ Components/ Models/ Networking/ Storage/` 整个子树从 macOS target 排除。`MacRootView` 因此只能渲染纯占位 3 列 shell（sidebar/list/detail 都是空态文案）——没有 `AccountStore`、没有 `APIClient`、没有任何会话或好友数据可读。Features/Message 那一堆（`ConversationView`、`BubbleView`、`ComposerView`、`ChatComposerAccessory`、`ChatActionSheet`、`MessageTabView`）也都顶层 `import UIKit`,直接共用要 (a) 在几十个文件里加 `#if os(iOS)` 门 + Mac 替代实现 (b) 把 UIKit 部分下沉到一个 iOS-only Components 层。
- **影响**: Mac 端会一直停在"空壳"阶段——每加一个 Mac 业务功能，都要先拆一刀 UIKit 门或者整段重写跨平台版。任由它发展，最终会形成"iOS 业务代码 + Mac 重写"两套并行实现的根基级分裂；T4.6 Crew Tab V2 多端方案能成立，是因为 Crew 一开始就走 SwiftUI-only。普通 IM 这块没有同样的预算，相当于 spec §11 三端齐目标被偷偷降级成"iOS+iPad 齐,Mac 占位"。
- **建议**: 接 Mac IM 之前必须先做一次跨平台抽层，至少这几步：(1) 把 `Models/`、`Storage/AccountStore`、`Storage/UnreadStore`、`Networking/APIClient`、`Networking/RealtimeManager` 等纯 Foundation 模块从 macOS 的 EXCLUDED 列表里拿出来（这些文件已经不 import UIKit）；(2) `Features/Message/*` 里 UIViewRepresentable 子组件抽进 `Components/iOS/` 子目录,顶层 view 用 `#if os(iOS)` / `#if os(macOS)` 各跑一份；(3) 写明哪些 iOS-only 能力（CallKit/PushKit/相机/UIImage 编码）在 Mac 上的对应方案（不做 / NSImage / 文件选择器）。短期不要为了多接一个 tab 而随手加 `#if`，会让以后真正拆层时阻力越大。
- **状态**: 待办（T1.4 stream 升级 Mac shell 到三列结构,但中间和右栏仍是 placeholder；真正的 Mac IM 接入留给后续 Phase 2+ stream）
=======
### 🟡 通话内 voice_cost 实时预览还在用 v1 PND markup（与 v2 PNC 钱包单位不一致）
- **发现**: 2026-05-29 · feat/billing-v2-cutover
- **位置**: `apps/edge/src/lib/voice-metering.ts:broadcastVoiceCostPreview`（getMarkup + usdToPnd）、`apps/edge/src/durable-objects/room-voice.ts:broadcastCost`、iOS `RealtimeSocket`/`Manager` 的 `voice_cost` 处理（`delta_pnd`/`cumulative_pnd` 字段）
- **问题**: billing v2 cutover 后，权威扣费已全部走 v2 PNC（settleUsage）。但通话过程中给客户端广播的"本次通话已花费"实时预览仍走 v1 路径：`getMarkup(billing_config.markup) × usdToPnd`，单位是 PND ∂，字段名 `delta_pnd`/`cumulative_pnd`。用户在通话里看到 ∂ 估算，挂断后进钱包看到的是 PNC——单位对不上。
- **影响**: 纯展示层不一致，不影响真实扣费（扣费已是 v2 权威）。但用户体验割裂；且这是 billing.ts 里 getMarkup/usdToPnd 仅剩的运行时调用点，挡着把这两个 v1 函数彻底删掉。
- **建议**: 把广播改成 PNC：`usdToPncMicros(costUsd)` 累加，字段改 `delta_pnc_micros`/`cumulative_pnc_micros`，iOS voice_cost 处理同步改单位 + 文案。改完即可从 billing.ts 删 getMarkup/usdToPnd。
- **状态**: 待办

### 🟡 v1 billing 表 + 死函数在 cutover 后留作冷备，未删
- **发现**: 2026-05-29 · feat/billing-v2-cutover
- **位置**: `users.balance_credits` / `subject_wallets` / `billing_ledger` / `topups` / `redemption_codes` / `group_member_billing` 表；`apps/edge/src/lib/billing.ts`（getBalance/getMarkup/usdToPnd/billingDebit/billingDebitSubject/getThreshold 等）、`apps/edge/src/lib/group-billing.ts`（splitAndDebit 整文件）
- **问题**: billing v2 cutover 让 v2 成为权威，v1 的扣费/gate 逻辑已不再被运行时调用（gate 已改读 v2 packs，debit 已改 settleUsage）。但 v1 的表和一批导出函数留着没删——作为一个周期的冷备，万一迁移有遗漏可回查。`/v1/me/balance`、`/v1/me/redeem`、`group-billing.ts`、`billing.ts` 的大部分导出现在是死代码（仅被自己的单测引用）。
- **影响**: 死代码 + 未用表，读代码时容易误以为还在用 v1；balance-cache.ts 的 KV 缓存也不再被写。不致命，但要在 v2 线上跑稳一个周期后清掉。
- **建议**: 跑稳后开 chore 分支：删 group-billing.ts、billing.ts 里 v1-only 导出、/me/balance + /me/redeem（或改 redeem 走 v2 issuePack）、balance-cache.ts；再写一个 drop-v1-tables 迁移（备份后 DROP）。
- **状态**: 待办

### 🟡 sandbox / container runtime 没有任何计费路径（v1 + v2 都缺）
- **发现**: 2026-05-29 · feat/billing-v2-services
- **位置**: `apps/edge/src/lib/sandbox.ts`、`apps/edge/src/routes/code-exec.ts`、`docs/billing-v2-design.md` §5 `sandbox_runtime`
- **问题**: billing v2 design §5 把 `sandbox_runtime`（container/runtime 秒数、磁盘、网络）列为应纳入 PNC 账本的成本分类，但 v1 从来没有给 sandbox 计过费，code-exec 工具调用 Cloudflare Sandbox SDK 时不产生任何 usage_event / audit cost。因此 billing v2 dual-write（#183）也无从镜像——没有可镜像的 v1 成本。当前 `dualWriteV2` 只接了 model 成本（llm/voice）和 web_tools。
- **影响**: 沙盒是可被滥用的变量成本（长时间运行的 container、磁盘、egress），目前完全免费。用户可以无限跑 execute_code 不掉余额。pre-launch、单人、沙盒 auto-sleep 的现状下风险有限，但发布前必须补上，否则是一个开口的成本漏洞。
- **建议**: 在 sandbox 生命周期（启动→运行→sleep）打点 container-seconds，按 Cloudflare Sandbox 计价转 `vendor_cost_usd`，走 `settleUsage({category:'sandbox_runtime', quantityUnit:'seconds'})`。design doc §7 要求 sandbox 走周期 settle + 余额 ≤ 0 立即终止容器——这部分要和 sandbox.ts 的 sleepAfter 生命周期一起做。
- **状态**: ✅ 基本闭合（2026-06-02 · billing P2 Phase F）。`runPython` 现在：执行前 `wallet.gate`（`exhausted` 抛 `SandboxGateError`，code-exec 工具转「余额用完」文案，不跑代码）；执行后按 wall-clock 秒数扣 `wallet.debit(category:'sandbox_runtime')`，dedupeId=`sandbox:<conv>:<startedAt>` 幂等。subjectId 复用 router 解析（群/临时群/crew→`responsible_subject_id`，否则发起 userId）。**仍未做**：周期 settle + 余额≤0 中途终止容器（当前最小可用=执行完一次性扣，30s 超时已封顶单次成本，长任务跨多次调用各扣各的，可接受）；真实单价见下条。

### 🟡 sandbox 真实单价 + 计量维度待定（当前 wall-clock × 占位价）
- **发现**: 2026-06-02 · billing P2 Phase F
- **位置**: `apps/edge/src/lib/sandbox.ts`（`SANDBOX_USD_PER_SECOND` 常量）
- **问题**: (1) **单价是占位**——`SANDBOX_USD_PER_SECOND = 0.0001`（≈0.36 USD/h）是随手填的 stand-in，**不是定价决策**。真实数字得从 Cloudflare container 计价（running 态按 provisioned memory+disk 计费）推。(2) **计量维度可能不对**——现在按 **wall-clock 秒** 计，但 Cloudflare 实际按 memory-seconds + disk + egress 计；CPU/内存重的任务和空转任务被同价对待。Sandbox SDK `runCode` 的返回（官方文档核实：`{ code, logs, results, error, executionCount }`）**不含任何时长/资源字段**，所以 worker 侧只能拿 wall-clock，要按内存/CPU 计就得换数据源（容器 DO 自报 or CF 用量 API）。
- **影响**: 占位价上线 = 系统性多扣或少扣；wall-clock 计量对滥用者（高内存长跑）偏宽松。pre-launch 无真实流量，先把门禁+扣费形态接通是合理折中。
- **建议**: 发布前 (1) 用 Cloudflare container 实际价目替换 `SANDBOX_USD_PER_SECOND`，最好建 `sandbox_prices` 表（同 `web_tool_prices` 模式）；(2) 评估是否需从容器侧拿 memory-seconds 取代纯 wall-clock；(3) 视成本量级决定是否加周期 settle + 余额≤0 中途 kill 容器。
- **状态**: 待办
### 🟡 群语音 DO↔容器掉线重连/resync 控制逻辑已写+单测，但端到端音频恢复 runtime 未验证
- **发现**: 2026-05-29 · feat/group-voice-reconnect
- **位置**: `apps/edge/src/durable-objects/room-voice.ts`（heartbeat / onMediaClosed / runReconnect / resyncContainer / 多路复用 alarm）、`apps/edge/src/durable-objects/room-voice-reconnect.ts`（纯函数：nextBackoffMs / buildResyncCommands / shouldGiveUpReconnect）、`apps/voice-container/src/room.ts`（resetForStart + pong）
- **问题**: 控制面的掉线检测（close/error + 心跳丢 pong）、指数退避重连、resync 重放（start 复位容器 + 逐 bot add-bot）这套**控制逻辑已实现并有 vitest 覆盖**（退避表 + cap、resync 命令序列、drop→reconnecting→恢复/放弃的状态机用 mock socket 跑通）。但这个功能**无法在本地 runtime 验证**——线上 Cloudflare Container 部署被刻意搁置，没有活的容器实例可打。因此 `start` + `dial /control` + `{t:'ready'}` 握手 + 重放命令的**真实时序**、以及音频是否真的恢复，全都没跑过。
- **影响**: 端到端的「通话扛过容器抖动」目前是**未验证的纸面能力**。最关键的几个未知：(1) **OpenAI realtime 会话**在容器被 `start` 复位后是全新握手——掉线那一刻**进行中的那一轮 turn 大概率丢失**，bot 不会接着说，需要人或 VAD 重新触发；(2) **RealtimeKit 参与者**在新容器/复用暖容器上 rejoin 的时序未知——旧 participant 是否会 linger 30–60s 让新 leg 干净顶替，还是会出现双 participant / 抢占；(3) 重连窗口内（最坏 ~30s）**人类听到的是静音**，没有补偿音频或「正在重连」语音提示，只有 UI 的「重连中…」横条；(4) playout jitter-buffer 在新 leg 上要重新 pre-roll，恢复瞬间可能有一小段额外延迟/卡顿。
- **重试边界（reviewer 需知道何时仍会放弃）**: 退避 250/500/1000/2000/4000/8000ms，cap 10s；总 wall-clock 预算 `RECONNECT_MAX_WALL_MS = 30s`。预算耗尽（约 8 次拨号）后 `runReconnect` 调 `finalize()` 真正结束通话并广播 `voice_call{event:'ended'}`，日志 loud（带尝试次数）。重连期间 `sendMedia` 丢弃命令（有日志）——靠 resync 的 add-bot 重放重建 roster，不排队。
- **建议**: 等容器部署后做一次真机演练：通话中 kill 容器实例（或断其网络），观察 (a) DO 是否在 ~10s 内检测到并广播 reconnecting；(b) 新容器 ready 后 OpenAI/RTK 是否都重建、人能否继续听到 bot；(c) 进行中 turn 丢失是否需要补一条「我刚刚断了一下」式的提示音/系统消息；(d) RTK 双 participant 是否需要在 resync 前显式 leave 旧 meeting participant。若 (b)/(d) 有硬伤，考虑 resync 时让容器先显式 detach 旧 RTK participant 再 rejoin，而非纯靠 `start` 复位。
- **状态**: 待办（控制逻辑已合入 + 单测绿；端到端音频恢复待容器部署后 runtime 验证）

### 🟡 IM realtime 仍是 Worker 主动推送和 Postgres conv webhook 混合态
- **发现**: 2026-05-29 · codex/message-coordination
- **位置**: `supabase/migrations/20260516073714_realtime_webhooks.sql`、`apps/edge/src/routes/messages.ts`、`apps/edge/src/lib/unread-state.ts`
- **问题**: 本轮已把高放大的 `user_unread_counts` pg_net fanout 去掉，read ack/unread 状态改由 Worker 主动推 user hub；但 `messages` 的 conv 级变更仍依赖 Postgres webhook 作为兜底，Worker 写入后也会等待 DB webhook 把 canonical row 推回客户端。
- **影响**: SSE/WS 已靠 message id + `message_seq` 去重，但消息发布源仍是混合态；后续要做 DO 级房间排序、离线 outbox、recall/update/delete 的精确顺序时，仍可能出现“Worker 已知道结果但 conv hub 等 DB webhook”的延迟和双路径语义漂移。
- **建议**: 下一阶段把所有消息状态变更统一收敛到 Worker/DO 的 `publishMessageChange` primitive：insert/update/delete/recall 都由 Worker 写库后同步发布 conv hub，Postgres `messages` webhook 只保留迁移期兜底，最终关闭。
- **状态**: 待办

### 🟡 PendingCrew Mac 本机 session：成功跑的 stdout + 退出码不回流 UI（卡在 running）
- **发现**: 2026-05-29 · computer-use 实测本机 happy path 时暴露
- **位置**: `apps/pendingcrew/Sources/Mac/LocalRunner/LocalCodingAgentProcess.swift`(actor + readabilityHandler/terminationHandler)、`LocalCodingAgentService.swift`(`MacLocalCodingAgentService.runSession` 把 line handler → AsyncStream，`waitUntilExit` → `exitCode` Task)、`apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift`(`CrewSessionRun.observeStreams`)
- **问题**: 起一个本机 Claude Code session 后，进程**确实跑完并干净退出**（`ps` 确认无残留 claude 子/孙进程；shell 里用完全相同的 argv/env/cwd/stdin 跑 `claude --print --output-format=stream-json --verbose` 2.6–8.7s 出完整 stream-json、exit 0），但 app 右栏**永远停在 `running`、stdout 恒为「(空)」**，6+ 分钟不变。即 stdout 流和 exit code 都没回流到 `CrewSessionRun` 的 `@Published`。
- **关键非对称线索**: **失败路径正常**——`--verbose` 修复前，claude 把参数错误打到 **stderr** 并秒退，app 正确显示 stderr 内容 + 状态 `失败 1`。也就是说 stderr 流 + exit code 在「快速退出」时能回流；但 **stdout** 在「跑几秒成功退出」时不回流，且同一次 run 的 exit code 也收不到（否则状态会从 running 翻成 completed）。代码层面 stdout/stderr 两条桥是对称的（同样的 readabilityHandler、同样的 `cont.yield`、同样的 observe Task），所以更像是 **Process/actor 生命周期或 Pipe EOF/terminationHandler 在「长跑 + 大块 stdout」场景下的竞态/未触发**，而非 stdout 专属的代码 bug。已排除：App Sandbox（无 entitlements、codesign 无 sandbox）、PATH/env（`env -i` 最小 PATH 也能跑通）、stdin 未关闭（代码已 write+close）、孙进程占住 pipe（`ps` 无残留）。
- **影响**: **v1.0 本机 runner 的核心路径目前不可用**——每个成功的本机 Claude Code/Codex session 都会卡在 running、看不到任何输出，用户无法判断任务进展或完成。这是 PendingCrew Mac 最主线的功能。`--verbose` flag 已修（commit 8bc97d72），所以 CLI 调用本身已正确；剩下的就是这条「成功 run 的输出/退出不回流」。
- **根因**: 不在 runner core——写了个不依赖 GUI 的 Swift harness（直接 new `LocalCodingAgentProcess` + `MacLocalCodingAgentService`，同样的 observe 模式）跑 claude，**stdout 实时流 + exit code 全正常、4s 跑完**，证明 process/service/stream 桥都对。真正的 bug 在 SwiftUI 层:`CrewSessionWindowView` 只 `@EnvironmentObject` 持有 `CrewSessionRunner`（`.current` 被赋值时才刷新），却把内层 `CrewSessionRun`(嵌套 ObservableObject)的 `@Published`(stdoutText/status/exitCode)当普通参数读，**没订阅**——经典 nested-ObservableObject 漏订阅。模型一直在更新，view 永不重渲染。
- **修复**: 抽出 `SessionRunContentView { @ObservedObject var run: CrewSessionRun }`，让输出栏 + 状态徽章订阅 run 自己的变化。
- **状态**: 已解决（2026-05-29 · commit 86f678f8。computer-use 实测:stdout 实时流出 stream-json、状态翻成「退出 0」。另已修 `--verbose` 前置 bug commit 8bc97d72。）

### 🟡 iOS PendingBot CrewTabView 是 codex 老 dashboard 风格,未按 spec v2 §11.2 重做(roadmap 漏列单独 task)
- **发现**: 2026-05-28 · user 主动追问"iOS Crew Tab 做了没"时暴露
- **位置**: `apps/pendingbot/Sources/Features/Crew/CrewTabView.swift`(878 行)+ `CrewAPI.swift`(330 行)+ 调用的老 `/v1/crew`(单数)endpoint 链路
- **问题**: 现有 iOS Crew Tab 是 codex 之前实现的 **dashboard 风格**:`@State crews / runnerHosts / sessionsByCrew / linksByCrew / membersByCrew / announcementsByCrew` 字典爆炸,UI 是创建 crew + 起 session + 看 runner host 的"工作台"形态。spec v2 §11.2 明确要求 PendingBot Crew Tab 是**普通群聊 UI grammar**(crew 列表按最近活跃排 + tap 进 crew → 群聊页面 + 消息流 + composer + @人/@session/@captain + session 状态卡 + 子 crew 摘要卡 + "在 PendingCrew 中打开")—— 完全两种东西。T1.3 D agent 只往里塞了个 SubjectPickerSheet(扫码批准 PendingCrew 登录),主体没动。
- **影响**: v1.0 发出去 iOS Crew Tab 是 codex 风格而非 spec v2 §11.2 风格,**用户体验跟 Mac PendingCrew + iPad 不一致**;后续 §9 通信规则(`@session` mailbox / `post_to_crew` tool / 群聊白板)接入也没 client 入口。
- **建议**: v1.0 roadmap 漏列了这个 task,本次补加 **T4.6 iOS PendingBot Crew Tab v2 重做**(roadmap §7 Phase 4,跟通信规则一起做)。重做要点:
  - 删/重写 老 dashboard
  - crew 列表用 `/v1/crews`(F agent ship 的新 endpoint),不是老 `/v1/crew`
  - tap 进 crew → 群聊页(类似 ConversationView 风格,但 crew 上下文)
  - 保留 SubjectPickerSheet(扫码批准 PendingCrew 登录的入口)
  - iPad / Mac 借此机会规划共享(spec v2 §12.1 中栏 = §11.2 crew 群聊,两端同源)
- **状态**: 待办(已加 roadmap T4.6,本次 session spawn sub-agent 做 MVP)

### 🟡 PendingCrew `devicePublicKey` 是 placeholder 字符串,device grant 没真绑设备
- **发现**: 2026-05-28 · feat/subject-login-flow(T1.3 sub-agent 标了 TODO,session cleanup 时正式登记)
- **位置**: `apps/pendingcrew/Sources/Services/PendingCrewAPI.swift`(`createDeviceLoginChallenge` 里的 `devicePublicKey`)
- **问题**: 现在传给 edge 的 `devicePublicKey` 是写死的字符串(类似 `"scaffold-placeholder-key-0123456789abcdef"`),仅满足 edge 端 `z.string().min(16).max(4096)` 长度校验,**没有任何 keypair 在背后**。spec v2 §4.4 暗示的"device-bound grant"(Secure Enclave / Keychain backed P-256 / Ed25519,后续请求要签名)完全没实装。
- **影响**: device grant token 跟物理设备**没有密码学绑定**,**丢了就丢了**;edge 也没办法验证后续请求真的来自原设备。这对一个挂在远程命令通道(Phase 4 跨端遥控 / `peer_device` location)上的客户端是显著的安全洞 —— 偷到 grant 的攻击者可以装作合法设备发指令。
- **建议**: Phase 4 跨端遥控架构动工前必须真做:Secure Enclave / `SecKey` API 起 P-256 keypair,private key 留 Enclave,public key 上行;后续敏感请求加 signed header(`x-pcrew-device-sig`)边端 verify。**写进 spec v2 §4.4 + roadmap T4.5 前置依赖**。
- **状态**: 待办(Phase 4 前置)

### 🟡 三组"新旧字段"双写并存(Phase 2 schema 增量演进的副产品)
- **发现**: 2026-05-28 · feat/crew-core-schema + feat/subject-schema-foundation(T1.1 / T2.x sub-agent 都选择"增量演进而非重写",session cleanup 时合记一条)
- **位置**:
  - `subjects.subject_type`(老 plan)↔ `subjects.kind`(spec v2 §4.1),`20260528083506_subject_v2_schema_alignment.sql` 加 BEFORE trigger 双写
  - `temporary_group_meta.runtime_kind` ('local'/'cloud',老)↔ `runtime_location` ('local_host'/'peer_device'/'fly_machine',spec v2 §8.2),迁移 `20260528105149` 双写
  - `temporary_group_meta.cloud_machine_id`(老)↔ `fly_machine_id`(spec v2 §8.2),同上
- **问题**: 我让 sub-agent 在 T1.1 / T2.1 写 schema 时图省事,选了 "新加列 + trigger 同步" 而不是 "改老列 + 全量回填 + 老 column drop"。triggers 把读写两边都对上,但**两套字段的存在让任何后续改这些字段的人要同时维护两套**,read path 也乱(看 schema.ts 不知道用哪个)。
- **影响**: 每多一个引用这些字段的 code path,都要决定用新名还是老名;混用很容易出现;长期会让 schema 不易理解。已经在 `crews.ts` route 等地方混用了 runtime_kind 跟 runtime_location 两个名字。
- **建议**: 起一轮 hard cutover migration:把所有 read path 切到 spec v2 字段名 → 删 trigger → DROP 老字段。趁 v1 还没发外、用户量为 0 时做最便宜。**v1 launch 前必须完成**,不然 user data 落到老字段就要做 backfill 比现在贵。
- **状态**: 待办(v1 launch 前必须 cutover)

### 🟡 Spec v2 §6.3.1 captain 三种来源跟现有 schema 不一致
- **发现**: 2026-05-28 · feat/crew-core-schema(T2.2 sub-agent 报告)
- **位置**: `docs/superpowers/specs/2026-05-28-pendingbot-pendingcrew-product-design-v2.md` §6.3.1 vs `supabase/migrations/20260527090000_crew_dag_captain_responsibility.sql`(老迁移已实装 `spawned_by_captain` 第四种来源)
- **问题**: spec v2 §6.3.1 列了 captain 三种来源(bot 在群聊发起自动当 / 用户已有 bot / 系统生成),但**老迁移已经实装了第四种** `spawned_by_captain`(captain 主动创建子 crew 时自动成为子的 captain),并配有 `create_child_crew_inheriting_responsibility_for_actor` RPC。T2.2 sub-agent 走了老 RPC,**没修订 spec v2**。
- **影响**: spec 跟现实出现 4 vs 3 来源的轻量不一致;后续 captain 选择 UI 设计、客户端枚举、文档都可能照 spec 漏掉 spawned_by_captain 分支。
- **建议**: 修订 spec v2 §6.3.1 把 captain 来源补到第四种,描述清楚"由当前 crew 的 captain 主动创建子 crew → 子 crew 的 captain 默认 = 父 captain"的语义。
- **状态**: 待办(spec 修订)

### 🟡 PendingBot Mac 端通过 EXCLUDED_SOURCE_FILE_NAMES 跳过 iOS-only 文件,非真正 multiplatform 适配
- **发现**: 2026-05-28 · feat/pendingbot-multiplatform-scaffold + feat/pendingbot-mac-tab-shell
- **位置**: `apps/pendingbot/project.yml`(EXCLUDED 配置)、`apps/pendingbot/Sources/{Components,Features,Models,Networking,Storage}/`(被排除的 iOS-only 子树)
- **问题**: T0.1 commit message 声称 "iOS code 全部用 `#if os(iOS)` 整体包住,Mac 端 build 能跑";实际**没有逐文件加** `#if os(iOS)`,Mac build "成功" 只是因为 swift 编译器在前面 2 个 module-resolution error 就 abort,后面 100+ 个 `import UIKit` 文件根本没参与 Mac 编译。T1.4 sub-agent 发现后改走 `EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]` 在 xcodegen 层把整个 iOS-only 子树从 Mac build 排除,实现等价(Mac 不编译这些文件),但代价是**这些文件在 Mac 端完全不可见**。
- **影响**: Phase 2+ 渐进做 Mac 端业务接入(IM 列表、消息流、Crew Tab 等)时,要逐文件决定是 unwrap 成跨平台还是保持 Mac-excluded。**没有任何 build 验证能告诉你哪些文件还在 iOS-only 子树里**(它们对 Mac build 隐身);容易在做 Mac UI 时反复 surprise:某个想用的 model / service 其实在 excluded 子树里,引用就编译不通。
- **建议**: Phase 2 起,每加一个跨平台 view 要主动检查依赖链 —— 跨平台需要的 model / service / helper 从 excluded 子树挪到 `Sources/Shared/`,或加 `#if os(iOS)` 让平台特定部分隔离,逐步收缩 EXCLUDED 范围。**T0.1 的"整体 #if 包"承诺要么真做(逐文件加),要么把 EXCLUDED 当作长期方案显式记入 spec/roadmap,不能两头吊**。
- **状态**: 待办(Phase 2 起渐进消化)

### 🟡 Supabase advisor 噪音没有 allowlist / ownership 分层
- **发现**: 2026-05-25 · codex/security-architecture-audit
- **位置**: Supabase security/performance advisors、`supabase/migrations`
- **问题**: 当前 advisors 同时报告真实待部署安全问题、service-role-only 表的 `RLS Enabled No Policy`、大量缺索引外键、多条 permissive policy、以及可解释的管理/触发器函数。没有 repo 内 allowlist 和“必须清零 vs 可接受噪音”的分层，导致每次审计都要重新判断哪些是风险、哪些是预期。
- **影响**: 真问题容易被噪音淹没；也会让“部署后 advisors clean”这个安全门槛变得不明确。尤其是 service-role-only 日志/配置表、管理 RPC、subject helper 这几类需要可机器检查的例外。
- **建议**: 建一个 `docs/supabase-advisor-allowlist.md` 或测试 fixture：记录每条可接受 advisor 的理由、owner、复核日期；CI/本地脚本把非 allowlist 的 security warning 当失败，performance warning 至少生成待办清单。
- **状态**: 部分修复（2026-05-25 · 新增 `docs/supabase-advisor-allowlist.json`、`scripts/supabase-advisor-gate.ts`、fixture 测试和 `.github/workflows/security-gates.yml`；安全 advisor gate 默认 fail-closed，只有列明理由的 service-role-only INFO 可通过，未列入的 WARN/ERROR 会阻塞；CI 现在覆盖 gate/allowlist 逻辑不会退化。live 上仍需部署本分支 Supabase 迁移、处理 Auth leaked-password / MFA 设置，并在上线流程中用真实 advisor JSON 跑 `bun run supabase:advisor:gate <advisor-json>`。）

### 🟡 1v1 Realtime 和群语音的 metering / billing 逻辑重复
- **发现**: 2026-05-25 · codex/security-architecture-audit
- **位置**: `apps/edge/src/durable-objects/realtime-meter.ts`、`apps/edge/src/durable-objects/room-voice.ts`、`apps/edge/src/routes/realtime.ts`、`apps/edge/src/routes/group-voice.ts`
- **问题**: 两套语音路径都在组装 realtime session、读取 `response.done` usage、调用 `computeVoiceCost`、广播 `voice_cost`、最终 `enqueueAudit`；但生命周期、参与者语义、计费归属和日志策略分别散在两个 DO / 两套路由里。
- **影响**: 一个路径修了隐私日志、缓存计费或余额中断，另一路可能漏掉；群语音接 bot participant 和 RealtimeKit 双轨成本后，这种重复会直接影响账单一致性和隐私审计。
- **建议**: 抽出共享的 voice metering/billing primitive：usage 归一、cost preview、audit enqueue、log redaction、hangup policy 共用；DO 只保留 transport/room lifecycle 差异。
- **状态**: 部分修复（2026-05-25 · 新增 `apps/edge/src/lib/voice-metering.ts` 和 `voice-metering.test.ts`，两套 DO 共用 realtime usage 拆分、事件脱敏摘要、`voice_cost` live preview 的 markup / 累计 / 广播逻辑、voice audit enqueue 元数据组装；1v1 realtime session 预调用与 post-turn 余额门槛均复用 billing 层 `getBalanceGateState`，避免语音和文字入口漂移；群语音房间级余额中断策略仍需单独设计，不能直接套 1v1 hangup。）

### ✅ JWT 验证只校验签名和形状，未绑定 issuer/audience/role
- **发现**: 2026-05-24 · codex/security-architecture-audit
- **位置**: packages/identity/src/jwt.ts:42、packages/identity/src/schema.ts:8
- **问题**: Edge 端 `jwtVerify` 允许 Supabase JWKS 的非 HS256 签名算法，但没有传 `issuer` / `audience`，payload schema 也只把 `role` 当 optional 字段，不要求 `role = authenticated`。
- **影响**: 目前同项目 JWKS 已经挡住大多数伪造，但认证边界比 Supabase Auth 语义更宽；未来多 audience、服务 token 或 Auth 配置变化时，可能把不该当用户会话的 token 接进 `requireSession()`。
- **建议**: 把 `issuer` 固定为 `${SUPABASE_URL}/auth/v1`，`audience` 固定到期望值，并在 middleware 中要求 `role === 'authenticated'`。
- **状态**: 已修复（2026-05-25 · `packages/identity/src/jwt.ts` 在 `jwtVerify` 层绑定 `issuer = ${SUPABASE_URL}/auth/v1` 与 `audience = authenticated`，payload schema 要求 `role = authenticated`；`identity-jwt.test.ts` 覆盖错误 issuer / audience / role。）

### 🟡 iOS 模型池的 Artificial Analysis 排序是静态快照
- **发现**: 2026-05-24 · codex/bot-model-pool-ui
- **位置**: apps/ios/PendingBot/Components/ModelPicker.swift
- **问题**: 新建机器人模型池按 Artificial Analysis Intelligence Index 排序，但当前实现把一份榜单分数快照写在 iOS 端；Artificial Analysis 免费 API 需要服务端 API key，仓库还没有对应的后端缓存/归因链路。
- **影响**: 榜单会随时间漂移，客户端静态排序会逐步变旧；以后如果用户把“按 AA 排序”理解成实时榜单，这里会产生隐性偏差。
- **建议**: 在 Edge 的 `/v1/models` 聚合里接入服务端缓存的 Artificial Analysis API 数据，返回稳定的 `intelligence_index` 字段，iOS 只消费字段排序和展示归因。
- **状态**: 已解决（codex/artificial-analysis-api：Edge `/v1/models` 接入 Artificial Analysis API + KV 缓存并返回 `artificial_analysis_intelligence_index`，iOS 改为消费服务端字段排序）

### 🟡 RealtimeKit POC 入口绕过了正式群语音 presentation
- **发现**: 2026-05-23 · codex/cf-realtimekit-poc
- **位置**: apps/ios/PendingBot/Features/Message/ConversationView.swift、apps/ios/PendingBot/Features/Call/GroupCallView.swift
- **问题**: 为了在两个模拟器上验证 RealtimeKit 房间，Conversation DEBUG header 临时加了 `RealtimeKit POC` 按钮直接请求 bootstrap 并弹 WebView；正式群语音按钮/active call banner 到 `GroupCallView` 的 presentation 在验证时没有稳定打开。
- **影响**: POC 验证路径和正式用户路径分叉，容易出现“调试入口可用、正式入口不可用”的假阳性；后续接 bot participant 和计费前必须把正式入口的状态机、sheet/fullScreenCover 归一。
- **建议**: 把正式群语音入口收敛到同一个 room state coordinator，由它负责创建/恢复房间、展示通话 UI、挂接 RealtimeKit/OpenAI participant 与计费状态；DEBUG 入口只保留为同一 coordinator 的诊断开关。
- **状态**: 已解决（013d037 之后的 codex/realtimekit-formal-entry，2026-05-23：DEBUG 群语音按钮进入 `GroupCallView` 的 RealtimeKit provider，删除 Conversation header 临时入口）

### 🟡 RealtimeKit 仍未接入 bot participant 和双轨计费
- **发现**: 2026-05-23 · codex/cf-realtimekit-poc
- **位置**: apps/edge/src/routes/group-voice.ts、apps/edge/src/lib/realtimekit.ts
- **问题**: RealtimeKit bootstrap/leave/end 已经接入 `voice_active_calls` 和 `voice_call` conv-channel 生命周期，但 bot runtime 还没有作为 WebRTC participant 入会，RealtimeKit 房间成本也还没有和 OpenAI Realtime usage 一起进入正式计费。
- **影响**: 两个真人可以走 RealtimeKit 调通房间生命周期，但“机器人像真人一样参会”仍缺一个受控 WebRTC client/mixer，且正式 Release 前还缺双轨计费口径；否则容易出现媒体成本不透明或机器人音频绕开 PendingBot 的预算控制。
- **建议**: 下一步把 bot runtime 做成 RealtimeKit participant，由服务端负责混音/输入 OpenAI Realtime、按会话维度汇总 OpenAI usage + RealtimeKit participant/session minutes，再落到现有 `voice_cost`/audit billing 体系。
- **状态**: 部分修复（2026-05-25 · 群语音已接入 headless RealtimeKit bot participant / media container；本轮新增 RealtimeKit audio participant-minute 结算：通话结束写入 `cloudflare_realtimekit_media` 审计行，按真人在场秒数加权 split，同时把 bot participant 秒数计入总媒体成本；价格进入 `billing_config.cloudflare_realtimekit_audio_participant_usd_per_minute` 和 board billing knob。剩余：用真实 RealtimeKit/Cloudflare 账单数据校准价格与 active-session minute 口径。）

### 🟡 跨 provider web search 解析路径未经真实流量验证
- **发现**: 2026-05-22 · feat/web-search-providers
- **位置**: apps/edge/src/llm/{responses,anthropic,gemini}-adapter.ts、apps/edge/src/lib/bot-reply/index.ts
- **问题**: 四条 provider 的搜索词/引用解析都是按当前官方文档「应该长这样」写的 + 单测覆盖了解析逻辑，但没跑过 AI Gateway 的真实响应。三处具体不确定：① OpenAI 用的是 `web_search_preview`，搜索词靠运行时 `web_search_call.action.query`，SDK 4.104.0 没建模 `action`，preview 变体运行时可能根本不带 query（引用走 annotation 不受影响）；② Gemini 把 `google_search` 和 `functionDeclarations` 放在同一个 `tools` 数组，2.x/3.x 支持、老模型会 400 整轮失败；③ annotation 事件名 `response.output_text_annotation.added` 是下划线形式，与 SDK 版本耦合，升级 openai SDK 时可能改成点号形式而静默失配。
- **影响**: 搜索词/引用可能在某些 provider 上仍不显示（降级而非崩溃，OpenAI/Gemini 引用仍能出）；Gemini 老模型若拒绝组合 tools 会让整轮回复失败——这是唯一可能从「不显示」恶化成「报错」的点。
- **建议**: 每条路各发一条真实搜索回合核对 SSE：OpenAI 看搜索词是否出（不出就把 `web_search_preview` 换 `web_search`）；Gemini 确认所用模型支持 search+function 共存（不支持则按模型分档，或搜索turn 不带 function tools）；升级 openai SDK 时回归 annotation 事件名。
- **状态**: 部分修复（2026-05-25 · Gemini native adapter 现在对 `google_search` + `functionDeclarations` 组合不兼容的 400 做单次 search-only 降级，避免老模型把整轮回复打挂；仍需用真实 AI Gateway 流量验证 OpenAI query / Gemini grounding / annotation 事件名。）

### 🟡 Crew Tab 聊天剩余两处刻意取舍（无附件 / 人类气泡同侧）
- **发现**: 2026-05-29 · feat/crew-tab-v2-multiplatform（T4.6 P1）；前两项已于 T4.5（feat/crew-live-push）解决
- **位置**: apps/pendingbot/Sources/Features/Crew/{CrewChatStore,CrewMessageListView,CrewComposerBar,CrewChatModels}.swift
- **问题**: 把 crew 详情页改成群聊 UI（消息流 + composer + @mention + session 状态条 + 子机组卡）时，P1 刻意留了四个洞，T4.5 已补掉前两个：
  1. ~~**轮询，无实时推送**~~ —— **已解决（T4.5）**：crew 就是一个 conversation，`crew_announcements` / `crew_sessions` 行变更现在经既有 `conv:<crewId>` RealtimeHub topic fan-out；`CrewChatStore.start()` 在首次 `load()` 后开 conv-channel，`apply` / `applySession` 按 id upsert（INSERT=新帖、UPDATE=权限状态翻转）。`.refreshable` + 发送后 `reload()` 保留为冷启动/兜底。
  2. ~~**inline 权限卡片缺数据源**~~ —— **已解决（T4.5）**：权限卡数据源就是 `crew_announcements` 里 `message_kind=='permission_request'` 的行（冷加载 `getCrewAnnouncements` + live 帧都带）。`CrewChatAdapter` 把这类行产出权限变体（解 `payload` → `PermissionRequestPayload`、session 标签查 session index），`CrewMessageListView` 按行分支渲染 `PermissionRequestCardView`，批准/拒绝走 `store.decide(...)` → `decidePermissionRequest`，服务端把状态盖回 announcement 再 fan 回来翻转卡片。
  3. **composer 无附件**——复用 `ComposerView` 但传 `showsAttachments: false`，把 "+" 按钮和附件面板整个隐藏（不是留哑 tile）。crew 发送只走 `POST /v1/crews/:crewId/messages` 的纯文本 + mentions。
  4. **人类气泡分不出"我 vs 别人"**——`crew_announcements` 读出来只有 `sender_member_id`，拿不到我的 user_id，所以 `CrewChatAdapter` 把所有 human 帖都渲染到 user（右）侧、用 `display_name` 做气泡上方署名。多人时仍读得出是群聊，但"哪条是我发的"无法高亮。
- **影响**: 剩余两项都是体验降级而非功能缺失/报错。③ crew 里发不了图/文件；④ 我自己的消息和别人的同侧、无"自己"高亮。
- **建议**: 要分"我 vs 别人"需要读侧返回 `sender_user_id` 或在 members 里把 `me` 的 member_id 标出来再比对；附件等 crew upload 通道就绪后把 ComposerView 的 picker 接活。
- **状态**: 部分修复 —— ① live push + ② inline 权限卡已于 T4.5 落地；③ 附件、④ 自我高亮仍未修（待读侧补字段 / crew upload 通道）

## 🟢 不规范

### 🟢 surf_runs / scroll_runs 是 envelope 取代后的遗留死表(仍挂在 realtime publication 上)
- **发现**: 2026-06-07 · chore/edge-read-offload-spec(T2 读卸载梳理)
- **位置**: `supabase/migrations/*`(`surf_runs` / `scroll_runs` 建表 + realtime publication)、`apps/edge/src/db/schema.ts`
- **问题**: surf / scroll 两个 feature 早已被 envelope(来信)取代,edge + iOS 活代码对 `surf_runs` / `scroll_runs` / `surfRun` / `scrollRun` **零引用**,仅 schema 残留。且 `surf_runs` 还挂在 `supabase_realtime` publication 里,白占一个 webhook/复制通道。
- **影响**: 纯死表噪音——拉大 schema、误导后来者以为是活 feature(本次 T2 梳理就一度把它们当 live 列进矩阵)、realtime publication 多一张无用表。无功能危害。
- **建议**: 确认无线上数据依赖后,迁移 drop 两表 + 从 realtime publication 摘除;`db push` 后 regen schema.ts。低优先,可与下次清理迁移合并。
- **状态**: 待办

### 🟢 iOS FriendsTabView 群邀请兜底文案仍是旧分摊口径
- **发现**: 2026-06-04 · fix/billing-tails-email-norm（#226 解耦）
- **位置**: `apps/pendingbot/Sources/Features/Friends/FriendsTabView.swift:827`
- **问题**: `billing_snapshot` 为 null 时兜底显示「接受后会按当前群设置参与机器人 Token 分摊。」——新群钱包模型下该口径已过时。edge 现总填中性 hint（`groupInviteBillingHint`），兜底极少触发，但文案该改。
- **影响**: 极少触发的过时文案，纯一致性。
- **建议**: iOS lane 顺手把兜底串改成中性/新模型口径。
- **状态**: 待办

### 🟢 PendingCrew 双轨 backend(EdgeBackend / LocalBackend)没有单元测试覆盖
- **发现**: 2026-05-29 · T5.2 dual-track routing wiring
- **位置**: `apps/pendingcrew/Sources/Services/PendingCrewBackend.swift`、`apps/pendingcrew/Tests/PendingCrewTests/`、`apps/pendingcrew/project.yml`
- **问题**: `PendingCrewBackend` protocol 有两个实现(EdgeBackend / LocalBackend),关键行为(BYOK 路径下 `attachParent` / 非 `local_host` runtime 抛 `notSupportedInByok`、`listMySubjects` 返回单元素假 subject、AppModel.mode → backend 选择)只通过 Mac 手测验证。`PendingCrewTests` target 是 standalone XCTest bundle,故意只编 `Sources/Mac/LocalRunner` 进去(`TEST_HOST=""` / `BUNDLE_LOADER=""`,见 project.yml 注释 —— scaffold 阶段 app 不签,无法做 host-app injection)。要给 backend 加单测得改 project.yml 把 Sources/Services + Sources/Stores + Sources/Models 也编进 bundle,或者把 backend 抽成独立 SwiftPM module。
- **影响**: BYOK / logged 切换、能力 gating(`supportsCloudRuntime`)的行为契约靠 UI 手验,后续新加 protocol 方法(spec §5.3 提到的 share-change / mailbox / whiteboard 等)很容易漏掉一端没实现就 ship。
- **建议**: 等 PendingCrew app 真正签名(脱离 scaffold 阶段)后,把测试 bundle 改成普通 host-app injection 模式,补 backend 行为快照测试;或者把 PendingCrewBackend + 两个实现拆到 `Packages/PendingCrewBackend/` SwiftPM module,带自己的测试 target。
- **状态**: 待办

### ✅ 模拟器 signup 失败("permission denied for table users") = 模拟器没签名 → Keychain -34018(三轮误诊后定案)
> 标题历经多轮:~~Keychain entitlements~~ → ~~后端 signup bug~~ → ~~supabase-swift anon~~ → **真因:模拟器关签名导致 Keychain -34018**(详见下方"二次纠正"+ 343 条 🔴 的"⭐ 上游真因")。已在 `project.yml` 根治。
- **发现**: 2026-05-29 · v1 QA;2026-05-29 复盘纠正
- **位置**: 误指 `apps/pendingbot/project.yml` / `Resources/PendingBot.entitlements`;实因 `bootstrap_user_id` 等 signup RPC
- **纠正后的真相**: 之前把模拟器邮箱登录失败归因为"sim 不签名 → `keychain-access-groups` 不生效 → `-34018` → session 存不进 Keychain"。**这是误诊**。三条证据推翻它:① `keychain-access-groups` 自 T0.1 脚手架(`4b305f1a`)起就在 entitlements 里,不是新增,无法解释"突然不行";② 关键 tell —— 故障期 **Google 登录正常、只有邮箱登录失败**;若真是 Keychain 问题,两条登录都要存 session 到 Keychain,会**一起挂**,Google 能成功恰恰证明 **sim 的 Keychain 工作正常**;③ 邮箱 OTP 走 `shouldCreateUser=true` 的建号路径,正好踩中当时坏掉的后端 RPC(`bootstrap_user_id` 的 `bot_id` 歧义、`uuidv7` 对 authenticated 无执行权、`is_bot_invitee` 残留),"permission denied for table users / auth session missing" 是后端 bootstrap 失败后拒绝 PATCH,不是 client 存不住 session。
- **影响**: 误诊本身耗了不少时间,也差点逼出"sim 用内存版 AuthLocalStorage"这种没必要的 workaround。模拟器**可以正常登录和测试**(签不签名都行;CLI ad-hoc 签名 entitlements 是空的,但 sim 的 Keychain 默认 access group 不依赖它)。
- **建议**: 模拟器是可信的 auth 测试环境,无需真机兜底。后端 signup bug 已修并部署(见对应迁移)。CLI 不签名构建只用于编译校验;运行时测试直接装 unsigned 或 Xcode GUI 构建都可登录。
- **状态**: 已解决/纠正(2026-05-29 · 根因是后端 signup bug,已修+部署;Keychain 结论作废,留作"别再被表象误导"的记录)
- **二次纠正(2026-06-01)**: 上面"`permission denied for table users` 是后端 bootstrap 失败后拒绝 PATCH"这句**也是误诊**。2026-06-01 同样的报错在选名字步骤复现,这次连 live 钉死了根因——**和后端无关**:① live introspection 实测 `has_table_privilege('authenticated','pendingbot.users','UPDATE')=true`、`users_self_update` RLS 在、唯一会 fire 的 `users_ensure_subject_trg` 是 `SECURITY DEFINER` owned by postgres;② `supabase db query` 直接复现出**一模一样**的 `42501: permission denied for table users`——但只在 `SET ROLE anon` 时;`SET ROLE authenticated + jwt.sub` 时 UPDATE 成功;③ live 上新用户行+subject 都正常建了(bootstrap 健康)。真正根因见下一条 🔴。**教训**:"permission denied for table X" 是**表级 grant**被拒(执行角色没权限),不是 RLS(那会说 "new row violates row-level security policy"),也几乎从不是 bootstrap;遇到先用 `has_table_privilege` + `SET ROLE` 复现钉死执行角色,别再往后端 RPC 上猜。

### 🔴 supabase-swift 写操作在拿不到 token 时**静默降级成 anon**(吞掉鉴权失败)
- **发现**: 2026-06-01 · 新用户选名字保存报 "permission denied for table users"
- **位置**: **全仓所有 `SupabaseStack.shared.from(...).insert/update/delete` 直写都受影响**;机理在 supabase-swift 2.46.0 `SupabaseClient.adapt(request:)`;最先暴露点是 `apps/pendingbot/Sources/Features/Onboarding/ProfileBootstrapView.swift:save()`
- **问题**: PostgREST 客户端初始化时把 `Authorization: Bearer <anonKey>` 设进默认 header;每个请求经 `adapt(request:)` 用 `let token = try? await _getAccessToken()` 取用户 JWT,**`try?` 会把 `auth.session` 的抛错吞成 nil**,nil 时**不覆盖** Authorization → 沿用 anon key 发出。于是当会话取不到 token(过期+刷新在途/刷新失败/瞬时不可用)时,这条写**静默以 `anon` 身份执行**;`anon` 对 `pendingbot.users` 只有 SELECT 没有 UPDATE → `42501 permission denied for table users`。onboarding 的 `users` PATCH 只是最先暴露的点(全新用户第一笔写、且直写 `users` 表),但**任何**直写都可能在 token 抖动时悄悄变 anon 然后被 RLS/grant 挡掉或(更糟)被 anon 的策略静默放行/拒绝,排错时极易误判成"后端/DB 问题"。
- **影响**: 真机上 token 抖动(过期+刷新失败)时,任意客户端直写会静默以 anon 发出 → 被 RLS/grant 挡掉并报误导性的"DB 权限"错。叠加既有的"客户端绕过 edge 直写 `users` 表"这一架构异味(本次 bug 报告里用户自己也点了"不走 edge / 不走 RPC")。注:本轮 onboarding 故障的**实际触发**是签名导致会话存不住(见上一条),不是真机 token 抖动;此条记录的是**独立存在的潜在隐患**。
- **建议(分层)**: ① 单点 mitigation(`save()` 写前 `try await auth.session` + fail-loud)**已评估并 revert** —— 真根因是模拟器签名,单点改动只治 onboarding 一个写、价值有限,为保持本分支聚焦签名根治,不保留。② 系统性(推荐):给所有"需要登录的写"包一层统一 helper(写前确保 token、拿不到就抛而不是降级),或把直写收敛到 edge 端点(显式 Bearer + service-role 落库,彻底消除 anon-fallback,顺带去掉直写 `users` 的异味)。③ 可选:给 `SupabaseStack` 配 `auth.accessToken` 自定义闭包改成"拿不到就 throw",从源头堵掉静默降级。
- **状态**: **未修**(代码层无改动;单点 mitigation 已 revert)。本轮 onboarding 故障由签名根因解决(见上一条 ✅)。本条作为独立潜在隐患记录,系统性收敛(helper / 收敛到 edge)待排期。
- **⭐ 上游真因(2026-06-01 当天继续挖出,这才是病根)**: "token 拿不到"在**模拟器上不是偶发抖动,是必现**——因为 `auth.session` 取不到 token 的根本原因是 **Keychain -34018**:模拟器装机后保存会话写 Keychain 直接失败,会话根本存不住。而 Keychain -34018 的根因是 **`project.yml` 之前对模拟器关了签名**(`CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]=NO`)→ ad-hoc 构建 → 没有 `keychain-access-groups`(该 entitlement 需要 team 前缀,ad-hoc 没有)→ app 没有任何 keychain access group → 所有 Keychain 操作 -34018。**模拟器实测**:`supabase db query` 复现出一模一样的 `42501`(只在 anon 角色);模拟器日志确证 `failed to persist DB passphrase to Keychain: -34018` + `aps-environment` 缺失,都是没签名的征兆。**生产/TestFlight 不受影响**(真机用真 profile 签名,有 team 前缀,Keychain 正常,会话存得住)——live 里 `bootstrapped=1` 的真实用户就是证据。这个病根被**反复误诊过多轮**(Keychain entitlements → 后端 bootstrap → supabase-swift anon),每轮都治了表象。
- **根治**: `project.yml` 改成模拟器也用 dev team 签名(`fix/signup-bootstrap-patch` 已提交)。**注意**:headless / 无登录 Apple ID 的 CLI 构建仍会回落 ad-hoc(xcodebuild 自动签名需要交互式证书访问),所以**模拟器跑 onboarding happy-path 必须用 Xcode GUI(已登录 Apple ID)构建**,纯命令行装的包验证不了登录态写。`supabase-swift 静默降级 anon`(下一条 🔴)本身仍是真实隐患(真机若遇 token 抖动同样会静默 anon),代码层未做改动、系统性收敛待排期。

### 🟢 iOS 工程缺少测试 target，语音诊断只能靠构建兜底
- **发现**: 2026-05-23 · codex/fix-group-voice-diagnostics
- **位置**: apps/ios/PendingBot.xcodeproj、apps/ios/PendingBot/Features/Call/CallDiagnostics.swift
- **问题**: 当前 iOS 工程只有应用 target，没有单元测试 target；WebRTC 统计差分、群语音诊断合并这类纯逻辑只能靠人工复现和 `xcodebuild build` 验证，无法先写一个失败用例锁住“新 RTP 轨道首次出现不能污染丢包率”这类回归。
- **影响**: 群语音、多轨道、重协商等边界条件容易被编译通过但行为错误的改动重新引入。
- **建议**: 给 iOS 工程补一个轻量 XCTest target，把诊断聚合逻辑抽到不依赖 WebRTC/SwiftUI 的小类型后覆盖轨道新增、轨道移除、负 delta、缓冲阈值等用例。
- **状态**: 已解决（codex/security-architecture-audit：新增 `PendingBotTests` XCTest target，并把语音诊断格式化、质量分级、网络/媒体瓶颈判断抽到 `CallDiagnosticsLogic`，用单测覆盖边界阈值和 bot 媒体瓶颈优先级）

### 🟢 OpenRouter 搜索 chip 无搜索词、引用不内联 [N]
- **发现**: 2026-05-22 · feat/web-search-providers
- **位置**: apps/edge/src/lib/bot-reply/index.ts（OpenRouter annotations 解析处）
- **问题**: OpenRouter 服务端搜索不回传查询串，只给 `annotations`，所以合成的搜索 chip 没有「搜索词」；且原生 provider（OpenAI/Anthropic/Gemini/OpenRouter）的模型不会写我们约定的 `[N]` 标记，引用只进结果列表、不在气泡正文内联。与 Exa MCP 路径（有搜索词 + 内联 [N]）体验不一致。
- **影响**: 体验降级而非功能缺失——引用列表正常显示、可点。属于 provider 能力差异，非自挖的坑。
- **建议**: 可选增强——按 annotation 的 start/end_index 把 [N] 注回正文文本；OpenRouter 的搜索词无解（provider 不暴露）。
- **状态**: 不修（provider 限制 / 体验可接受）

---

## 2026-05-29 v1 sprint summary

本节为本轮（Phase 1–7）冲刺收尾的汇总。冲刺范围：在 `claude/blissful-albattani-a8a732` 分支上推进 v1 双轨架构（PendingBot IM 多端 + PendingCrew 本地 coding agent + billing-v2 双写），共 **34 commits**，由 ~13 个并行 sub-agent worktree 汇出。

### 已落地（commit hash）

**Phase 1 — billing-v2 双写底座** (merge `worktree-wf_bb2bdb07-141-3`)
- `4a9f93da` v2 dual-write — LLM + web-tool usage_events alongside v1 debit
- `71b69a02` v2 voice (RealtimeKit media) + sandbox usage_events
- `2dc06dbe` v2 cron — pack expiry sweep + group-pool reconciliation
- `cbb4fb3f` v2 settleUsage CAS-loss retry + cover main paths
- `3aef07e8` merge

**Phase 2 — PendingBot Mac multiplat T0.1 P0** (merge `worktree-wf_bb2bdb07-141-5`)
- `388f24fd` `#if os(iOS)` 替代 EXCLUDED_SOURCE_FILE_NAMES 大锅排除
- `4eff9d8e` Mac "我" tab 接入 AccountStore 真实账号信息
- `d6ed2808` 记录剩余缺口
- `6df88dbb` merge

**Phase 3 — 群账号 / 权限 / 三端壳** (merges `…-7`, `…-8`, `feat/mac-3col-shell`)
- `207d5203` edge T1.2 — `/v1/group-subjects/*` 群权限矩阵路由
- `cc080ac1` merge T1.2
- `7ff0c2a6` merge T1.3
- `f2dbebfb` crew(mac) identity footer + sign-out
- `c174f734` mac 三栏 NavigationSplitView 根壳
- `5e132703` merge mac-3col-shell

**Phase 5 — T4.5 跨设备控制设计** (merge `worktree-wf_bb2bdb07-141-16`)
- `ceba5619` docs(t4.5) cross-device session control as-built design
- `0780685f` merge

**Phase 6 — PendingCrew 本地 runner + Session 面板** (merges `…-18`, `…-19`, `…-20`)
- `5f731002` Swift 6 captured-var warnings 静化
- `2c7b7887` LocalRunner 接 model slug
- `a5ffe5c3` `/v1/models` client + backend `listModels()`
- `6d944513` GitInspector helper（分支选择器）
- `29699690` 完整 session-create panel（spec v2 §12.2）
- `280d5b7b` T3.4 first-launch disclosure modal
- `00746ca9` GitWorktreeService for T3.3 worktree option
- `bbd97ae4` T3.3 three-layer working directory in session sheet
- `4ca47a98`, `564693f7`, `e7bb267b` merges

**Phase 7 — PendingCrew 未登录 BYOK 双轨路由** (merges `…-22`, `…-23`)
- `ee28d676` reset CrewStore on backend mode change
- `8e0eac32` docs(tech-debt) PendingCrew 后端单测缺口
- `42d58047` BYOK 本地 captain template store
- `f78d61bf` BYOK CreateCrewSheet captain pool picker + template editor
- `c69ba418` merge T5.1
- `692b661f` merge T5.2

### 仍延期（需人工或后续 session）

#### 🔴 必须人工介入

- 🟡 **多 session 共享 DB 的迁移协调摩擦（不是漂移，是正常并行开发）** (2026-06-03 厘清)。一度以为远端有 4 条"幽灵迁移"(`20260602043820 pnc_ledger / 051354 metabase_readonly_role / 121205 group_pool_polar_rehome / 150732 group_pledges`)——后查清它们是**别的在飞分支的真实文件**(`chore/billing-dashboard-specs` / `feat/billing-p2-llm-gate` / `chore/retire-billing-v2` 等 billing/dashboard 线),那些 session 已经从各自分支 `db push` 到共享 prod、但还没合 main,所以 main + 我的分支都没这几个文件。**这是单 prod DB + 多分支各自 push 的固有摩擦**:谁 push 了未合 main 的迁移，别人本地就"缺"它，`db push` 会因 "Remote migration versions not found in local" 拒绝，直到把缺的文件带进来(从 sibling worktree 拷)或等其合 main。**对 T4.5 交互迁移的处置**:已把它从 `20260602145934` 改名到 `20260603032138_crew_interaction_requests.sql`(最新时间戳，避免它夹在 billing 那几条中间造成乱序);带齐 sibling 文件后 dry-run 干净(只推我这一条)。**✅ 已于 2026-06-03 用户在场授权后 `db push` 应用**（只推了 `20260603032138`；read-only 复核 `permission_requests.request_kind/reply_text` 列 + `create_interaction_request/answer_interaction_request` RPC 都已在 DB 上）。**对称摩擦**:我应用后，别的在飞 session 本地会"缺"这条 → 他们下次 `db push` 会被同样的 "not found in local" 拦，需带进本文件或等其合 main。schema.ts **故意没 regen**——并行期 regen 会把别 session 的 billing 表一起 dump 进我的 schema.ts(污染),且 `crew-interactions.ts` 走 untypedRpc 本就不需要 regen 才 typecheck 绿;regen + 收口 untypedRpc 留到合 main 时。
- **#185 IAP 服务端 webhook** — App Store Server Notifications V2 真实签名校验、refund/REVOKE 处理；当前只有 stub。需要 Apple Developer 后台配置 + 真实 sandbox 测试，必须人工。
- **#186 Lemon Squeezy refund 完整路径** — webhook 已落 issuePack 入账，但 refund/dispute 反向冲销在 v2 ledger 上还没串通；需要联调 LS test mode。
- **#188 Board 后台 — 计费 v2 管理面板** — `de4a62c2` 起了 admin grant/claw-back RPC + 简单 board UI，但仍缺：pack 列表/手动作废、refund 列表、用户 wallet 详情视图、批量 grant。需要 Board 端 UI 设计 + RPC 扩展。
- **#189 iOS wallet v2 完整 UI** — `5c63ce76` 只落了 preview 入口（PNC packs view），缺购买流（IAP product picker）、refund 历史、share-index 详情、群池贡献 UI。需要设计师定稿后再做。
- **#190 v1 计费完全退役** — `551296e9` 边缘 cutover 已让 v2 authoritative，但 v1 表 (`wallets`, `wallet_ledger`) 还在 schema 里；30 天观察期后需要一次清理迁移 + 删除 dead code 路径。

#### 🟡 后续 session 即可

- ~~**T3.2 Codex runner**~~ **（2026-06-02 已解决，#202）** — codex 契约已调研（codex-cli 0.133.0 `codex exec --help`）：argv 补 `--json`（JSONL 事件流，对标 Claude `--output-format=stream-json`）+ `-m/--model` 透传；launch / env 白名单 / discovery 早就是 kind-无关的复用层，不需要单独抽象。argv 测试覆盖 codex `--json` + 双 runner model 透传，11/11 绿。**上层 JSONL 事件解析层也已落地（#203，2026-06-02）**：`RunnerEventParser`（`apps/pendingcrew/Sources/Mac/LocalRunner/RunnerEventParser.swift`）把两种 schema flatten 成统一 `RunnerEvent`，接进 `CrewSessionRun.events` + session 窗口「转写」tab；fixtures 取自实跑 claude-cli / codex-cli 0.133.0，9 测试绿。Phase 3 本机 runner 闭环真实缺口已清零（剩 T5.3 真机 E2E QA，另列）。
- **T4.5 完整实现** — ~~`ceba5619` 只落了设计文档，实际代码一行没动~~ **（2026-06-01 对账更正：此说法已过时）**。服务端 P0 已落地：`c7b2cd2d` ship 了 `SessionProxyDO`（`apps/edge/src/durable-objects/session-proxy.ts` 534 行）+ `session.command`/`session.state` ws 协议 + 路由 + 单测 + wrangler 绑定。**仍缺客户端侧**：iOS/Mac 无任何 SessionProxy 订阅代码、PendingCrew runner 不发布到 DO（手机→Mac 推命令、Mac session 镜像未接）。当前是"服务端打底好、客户端未接"的半截桥，不是"一行没动"。
- **T4.5 runner WS 遥控命令应用 — cancel + send_prompt 已接通，permission 未** — runner-side 实时层（`SessionProxyClient` actor，connect→subscribe→边跑边推 `session.state`，退避重连 + ping）。**`cancel`** → `cancel()`，端到端。**`send_prompt` 已接通**（`<this branch>`）：`handleRemoteInbound` 取 payload `{text}` → `enqueueFollowUp` → `CrewSessionRun` 在当前回合退出时（`turnDidExit`）drain 队列，起 `claude --resume <agentSessionId> --print --output-format=stream-json` 续跑回合把 steering prompt 经 stdin 喂进去，复用 agent 上下文 + 缓存前缀（实测 cache_read 42422/create 494）。机制四连实验全绿（见 `docs/crew-runner-steering.md`）。**permission 这块已重新定性（2026-06-02，见 spec §10 重写 + `docs/superpowers/plans/2026-06-02-crew-interaction-human-in-loop.md`）**：原"逐动作 manual-mode 暂停/批准"作废——session 跑 auto/bypass，不做逐动作门禁；要的是**交互**（computer-use 授权/问问题/要判断），经 `--mcp-config` 注入的 `ask_human` MCP 工具阻塞 → captain 自决/沿 DAG 溯源到真人。`SessionProxyClient` 现有的 `sendPermissionDecision` 出口先留着（将来交互卡回复可复用），但 manual-mode 暂停那套不做了。**两个需要盯的点**：① **lifecycle 变更**——`finish()`→`finalize()`，现在**队列 drain 完才 finalize**（关 server row + WS）；无 steering 时队列空、`turnDidExit`→`finalize` 与原 one-shot 字节一致，但**有 steering 时 server session 会跨多回合保持 running 到 drain 完**，这条改了 T4.5 runner-chain 真机验过的"首回合退出即 completed"语义，需真机复验。② send_prompt 只能对**活着的**session 生效（finalize/cancel 后拒绝）；快任务窗口窄。③ 仅 Claude（Codex resume 返回 nil → fail loud）。**hook-注入的 ambient steering 通道已建**（`<this branch>`）：`SteeringChannel`（LocalRunner）造一个**仓库外**托管目录（app caches）放 `settings.json`（注册 `UserPromptSubmit` hook）+ 纯 stdout `hook.sh`（cat steering 便签，无 jq 依赖）；`LocalCodingAgentLaunchSpec.claudeSettingsPath` → `--settings <path>` 挂到首回合 + 每个 resume 回合；viewer 的 `set_steering`（payload `{text}`，空=清除）经 `CrewSessionRun.setSteeringNote` 写便签；`RemoteSessionsView` composer 发送按钮的菜单出「设为/清除常驻便签」。session 结束 teardown 托管目录。headless 四点全绿（注入无读、live 重读、尾部不破缓存、`--settings` 让工作目录零 `.claude` 污染）。**需真机复验的点**：① `--settings` 挂到了 logged 首回合（验证过的 launch 命令变了，跟 lifecycle 改一样要真机过）；② 用户的 crew 工作目录若自带 `.claude/settings.json` + 自己的 hooks，与我们 `--settings` 的合并行为没在真实 repo 验过（spike 是空目录）。
- **T4.5 Mac viewer 实时层已接，viewer→runner 发命令 UI 未建** — `7b71fb21`：`RemoteSessionsView`（PendingCrew Mac viewer）在 3s HTTP 轮询的持久转写之上叠了**实时层** —— 选中 session 开 `SessionProxyClient(role:.viewer)`，消费 `states` 流（`SessionStateSnapshot`，对账 runner 的 `SessionState.dict()` fan-out），顶部 banner 实时显示 status/lastEvent/eventCount。轮询保留为兜底（WS 连不上就退回原行为）。**viewer 发命令已部分接通**（`<this branch>`）：`SessionProxyViewerOutbound`（session.command / permission.decision）+ `SessionProxyClient.sendCommand/sendPermissionDecision` + `RemoteSessionsView` 的「停止」工具栏按钮发 `cancel`；runner 侧已 apply cancel，所以 viewer→runner 停止是端到端闭环。**viewer 发命令已基本接通**：`RemoteSessionsView` 现有「停止」（cancel）+ **steering composer**（输入框 + ⌘↩ 发 `send_prompt`，payload `{text}`），runner 两条都 apply，所以 watch（banner）→ steer（composer）→ stop（toolbar）在 PendingCrew 单 app 双窗即可端到端演示。**仍缺**：permission 卡片 approve/reject 走 `sendPermissionDecision`（出口已在，差 manual-mode UI + runner 侧解阻塞）。iOS PendingBot viewer 是另一条并行线（那边还在 HTTP 轮询）。
- **T4.5 authenticated E2E 未真机验** — 已验：codec + viewer 解码（21 SessionProxy 测试）+ `makeConnectRequest` wss/ws 升级 + auth header + role query + inbound 路由 + macOS app 编译 + **生产路由活性**（`wss://api.pendingname.com/v1/sessions/<uuid>/proxy/connect` 无 bearer → 401，证明 client 拼的 path 在 prod 命中 handler）。**未验**：带真实 device-grant 的完整 WS 往返（runner 连上推 `session.state` → Mac viewer banner 实时显示 → 之后 viewer 发命令）。需登录账号 + 真实 session 行；mint `pdg_` token 要走 iOS 扫码 approve，headless 起不了，留作 T5.3 真机 QA 的一部分。**注**：现在 runner + Mac viewer 两端代码都在，真机验时可在**同一台 Mac 两个窗口**（一个起 session 当 runner，一个开 RemoteSessionsView 当 viewer）直接看实时 fan-out，不必两台设备。
- **T4.5 交互（ask_human）——"agent 问人"半边已代码全通，"人答 + captain 溯源"半边未建** — spec §10 + plan `2026-06-02-crew-interaction-human-in-loop.md`。已落（`<this branch>`）：① **P1** CLI 权限档进 argv（`AgentPermissionMode`；顺手修了 runner 不传 `--permission-mode`→headless `default` 卡死的隐患，默认 `auto`）；② **edge 数据面**——迁移 `20260603032138`（`permission_requests` 加 `request_kind`/`reply_text`/status `answered` + RPC `create_interaction_request`/`answer_interaction_request`）+ 路由 `crew-interactions.ts`（runner 发起 / long-poll / 人答）；③ **MCP server** `ask-human-mcp.cjs`（POST→long-poll→返回回复，mock-edge 实跑验过）+ `InteractionChannel` 写 mcp.json + `--mcp-config` 进首/resume 回合；④ **prompt §10**（zh+en）改成 ask_human。机制全验：claude `auto` 自动放行 MCP 工具、`--mcp-config` 阻塞工具走通、`.cjs` 进 bundle。**未建/未验**：① **迁移没 apply + schema.ts 没 regen**（`crew-interactions.ts` 走 untypedRpc 才 typecheck 绿；落地前从主 worktree `db push`+`types:db`+收口）；② **人答的 UI**——卡片已由 RPC 发到 crew 群聊（direct-to-human），但**渲染 + 回复入口**没建（自然落点是 iOS PendingBot 交互卡=T4.3 卡片扩展，属并行 session 域；或 Mac 加个答复面板）；③ **captain 三角判断 + 沿 DAG 层层溯源**（spec §10.3-10.5）没做——现在是直发责任主体；④ 真实 edge auth 的端到端（要登录 + 迁移 apply）。**砍掉**：自建逐动作审批门禁 / Agent SDK `--permission-prompt-tool`（CLI 不存在）。
- ~~🔴 **`get_crew_whiteboard` 在 service-role 下 `RAISE 'auth required'`**~~ **（2026-06-03 已修，G1）**。根因：RPC 体内 `caller_id := auth.uid(); IF caller_id IS NULL THEN RAISE 'auth required'`，但 edge 一律用 **service-role client** 调它（auth.uid()=NULL）→ 必 500。这是 crew 上下文注入（白板→session，T4.1/T4.2 核心通道）真跑就炸的潜伏雷（同 `client_message_id` 类）。**修法**：`GET /v1/crews/:crewId/messages`（中栏）+ `GET /v1/sessions/:id/inbox`（runner）两处都改成**直接读 `crew_announcements` 表**（访问门禁在路由层已做），不再调该 RPC。已部署（`9f4234eb`）。RPC 没删（仍带 guard，将来 authenticated 调用方可用）。
- 🟡 **白板→session 注入闭环（G1-G3）只编译/端点 live，没真机跑过** (2026-06-03)。runner（`CrewSessionRun.runCrewContextPoll`）每 4s 拉 `/inbox`，把白板近况 + 未读 mailbox 渲染成 `<crew-whiteboard>` 块写进 `SteeringChannel` 的 crew-context slot（UserPromptSubmit hook 每轮 tail 注入，缓存安全），注入后 mark-delivered。**未验**：① agent 真跑时确实读到该块并按相关性行动（prompt 工程对不对、会不会被当成"任务"误执行——digest 里加了"这是参考不是任务"的提示，但没真测）；② 4s 轮询 + mark-delivered 的时序（同一条消息会不会在 mark 前重复注入一两轮）；③ 仅 logged Claude（Codex 无 steering channel → 不注入,BYOK 同）。归 T5.3 真机 QA。
- 🟡 **右栏「持续对话」回合完成后不续上下文（resume-after-complete 缺口）** (2026-06-03)。三栏重排后右栏 = composer-first 常驻 session（`CrewSessionWindowView`，spec §9 落地）：第一条消息零配置起 session，运行中再发 = `enqueueFollowUp` 走 `--resume` 续回合（保上下文 + 缓存前缀）。**但** claude `-p` 单回合跑完、队列空 → `finalize`（status=completed）。此后再发消息 `send()` 判 `status != .running` → **起一个全新 agent**（fresh context，丢历史）。所以「像 Claude Desktop 一直聊」只在**一个回合进行中持续发**时成立；agent 跑完闲下来后下一条消息会另起炉灶。真·持续对话要改 runner lifecycle：闲置不 finalize、下条消息 `--resume` 复活同一 agent session（`agentSessionId` 已存着，`startResumeTurn` 也在，差「completed 后还能 resume」这一段 + server row 不立即关）。属右栏体验的后续打磨，非阻塞。Codex 同理且更弱（resume 返回 nil）。
  - **（2026-06-02）iOS PendingBot 只读 viewer 已落地并真机验通（#204）** — `RemoteSessionsView.swift`（session 列表→push 转写，3s 轮询）+ `getCrewSessionEvents` / `CrewSessionLogEvent`，入口是 `CrewDetailV2View` 右上角 terminal 按钮（sheet）。镜像 Mac `RemoteSessionsView`（`acf9db29`）。**编译过 + 用户用骆店账号在 iOS 上打开 viewer 看到 test2 渲染（2026-06-02 验通）**。
  - **（2026-06-02）iOS viewer 实时层 + cancel 遥控已落地（#204 第二刀，编译绿）** — `SessionProxyClient.swift` + `SessionProxyProtocol.swift`（viewer-only 镜像 Mac `feat/t45-ws-transport` 的 SessionProxyClient）：viewer 连 `GET /v1/sessions/:sid/proxy/connect?role=viewer`（用 Supabase JWT，token 每次 reconnect 取 fresh），收 `session.state` → transcript 顶部实时 banner，工具栏「停止」按钮发 `session.command{kind:cancel}`。**仅 BUILD SUCCEEDED，端到端两设备 QA 未做**：要 Mac PendingCrew（带 `feat/t45-ws-transport` 的 runner 发布）起一个 **running** session 实时推 state，iOS 同账号 viewer 看实时 banner + 点停止能真的取消。wire 格式对齐 edge + Mac 已验证侧（Mac viewer 已验过发 cancel/收 state，`40870183`），实时层是 best-effort 装饰（连不上回退已验证的只读轮询）。**剩**：① 两设备 E2E QA（活 session）② permission.request/decision over WS（iOS 现走 HTTP T4.3 卡片，WS 实时通道未接）。
  - **（2026-06-02）PendingBot macOS 端 viewer 也落地（#204 第三刀，编译绿）** — PendingBot 是 iOS+macOS multiplatform 工程；把 viewer 所需的纯数据/网络/展示层抽成跨平台（`CrewSessionAPI.swift` / `SessionProxyClient` / `SessionProxyProtocol` / `CrewSessionPresentation.swift` 去掉 `#if os(iOS)`），新增 macOS UI `Sources/Mac/Views/MacRemoteSessionsView.swift`（Mac 三列 detail：crew 列表→session 列表→实时转写+cancel），接进 `MacRootView` 的 Crew tab。**iOS + macOS BUILD SUCCEEDED**。三端 viewer 齐：iPhone（已真机验只读）+ iPad（随 iOS universal，同代码，布局打磨待做）+ Mac（编译绿，**待登录骆店在 Mac app 真机看 test2 渲染**）。**copy-paste/DRY 注记**：Mac viewer UI 是 iOS `RemoteSessionsView` 的平台适配（HSplitView vs NavigationStack），逻辑重复但 SwiftUI 布局差异大，未强行抽共享 ViewModel；纯数据/网络/展示已抽共享。Mac 端 crew 其它业务（创建/群聊/详情）仍是 iOS-only，Mac 仅接了 viewer 这一刀。
- **T5.3 PendingCrew E2E QA** — BYOK 路径和 cloud 路径的端到端测试（创建 crew → 派单 → 收到结果 → 计费记账）从未真机跑通；只有编译过 + 单测覆盖。需要人工 QA pass。

### 部分/骨架级、需要补完

- **PendingBot 完整原生 Mac 版 — 2026-06-02 夜间进展(#212)** — 用户明确要完整原生 SwiftUI macOS(非 Catalyst)。架构:逻辑/数据/网络跨平台共享,UI 原生重画。夜间一口气接了 4 块,均两端 BUILD SUCCEEDED + 合 main:登录(MacWelcomeView+MacRootGate,Email OTP+Turnstile,**用户真机验通**)、机组 viewer(MacRemoteSessionsView)、消息(MacMessagesView + 跨平台 ChatDataSource,会话列表+1:1/群文字聊天+流式发送)、好友(MacFriendsColumn + FriendsDataSource,机器人+人类好友只读列表)。
  - **关键验证缺口(用户醒后必看)**:**Mac 真实 UI 渲染没截图核对**——agent 截不了 Mac 桌面(computer-use 掉线、screencapture 无屏幕权限)。已做的替代验证:① 所有 Supabase 查询的列名/FK/role 值用 live DB introspection 核对(messages.role 仅 user/bot、conversations_bot_id_fkey、user_unread_counts 列、user_bot_contacts FK 抄 iOS 已验证查询)② 命令行跑 Mac app binary 8s,stderr 无崩溃/无 401/无未捕获异常 ③ iOS 范本装模拟器截图确认跨平台抽取没退化。**但每个 tab 在 Mac 上实际渲染长啥样、点击交互对不对、流式聊天收发是否正常,需用户在 Mac app 逐 tab 真机过一遍**。
  - **各模块第一版简化(均记此)**:消息——无 Realtime(3s 轮询+发后 reload)、无附件/图片/语音、无 @提及、无群组 peer 解析、时间戳列刻意不 select(规避 Decodable 歧义);好友——只读,无点击进会话/头像图片(ServerImage iOS-only)/加好友/备注/排序;机组——仅 viewer,无创建/群聊/详情。
  - **DRY 注记**:iOS 的会话列表/消息加载逻辑内联在 `MessageTabView`/`ConversationView`(UIKit 耦合的 View),没法直接复用,所以 Mac 新建了 `ChatDataSource`/`FriendsDataSource` 跨平台 service 复刻同样的 Supabase 查询——查询逻辑与 iOS 有重复。未来可让 iOS 也迁到这两个 service 去重(改 iOS 范本有回归风险,夜间没动)。
  - **未做(夜间因复杂度+无法真机验时序而留)**:来信 tab(EnvelopeAPI:realtime-hub WebSocket + EnvelopeRun/Turn + thinking trace,最复杂)、机组完整(创建 crew 是写操作会污染 prod、群聊)、跨 tab 连贯交互(好友点击进会话需 ensure-conversation + SwiftUI 跨 tab selection 状态机,夜间无法验时序)、Realtime 推送(三端 Mac 现全轮询)、头像图片。


- **PendingCrew 后端单元测试** — `8e0eac32` 已记录：`apps/pendingcrew-server` 几乎没有单测覆盖，BYOK 路径切换、CrewStore reset、template store 三处都是裸代码。建议后续 session 补 vitest。
- **群权限矩阵 client 端消费** — `207d5203` edge 给了 `/v1/group-subjects/*` 路由，iOS / Mac 客户端还没真正消费；目前权限判定仍走旧 client-side 规则。
- **Mac 三栏壳的实际内容** — `c174f734` 是结构脚手架；middle column 的会话列表 + detail column 的消息流都还是 placeholder，等 IM 主路径打通后填。
- **First-launch disclosure modal 文案** — `280d5b7b` 走通了流程，正式文案待法务/产品定稿。
- **billing-v2 settleUsage CAS-loss retry** — `cbb4fb3f` 实现了重试，但极端高并发下的退避策略未压测；30 天观察期内若看到大量重试再优化。（注:billing-v2 settleUsage 已于 #209 整体退役删除,本条历史留痕。）

- 🟡 **计费 P2 throttle 档"降级"未实装（LLM 路径）** — `gateUsage`(`apps/edge/src/billing/usage-gate.ts`)已正确分出 4 档阈值(exhausted 硬停 / low / throttle / sufficient),`<5 PNC = throttle` 也正确返回,但 **throttle 时的"降级"动作没做**:计划里写的 OpenRouter `cost_quality_tradeoff=max` 经官方文档核实(<https://openrouter.ai/docs/guides/routing/routers/auto-router>)**只对 `model: "openrouter/auto"` 生效,且是 `plugins:[{id:"auto-router",cost_quality_tradeoff:10}]` 的 plugin 配置,不是顶层 `=max`**;本仓库 router 是纯 passthrough(把调用方 model slug 原样发),不走 auto-router,所以该参数对正常 slug 是 no-op。要真正"降级"得在 throttle 时(a)临时切到 `openrouter/auto`+plugin、或(b)切便宜模型 pin,并(c)关工具——这要把 threshold 信号穿过 `runChatTurn`/各 runner(memory/envelope/title/group)到 completion 构造处,跨多文件接线,本任务(Phase C)未做。**当前 throttle 等同 low(放行不降级)**,只是不会硬停。
- 🟡 **计费 P2 low 档"余额低"提醒未注入** — 阈值 low(<50 PNC)gate 正确放行,但"在下一条回复里注入余额低提醒(24h 去抖)"这个 UX 从未实装(billing-v2.ts 注释里只写了意图)。需要在回复渲染层加一个 threshold 信号通道 + 去抖。gate 层已就绪(`gateUsage` 返回 `thresholdState`),缺消费方。

- ✅/🟡 **计费 P2 群成本分摊(share-index)已重挂到 Polar/WalletDO**(2026-06-02,用户拍板"用 v2 共享池方法") — 计划 `docs/superpowers/plans/2026-06-02-group-wallet-polar-rehome.md`。已落:`billing/share-index.ts`(纯数学)+ 迁移 `apply_group_pool_spend`/`apply_group_contribution`/`apply_group_refund` 原子 RPC + `billing/group-wallet.ts`(contribute/refund/dissolve)+ 群消费在 router/群语音/sandbox 扣费后衰减 share_index + 端点 `/topup`(改 contribute)`/leave`(自退款)`/dissolve`。typecheck 0 + 523 测试。**剩余 🟡 尾巴(未做,见下三条)**:链式退款、漂移报警、`/leave` 不删 membership 行。
  - ✅ **链式退款覆盖群注资**(2026-06-02 完成,#210):`billing/group-wallet.ts clawbackFromGroups` —— Apple/Polar 退款先从用户各群 active 份额按 share_now 冲减(`apply_partial_withdraw` 缩份额+池 + `reduceCredits` 群 Polar,不返还用户)、再退个人剩余,平台只自担"已被群花掉"的部分。Polar `order.refunded` + RC `CANCELLATION` 两路接入。堵住"注资进群→退购买款→群留额度"漏洞。
  - ✅ **群池镜像漂移报警**(2026-06-02 完成,#210):`WalletDO.checkGroupPoolDrift` 在 alarm 对账时比对 `group_pools.total_remaining` vs Polar 群余额,偏差 > 1 PNC `console.warn`(不自动改写)。
  - ✅ **`/leave` 一步退群**(2026-06-02 完成,#210):退份额 + 清认缴(setPledge 0)+ service 直删成员行;群主拒退(须先转让/解散)。
  - ✅ **群 bot 异步回复前置 gate**(2026-06-02 完成,#210):`lib/group-dispatch.ts dispatchGroupTurn` 开头按群池+认缴聚合 `gateConversation`,exhausted 直接 `no_balance` 不发起 bot 回合(读失败 fail-open)。

- ✅ **billing-v2 退役完成(#209,2026-06-02)** — 删 16 文件:`billing-v2.ts`(settleUsage/packs)、`billing-v2-{group,pack,lemon,iap,iap-verify,refund,expiry}.ts`、pack 过期 cron;去掉 `/lemonsqueezy/webhook`·`/iap/*` 路由;`room-voice` OwnerRef→WalletOwner;清孤儿 env/cron。保留 `pnc_ledger` + `group_pools/contributions/pledges`。旧 packs/ledger 表留冷备。

- ✅ **`routes/me.ts /wallet/v2` 余额改读 WalletDO(2026-06-02)** — 余额/阈值走 `wallet.gate`,账本读 `pnc_ledger`,不再读已退役 packs 求和。

> ── 以下为 dashboard 栈接线(feat/dashboard-wiring)的待办 ──
#### 🟡 PostHog 行为事件 — 缺 server 端 seam 的事件（dashboard 栈 block 1）

边缘 PostHog 接线（`feat/dashboard-wiring`）已覆盖有服务端落点的事件：`message_sent` / `group_created` / `group_joined`(invitation+invite_link) / `voice_call_started`(1v1+group) / `voice_call_ended`(group) / `topup_succeeded`(iap+lemon webhook，`created:true` 时)。统一走 `lib/track.ts` 的 `trackEvent(c,...)`（fire-and-forget，无 PII）。**以下 spec 列出的事件在当前架构没有 edge 落点，未接，必须从别处补**（别当成"已全覆盖"）：

- **`signed_up`** — 用户/subject 创建是 Supabase signup 触发器（`me.ts:256` 注释提及），edge 无 signup handler。→ 由 iOS PostHog SDK 在登录/首启时 `identify` + 发，或加 DB 触发器→PostHog（P4，spec 的客户端侧）。
- **`bot_created`** — `routes/bots.ts` **没有 POST/create**，建 bot 是客户端直写 Supabase（仅 PATCH/GET/invite-links 在 edge）。→ 同上，由 iOS SDK 发，或 bots 表 AFTER INSERT 触发器。
- **`voice_call_ended`（1v1）** — 1v1 通话结束在 `RealtimeMeterDO`（计量 DO）里异步发生，route `/realtime/.../end` 是 no-op，edge 路由层无落点。→ 需要在 DO finalize 时发（DO 内 `capture(env,...)` 可用），未做。
- **群注资 / 认缴（`group_topped_up` / `group_subject_created`）** — `routes/group-subjects.ts` 有 `POST /:id/topup` 等落点，但该文件正被另一 session 改造（task #220-221 群钱包重构），为避免抢同一文件**本轮未接**；待群钱包改造落定后补 `trackEvent`。事件名已在 `AnalyticsEvent` 常量预留。
- **`topup_succeeded` 数据源随计费迁移** — 当前接在 billing-v2 iap/lemon webhook（仍是现行入账路径）。billing 引擎若迁到 **Polar**（见 memory `project_billing_outsourcing`），事件源要跟着搬到 Polar webhook，别留在退役路径上。



### 🟢 Grafana BI 依赖 `bi_ro` 只读角色 — ✅ 已解决（migration 20260602051354 建角色 + 20260604143012 正名 bi_ro）
- **发现**: 2026-06-03 · feat/dashboard-wiring
- **位置**: infra/grafana/（datasource provisioning 指向 `bi_ro`）
- **问题**: dashboard stack 第 5 块（Grafana 营收/钱包 BI）的数据源用 SELECT-only 角色 `bi_ro`，但本 worktree 里没有任何 `*metabase_readonly_role*` migration——角色不存在则数据源连不上。属于「依赖一个未落库的前置」。
- **影响**: Grafana 面板全部依赖此角色；未建角色前所有 dashboard 都是空的/连接失败。不影响主程序运行。
- **建议**: 补一条 migration 建 `bi_ro` 角色 + `GRANT USAGE ON SCHEMA pendingbot` + `GRANT SELECT` on（至少）`topups, billing_ledger, subject_wallets, subjects, group_member_billing, conversations, audit_log, users, bots, group_join_requests`；或手工 SQL 建角色。建好后在 Grafana Cloud 填 datasource 密码 + 确认 Supabase 网络放行（pooler 公网可达或配 PDC）。
- **状态**: 待办（前置依赖，需用户落库角色 + 配 datasource）

### 🟡 admin 控制台（apps/admin）依赖的 edge admin 端点尚不存在 —— dataProvider 指向"意图路径"，调用即 404
- **发现**: 2026-06-03 · feat/dashboard-wiring（dashboard stack block 4）
- **位置**: `apps/admin/src/providers/resource-map.ts`（`RESOURCE_ROUTES` + `ADMIN_ACTION_ENDPOINTS`，逐条标了 `exists:false`）、`apps/admin/src/providers/data-provider.ts`、`apps/edge/src/index.ts`（v1 路由挂载处，**当前无任何 `/v1/admin/*`**）
- **问题**: 新建的 Refine admin 控制台按 spec 要求"读写都过 edge、绝不直连 Postgres、前端不持 service-role key"，所以 dataProvider 把每个资源映射到 edge REST 路由。但**edge 目前没有 admin 路由面**：`users.is_admin` 字段在 DB 里存在，`@pendingbot/identity` 也导出了 `requireAdmin(...)`，但**全仓没有任何地方 mount 或使用它**。控制台为了不埋"假装能用"的 stub，把这些资源指向**意图中的** edge 路径并在代码里 `exists:false` 标注 + 页面渲染告警横条；调用当前会 404。
- **影响**: 控制台骨架可编译、可登录（Supabase Auth → JWT），但除下面两条已存在的 route 外，所有 admin 读/写页面都打不通真实数据，直到 edge 补齐这些端点。属于"先把前端接好、等后端落地"的刻意取舍，不是无声 stub。
- **已存在、控制台已复用的 edge 面（仅这两条）**:
  - `GET /v1/human-help-requests?status=...`（**requester-scoped**，按 `requested_user_id = caller` 过滤）+ `POST /v1/human-help-requests/:id/decision {decision: accepted|declined}`
  - `POST /v1/permission-requests/:id/decide {decision: approve|reject}`
- **控制台需要、但 edge 尚不存在的端点（完整清单，全部待办）**:
  1. `GET /v1/admin/users`（list）+ `GET /v1/admin/users/:id`（show）—— 用户清单（id/handle/created_at/subject），跨用户、需 is_admin。
  2. `GET /v1/admin/bots` + `/:id` —— bot 清单（visibility/model/owner）。现有 `/v1/bots` 是用户态，非 admin 列表。
  3. `GET /v1/admin/conversations` + `/:id` —— 会话清单/详情。
  4. `GET /v1/admin/billing/ledger` —— 计费台账读。**注意 spec 写的 `pnc_ledger` 视图在 schema 里不存在**；真实来源是 `pendingbot.billing_ledger` 表（+ `subject_wallets` 取每主体余额）。要么建 `pnc_ledger` 视图，要么端点直接读 `billing_ledger`。
  5. `GET /v1/admin/billing/group-pool` —— 群池/分摊读。**schema 里没有 pool/pledge 视图**；最接近的源表是 `group_billing_config` + `group_member_billing`，需要端点聚合或建视图。
  6. `POST /v1/admin/billing/wallet/grant` —— 钱包发放额度（写 `subject_wallets`/`billing_ledger` + `admin_audit`）。
  7. `POST /v1/admin/billing/wallet/clawback` —— 钱包回收（负 delta）。
  8. `POST /v1/admin/billing/ledger/adjust` —— 直接台账调整（entry_type=adjustment 等）。
  9. `POST /v1/admin/users/account-op` —— 账户操作（freeze/unfreeze/delete）。
  10. `GET /v1/admin/permission-requests`（list）—— 权限审批**列表**（decide 动作已存在，但没有 admin 列表读）。
  11. `GET /v1/admin/human-help-requests`（list）—— **admin-wide** 人工协助队列（现有那条只看 caller 自己被点名的，不是全局队列）。
- **建议**: 新建 `apps/edge/src/routes/admin.ts`，挂在 `/v1/admin`，第一道中间件 `requireSession()` 后接 `requireAdmin(c => SELECT is_admin FROM pendingbot.users WHERE id=c.var.userId)`，所有读用 `serviceClient` 跨用户查、所有写进 `admin_audit`（actor_id/before/after/ip/user_agent 已有列）。读端点返回 `{ items: [...] }`（控制台 dataProvider 已按此 normalize）。建端点时同步把 `resource-map.ts` 对应条目翻成 `exists:true`，并把本条状态推进。计费两个端点落地前先决定 `pnc_ledger` 视图建不建（spec 名 vs 实表名的口径要统一）。
- **状态**: 待办（控制台前端已接好并可编译/构建；等 edge admin 路由面落地）


- 🟡 **旧 per-conversation 分摊模型"连根拔"未完(invite 流耦合 + 物理 drop 待协调)** — `feat/ios-wallet-group`(2026-06-03,基于 `chore/retire-billing-v2`)。群消费结算早已切到责任 subject 的实缴池+认缴(`settleGroupSpend`),用户拍板 iOS+edge 连根拔旧 per-conversation `group_member_billing` 分摊。**本拍已做**:删 `lib/group-billing.ts`+测试(死)、删 `groups.ts` 的 `/billing|/cap|/participates` 三路由。**未做(耦合群邀请流 + iOS,独立一摊)**:(a) `groups.ts:groupBillingInviteSnapshot` 仍读 `group_member_billing` 生成邀请预览"分摊"文案,两处调用(创建群邀请 / 邀请预览)嵌进 invite 响应,iOS `FriendsTabView` 消费 `mode_label/invitee_participates/payer_count_after` —— 新模型无 per-conversation "participates" 概念,该快照前提已不成立,需解耦/移除并改 iOS 邀请预览 UI;(b) 接受邀请 handler 仍写 `group_member_billing`(seeding)+ 用 `group_member_invitations.invitee_participates`;(c) 物理 drop 迁移:`group_member_billing` 表 + `group_set_billing/cap/participates` RPC + `group_member_invitations.billing_snapshot`/`invitee_participates` 列。**(c) 必须在 `chore/retire-billing-v2` 部署、且 (a)(b) 解耦后再 apply**(生产 main 当前仍 live 在旧模型上,提前 drop 会 500)。建议作为独立 task 整体收口,别塞进钱包 UI 这一拍。

- 🟡 **iOS 群钱包/个人钱包 UI 依赖的 edge 端点只在 `chore/retire-billing-v2`,未合 main** — `feat/ios-wallet-group` 基于 `chore/retire-billing-v2`(75 commits ahead of main)。新加的 `GET /v1/group-subjects/:id/wallet` + 已有的 `/pledge`/`/withdraw`/`/leave`/`/dissolve` + `/wallet/v2`(micros+null ledger)都在该分支,**main 上没有**。iOS 改动编译不依赖 edge,但**运行期端点 404 直到该 billing 分支部署**。合并/部署排序:iOS 钱包 UI 必须随/在 billing 分支之后上线,不能单独先合 main。本 feat 分支应并入 `chore/retire-billing-v2`(或与之同批合 main),不走独立合 main。

- 🟢 **群部分取出 `/withdraw` 流式回合诚实小角** — spec §5:流式回合最终成本要回合结束才精确,若有人正流式中途取走,极端下池子在末笔扣款落地时可能短一点点;overdraft 缓冲 + 新回合过门禁兜着,预发布可忽略。记此备查。

- 🟡 **billing-v2 / v1 退役后的 DB 孤儿全清单(表 + RPC + 触发器)** — 摸查于 2026-06-03(`feat/billing-obs-killswitch`)。新计费只读 `pnc_ledger / group_pools / group_contributions / group_pledges / subjects / group_subject_members`(+ `billing_config` 的 markup/threshold),余额真相在 WalletDO→Polar。以下是退役 billing-v2 + provider 转向后**线上库仍在、但新模型不读**的工件,按"能否直接 drop"分层。**记录不自动删**(数据销毁性;且部分在生产 main 仍 live,须等 `chore/retire-billing-v2` 部署后才能 drop)。

  **A. 纯孤儿(无任何活代码路径,可随 #226 一并 drop):**
  - 表:`billing_ledger`、`group_billing_config`、`group_billing_custom_shares`、`ledger_entries`、`packs`、`topups`、`refund_events`(退款现走 `pnc_ledger`)
  - RPC:`billing_admin_grant`、`billing_credit`、`billing_debit`(仅被死函数 `lib/billing.ts:billingDebit` 调,无活调用方)、`billing_debit_subject`(仅被死函数 `debitSubject` 调)、`billing_issue_codes`、`billing_v2_admin_adjust`、`group_set_billing`、`grp_topup_wallet`
  - 触发器/触发函数:`on_user_billing_signup` + `billing_signup_bonus()`/`billing_signup_bonus_trigger()`(写 `packs`,新模型不读 → 详见 #244)

  **B. 半死(代码仍碰,但模型已废 → 属 #226 收口,drop 前须先解耦):**
  - `group_member_billing` 表 + `group_member_billing_freeze_trg`/`_group_member_billing_freeze_trigger()` —— `routes/groups.ts:67/403` 仍在群邀请/加入流里 SELECT/INSERT
  - `subject_wallets` 表 + `subject_wallets_sync_updated_at_trg`/`tg_subject_wallets_sync_updated_at()` —— `lib/billing.ts:getSubjectBalance` 仍被 `routes/me.ts` 调(很可能展示陈旧值,真相已是 WalletDO/Polar)

  **C. 活着但很可能还在充旧钱包模型(同 signup bonus 的"孤儿入账"病,需决策/重建,非纯删):**
  - `billing_redeem` RPC + `redemption_codes` 表 —— 兑换码功能经 `routes/me.ts` 活调,但兑换大概率仍写 billing-v2/`subject_wallets` 而非 Polar credit。要么重建到 Polar(注册送同款,见 #244),要么暂时下线。**别当纯孤儿删**。

  **死 edge 代码(随 drop 一起清):** `lib/billing.ts` 的 `billingDebit`/`debitSubject`/`getSubjectBalance` + `balance-cache.ts`(v1 KV 余额缓存)+ 相关 `getBalanceGateState` 旧 1v1 gate 路径。

  **建议**:把 A 段整体并入 #226 的物理 drop 迁移(同一 `chore/` 批次);B 段先做 #226 的 invite 流/me.ts 解耦再 drop;C 段与 #244 一起拍板(送不送 / 兑换走不走 Polar)。drop 顺序硬约束:`chore/retire-billing-v2` 必须先部署到生产,否则提前 drop 会让线上旧路径 500。
  **状态**:待办(已登记,等 #226/#244 推进时按 A/B/C 分层落)

- ✅ **billing-v2/v1 孤儿 A 段已 drop(2026-06-03 部署)** — 上条「全清单」的 **A 段**(表 billing_ledger/group_billing_config/group_billing_custom_shares/ledger_entries/packs/topups/refund_events + 8 孤儿 RPC + on_user_billing_signup 触发器)已随迁移 `20260603112148_drop_billing_v2_orphans` apply 到生产(先部署新 edge 代码再 drop,无 500)。**C 段**(兑换/送)已重建到 Polar:`billing_redeem` 退化为只校验(迁移 20260603111613),送(35 PNC)/兑换入账走 `lib/billing-grant.ts` 的 ensureCustomer+grantCredits,均受 BILLING_ENABLED 门控。**残留**:ensureCustomer 的 409(已存在客户)吞掉分支未经 sandbox 实测(P0 spike 已验证全新客户的 create+grant+balance;409 支 dormant,billing 关时不触发)——启用计费前用 token 跑一次 spike 坐实即可。**B 段**(subject_wallets / group_member_billing + invite 流 + iOS)仍是 #226。

- 🟢 **死代码全项目扫描(2026-06-04)— 安全区已清,Swift 区待对应 session 清** — `feat/billing-obs-killswitch`。用 workflow fan-out 8 region 扫了全仓死代码(60 项)。
  **已清理(edge/supabase/packages 安全区,15 项,typecheck+vitest 守门,484 测试绿)**:删 `lib/balance-cache.ts` 整模块 + `getThreshold`/`_resetThresholdCache`/threshold 缓存簇 + `billingDebit`/`billingDebitSubject`(已在退役批) + `gateUsage`/`GateResult`(throw 版前身) + `decayShareIndex` + `isNativeAdapterStyle` + `_resetCatalogCache` + `_resetWebToolPriceCache` + `SessionUser`(identity) + 6 个废 IAP/LemonSqueezy ApiErrorCode + crews.ts 的 `ApiErrorCode` re-export + index.ts/http-error.ts 过时注释 + 死脚本 `dev:web`(无 apps/web)。
  **安全区暂留(review,价值低/需判断,未删)**:`models.ts` 4 个 LMArena* 过度 export + `crews.ts:accessibleSubjectIds` 过度 export(去 `export` 关键字即可,低价值,crews.ts 属 crew session territory 故未动);`identity/jwt.ts:ALLOWED_JWT_ALGS` 过度 export;`sandbox.ts:deleteSandbox`(0 调用但注释称"会话拆除时调"——**误导注释**,可能是未接的 future teardown,建议要么接上要么删注释);`supabase` 的 `v_audit_daily`/`v_audit_monthly` 视图(edge 0 引用,可能留给 BI,删需迁移);`createPolarClient`/`PNC_EVENT_NAME` 是**假阳**(被同文件 polarFromEnv 内部用,勿删)。
  **✅ 已查清(非 bug,已删)**:`persona-cache.ts` 的 `deleteCachedChatMemo`/`deleteCachedBotNote` 当时疑似"缓存从不失效"。追查确认**不是 bug**:chatMemo/botNote 只由 `memory.ts` 的 `refreshChatMemo`(:496)/`refreshBotNote`(:344)写,且这俩 refresher 改完 DB 后**立即 write-through**(`putCachedChatMemo`/`putCachedBotNote`)——缓存始终新鲜,无需 delete 式失效。这俩 delete helper 是当初连着 put/get 顺手写的多余件,已删除。

- 🟡 **iOS/macOS/crew Swift 死代码清单(22 项)— 交接给 pendingbot / pendingcrew session(本 lane 不动)** — 同一次扫描的 Swift 区。Swift 无廉价 unused 检测,以下均 rg 证据(符号全仓仅定义),**删前 owner session 必须 xcodebuild 验证**(可能有 storyboard/动态引用)。多数像被取代的旧面:
  - **旧 billing-v1 iOS 钱包面(疑被 WalletV2View 取代)**:`Features/Me/WalletView.swift:WalletView`、`Networking/BillingService.swift`(fetchBalance/fetchLog/redeem/fetchSummary/applySilentUpdate + Balance/LogEntry/LogPage/Summary/RedeemResponse 等嵌套类型)——若 UI 已切到 WalletV2View/GroupWalletView,整个 BillingService + WalletView 可能整体死。**高价值核查**。
  - **BigScreen 实验面**:`Shared/PendingBotBigScreenApp.swift`(PendingBotBigScreenAppView / PendingBotCrewWorkspaceView)+ `Shared/PendingBotSharedModels.swift` 一大批 `PendingBotCrew*` / `PendingBotBigScreenTab` 类型(疑 BigScreen 原型残留)。
  - **其它 0 引用**:`Features/Me/AccountsView.swift:AccountsView`、`Components/TabTitle.swift:TabTitle`、`Mac/Views/MacEnvelopeView.swift:MacEnvelopeDetail`、`Models/APIModels.swift` 的 `MeProfile`/`AiPick`、`pendingcrew .../LocalRunnerPlaceholder.swift:LocalRunnerModule`。
  - **过时常量**:`Features/Me/WalletV2View.swift` 的 `channelLabel` 还留 `iap_ios`/`iap_macos`/`lemon_squeezy` 分支(渠道已转 Polar/RevenueCat)。
  - **构建产物入库**:`apps/ios/build/**`(.xcarchive/.ipa)疑被 git 跟踪——应 gitignore + 移除。
  建议各 session 在自己分支用 Xcode 的 unused 检查/编译告警逐个核掉,别由计费 lane 跨改。

- 🟡 **Mac 三种登录已接通+编译过,但 Apple/Google 真实登录回合未验(邮箱 OTP 已可信)** — `feat/mac-login-align`(2026-06-04,#253/#212)。Mac `MacWelcomeView` 重画对齐 iOS,三种登录代码都接上:邮箱 OTP 走跨平台 `EmailSignIn`(**已可信**,与 iOS 同一条路);Apple 走原生 `ASAuthorizationController`(NSWindow anchor),Google 走 GoogleSignIn-iOS 的 macOS target(`signIn(withPresenting: NSWindow)`)。iOS+macOS 双端 `xcodebuild` 均 BUILD SUCCEEDED,但**Apple/Google 在 Mac 上的真实 sign-in 回合没跑过**(本 session TCC 屏幕录制权限被拒,连截图都做不了,更没做真登录)。两个**外部配置依赖**会决定它们能否真的成功,启用前必须坐实:
  - **Google macOS OAuth client**:`Info.plist` 的 `GIDClientID`(`842392349572-…apps.googleusercontent.com`)+ reversed URL scheme 是当初按 **iOS 型** OAuth client 配的。Google 原生 macOS 登录要求 client 的平台/bundle 匹配,iOS 型 client 在 macOS 上**可能**报 redirect_uri_mismatch / invalid_client。需在 Google Cloud Console 给 `com.pendingname.pendingbot` 加/确认一个 **macOS 型** OAuth client(或确认现有 client 接受 macOS bundle),并把其 client id 填进 Supabase Authorized Client IDs。**没验证过 = 可能一点就挂**。
  - **Sign in with Apple**:entitlement(`com.apple.developer.applesignin`)已在共享 `PendingBot.entitlements`,EU 库 `/auth/v1/settings` 实测 apple enabled(见 progress 2026-06-04 Phase 4)。Mac App ID 需带 SIWA capability(自动签名通常带);真机/真账号点一次确认即可。
  **验证清单(启用 Mac 端 Apple/Google 前必跑)**:① Mac GUI 构建(非 headless,否则签名回落 ad-hoc → Keychain -34018,session 存不住,和反复误诊的那个坑同源)② 真点 Apple → 成功落 supabase session ③ 真点 Google → 同上(先确认 macOS OAuth client)。**在坐实前别对外声称 Mac 三种登录可用**——当前只到"编译过 + 邮箱 OTP 同路可信"。

- 🟡 **新钱包(WalletV2View / MacWalletView)无兑换码入口** — `feat/mac-login-align`(2026-06-04,#253)。删死的 v1 `WalletView` 时连带删了它独有的兑换码 UI(`BillingService.redeem`)。新钱包 `WalletV2View`(iOS)/`MacWalletView`(Mac)都**没有**兑换入口。后端 `billing_redeem` 已退化为只校验、送/兑换入账走 `lib/billing-grant.ts`(见 billing 退役条目),即后端仍能兑换,但**两端 App 都没有让用户输入兑换码的地方**了。删除本身不算回归(v1 WalletView 早已零引用、不可达),但"用户如何兑换码"是个产品缺口:要么在新钱包加兑换入口(iOS+Mac),要么确认兑换只走别的渠道(如深链/网页)。待用户定。

- 🟡 **Mac 加好友/建管机器人原生重画落地,但裁掉了 iOS 的若干高级面 + 无扫码** — `feat/mac-login-align`(2026-06-04,#212)。`Sources/Mac/Views/MacBotManagement.swift` 新增 macOS 原生 `MacAddFriendSheet`/`MacAddBotSheet`/`MacCreateBotSheet`/`MacManageBotSheet`/`MacModelPickerSheet`,逻辑全复用跨平台 SupabaseStack/APIClient/AccountStore/ModelCatalog,沿用同一 RLS。双端 BUILD SUCCEEDED。**有意未对齐 iOS 的部分(缺口)**:
  - **建机器人只支持单模型**:iOS `CreateBotSheet` 的 step1 是 `ArenaModelPoolEditor`(价格区间池 / 多模型竞技场,iOS-only),Mac 没移植——Mac 建的 bot 一律单模型。建/管里都没有 arena 入口。要补需把 arena 池编辑器抽成跨平台或 Mac 重画一版。
  - **管机器人裁掉多项 iOS 子面**:iOS `ManageBotSheet` 还有 语音通话 toggle、分段气泡(output_mode,走 PATCH /v1/bots 拍 KV 缓存)、机器人时区 picker、被邀请人管理(InviteListEditor / InviteContactPickerSheet)、分享机器人(BotSharePage 邀请链接/二维码)、以及 BotConfigView(主/识图模型、联网搜索、写信设置、自动回看、技能)。Mac 第一版**只做** 改名/模型/可见性升级/slug/删除。其余 Mac 端均缺。
  - **加好友/加机器人无扫码**:Mac 无摄像头,`MacAddFriendSheet` 只做输入号码/隐私号路径;`MacAddBotSheet` 只是邀请制说明页——iOS 的 QR 扫码 + universal-link 兑换 invite token 流(resolve/redeem /v1/bot-invites)在 Mac 没接。后续可补「粘贴邀请链接」入口走同一 resolve/redeem(BotInviteAPI 已跨平台)。
  - **无头像选择器**:建/管机器人都没头像上传(iOS 走 iOS-only 图片选择器),Mac 仅 emoji 占位。可后续用 NSOpenPanel 接。
  - **MacBotSlugRule 是 iOS `BotSlugRule` 的手抄副本**(后者在 `#if os(iOS)` 里不可见)。两处规则需手动保持同步;服务端 slug 约束才是真源。
  **均为真机/真账号才能端到端验**:写操作(建/改/删 bot、发好友申请)本 session 只编译校验,未跑真实回合。

- 🟡 **Mac 聊天/会话列表已接 cache-first(复用 iOS LocalDatabase),但"把编排抽成共享 store 两端共用"仍待 iOS 真机回归** — `feat/mac-login-align`(2026-06-05,#212)。Mac `MacChatView`(消息)+ `MacConversationListColumn`(会话列表)现在镜像 iOS 的 cache-first:打开先从跨平台 `LocalDatabase` 读缓存秒开 → 拉服务端 → 用 iOS 同款 `replaceMessages`(单事务 / cmid-aware upsert)+ `upsertConversations` 写回。编排落在跨平台 `ChatDataSource`(`cachedConversations`/`cachedMessages` 读缓存,`listConversations`/`loadMessages` 写回),复用 `MessagesFetch`/`ConversationFetch`/`LocalDatabase`,**没有新建 Mac-only 缓存表**。双端 BUILD SUCCEEDED。**缺口 / follow-up**:
  - **未跑真机回归**:cache-first 的"先缓存秒开 → 网络覆盖 → 写回"在本 session 只编译校验,**没在真实登录态 / 真机上跑过**(秒开是否真即时、写回与 Realtime 刷新是否有竞态、离线再开是否仍有内容、replaceMessages 删-插事务中途无空窗——均未观测)。需用户在场做一次。
  - **编排仍是两套(iOS 在 `ConversationView+Loading`/`MessageTabView` 里内联,Mac 在 `ChatDataSource` 里镜像)**:本 session **刻意未动 iOS shipping 代码**(避免无真机回归时改已验证的 iOS View)。把两端的 cache-first 编排抽成一个**完全共享的 store**(读+网络+diff/merge+写回一处,两端只接 UI)是正经的下一步,但那是重构 iOS 已验证路径,**必须等用户在场做 iOS 真机回归**再动。当前镜像有结构性重复:cache 写回的 row 映射、error 抑制策略、sender 解析在 iOS 与 Mac 各写了一遍,column/policy 改了要两处同步。
  - **未读数 cached 首屏为 0**:`cachedConversations` 缓存行不带 unread(iOS 的未读真源是 server-truth unread store / `user_unread_counts`,不在 conversations 表),所以纯缓存首屏的红点要等网络刷新才出。可接受(和 preview/排序一拍 settle),但和 iOS 完全一致需把未读也落进某个 Mac 可读的缓存通道。
  - **缓存消息无附件**:`LocalDatabase.messages` 没有附件列,cached 行是纯文字,图片/文件 chip 等 `loadMessages` 网络往返解析——与 iOS 缓存 hydrate(`attachments: nil`)一致,非 Mac 独有缺口。
