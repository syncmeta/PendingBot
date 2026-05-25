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

### 🔴 Edge 用户态路由里 service-role 鉴权边界过于分散
- **发现**: 2026-05-25 · codex/security-architecture-audit
- **位置**: `apps/edge/src/routes/messages.ts`、`apps/edge/src/routes/groups.ts`、`apps/edge/src/routes/group-voice.ts`、`apps/edge/src/routes/contacts.ts`、`apps/edge/src/routes/friend-requests.ts`
- **问题**: 多个用户可调用的 route 在 `requireSession()` 后直接使用 `serviceClient()` 绕过 RLS，再在 handler 内用本地查询、RPC 或 if 分支证明 membership/admin/owner。单个点大多有检查，但检查语义分散在大文件里，缺少统一的“以用户身份解析资源 + 明确提升到 service-role 写派生状态”的边界。
- **影响**: 越权风险会随功能增长放大：新增分支很容易漏掉某一种 conversation type、subject role、deleted/withdrawn 状态或 billing ownership；审计也只能逐个 handler 追踪，难以证明最小权限。
- **建议**: 收敛出 route 级授权层，例如 `loadConversationForUser`、`requireGroupRole`、`requireSubjectRole`、`withServiceWriteAfterAuthz`，并为每类资源维护一套负向授权测试；优先拆 `messages.ts`、`groups.ts`、`group-voice.ts` 这种 800+ 行入口。
- **状态**: 部分修复（2026-05-25 · 新增 `apps/edge/src/lib/route-authz.ts` 和 `route-authz.test.ts`，`groups.ts` / `group-voice.ts` 的 group conversation、human/bot participant、owner/admin 检查已迁入共享 helper；`contacts.ts` 的 singleton `user_user` 会话查找已收敛到 `findSharedUserUserConversation`，`open-chat` 创建已下沉到带 advisory lock 的 `open_user_user_conv` RPC，防止多设备并发创建重复 1v1 会话；`messages.ts` 的 hard delete 权限已迁入 `authorizeMessageDelete`，recall 权限已迁入 `authorizeMessageRecall`，普通发消息会话/peer-gone 检查已迁入 `authorizeMessageSendConversation`，附件所有权检查已迁入 `authorizeAttachmentOwnership` 并复用于普通发送和首轮 `/messages/start`，并修复“群主硬删别人群消息”的越权边界；`friend-requests.ts` 的 peer-id 加好友必须带 source group 并验证双方同群；`messages.ts` normal send / regenerate 共用 `authorizeBotUse`，修复 regenerate 漏掉 revoked `public_invite` 复核的问题；`messages.ts` 三条 bot turn 路径的 pinned model / arena random routing 已收敛到 `resolveMessageBotTurnRoute`，余额 402 payload 与 auto-lookback parent lookup 已抽成本地 helper。剩余主要是继续把普通发送 Phase 2 前置阶段拆成更小的可测试 primitive。）

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
- **状态**: 待办

## 🟢 不规范

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
