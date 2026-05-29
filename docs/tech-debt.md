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

### 🔴 PendingBot Mac 端业务接入只覆盖 5 tab 中的 1 个,其余仍是 placeholder
- **发现**: 2026-05-29 · feat/mac-multiplat-t01-p0(worktree wf_bb2bdb07-141-5)
- **位置**: `apps/pendingbot/Sources/Mac/MacRootView.swift`、`apps/pendingbot/Sources/Features/**`、`apps/pendingbot/project.yml`
- **问题**: T0.1 P0 把 `project.yml` 里的 `EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]` 大锅排除摘掉了,改用 `#if os(iOS) ... #endif` 包住每个 iOS-only 文件。但实际包了 `Sources/Components/*` + `Sources/Features/*` 整两层目录(再加 Networking 里 7 个文件),原因是这些目录里的 UI 类全部转性依赖 UIKit / PushKit / CallKit / Theme(UIColor) / Haptics(UIKit)。Mac build 现在能过,但能拿来用的 Mac 真实视图只有 `MacMeView`(账号信息 + 退出登录),消息 / 好友 / Crew / 来信 4 个 tab 仍是 `MacTabPlaceholder`。
- **影响**: 用户在 Mac 端只能看自己账号 + 登出,看不到任何聊天、好友、Crew、来信内容 — Mac 端基本不可用。后续 T0.1 P1+P2 真正接业务时,要把 iOS 业务里 UIKit-tied 的小部件抽成 cross-platform 等价物(`UIImage`→`Image+platform helper`、`UIPasteboard`→`NSPasteboard`、`Haptics`→Mac noop、`UIViewRepresentable` 桥不能用要找 SwiftUI 等价或 Mac-only 重写),工作量按文件数估在 30+ 文件级别;短期不可能"开关一拨就好"。
- **建议**: T0.1 P1 — 先把 Models / Storage / Networking 里已 cross-platform 的部分往上抽通用 `Theme` / `PlatformColor` / `PlatformImage` 抽象层,让 `Sources/Components/` 里小部件(`UserAvatar` / `BotAvatar` / `Theme` / `Haptics` / `Platform` / `RelativeMessageTime` / `EmptyHint`)能不带 `#if os(iOS)` 编译过 Mac;T0.1 P2 — 接 `MessageTabView` 等价物(读 supabase `conversations` + 走 `ChatStream` 已是纯 Foundation),把"消息" tab 做出来。Crew / Call 强依赖 PushKit/CallKit 的,Mac 端等 v2 再说。
- **状态**: 待办(P0 已完成 — 见 commit 388f24fd + 4eff9d8e)

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
- **状态**: 待办

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

### 🟢 ~~模拟器 Keychain -34018 登录失败~~ → 其实是后端 signup bug 的误诊(已纠正)
- **发现**: 2026-05-29 · v1 QA;2026-05-29 复盘纠正
- **位置**: 误指 `apps/pendingbot/project.yml` / `Resources/PendingBot.entitlements`;实因 `bootstrap_user_id` 等 signup RPC
- **纠正后的真相**: 之前把模拟器邮箱登录失败归因为"sim 不签名 → `keychain-access-groups` 不生效 → `-34018` → session 存不进 Keychain"。**这是误诊**。三条证据推翻它:① `keychain-access-groups` 自 T0.1 脚手架(`4b305f1a`)起就在 entitlements 里,不是新增,无法解释"突然不行";② 关键 tell —— 故障期 **Google 登录正常、只有邮箱登录失败**;若真是 Keychain 问题,两条登录都要存 session 到 Keychain,会**一起挂**,Google 能成功恰恰证明 **sim 的 Keychain 工作正常**;③ 邮箱 OTP 走 `shouldCreateUser=true` 的建号路径,正好踩中当时坏掉的后端 RPC(`bootstrap_user_id` 的 `bot_id` 歧义、`uuidv7` 对 authenticated 无执行权、`is_bot_invitee` 残留),"permission denied for table users / auth session missing" 是后端 bootstrap 失败后拒绝 PATCH,不是 client 存不住 session。
- **影响**: 误诊本身耗了不少时间,也差点逼出"sim 用内存版 AuthLocalStorage"这种没必要的 workaround。模拟器**可以正常登录和测试**(签不签名都行;CLI ad-hoc 签名 entitlements 是空的,但 sim 的 Keychain 默认 access group 不依赖它)。
- **建议**: 模拟器是可信的 auth 测试环境,无需真机兜底。后端 signup bug 已修并部署(见对应迁移)。CLI 不签名构建只用于编译校验;运行时测试直接装 unsigned 或 Xcode GUI 构建都可登录。
- **状态**: 已解决/纠正(2026-05-29 · 根因是后端 signup bug,已修+部署;Keychain 结论作废,留作"别再被表象误导"的记录)

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
