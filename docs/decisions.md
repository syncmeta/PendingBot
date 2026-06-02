# 产品 / 设计决策登记 (Decision Log)

记录**拍过板的产品/设计决策**,防止"记得设计过、代码里却找不到"的反复丢失。这是四账本里"决策"维度的家(task=做没做 · roadmap=计划 · tech-debt=风险 · progress=状态 · **decisions=拍过的板**)。

每条格式:决策内容 · 日期 · 背景/为什么 · **现状核实**(代码里是否已对齐;🔍=待核实,✅=已核实在,❌=确认缺失)。拍板后写一条;落地后更新现状核实。

---

## D1 · Bot 邀请模型 = 好友可邀 + 链接关联邀请者 + 透明留痕
- **日期**: 2026-06-01
- **决策**:
  - bot **纯邀请制**,slug **不是**加入路径(`public_open` 已删)。
  - **任何「bot 的好友」**(在 `user_bot_contacts` 有该 bot 的人)都能签发邀请链接。不做"被授权的人"这种额外委派。
  - 链接 = **邀请者签发的、可复用凭证**(默认 7 天有效、可手动撤销),像微信群邀请二维码 / 网盘分享链接。持链接者有权加入。
  - **关联到邀请者**:兑换时记 `invited_by = 邀请者`。
  - **好友列表对所有好友透明**:任何好友能看到该 bot 还有哪些好友、以及**每个好友是谁拉进来的**。
- **背景**: #121-128 原实现是 slug-as-public-identity(陌生人按 slug 直查),与邀请制 RLS 正面冲突、ship 即坏(见 tech-debt 🔴 bot 分享 RLS)。本决策把它返工成 invite-token 模型。
- **落地方向**: 新表 `bot_invite_links(token, bot_id, inviter_user_id, expires_at, revoked_at)`;service-role 预览/兑换端点(RLS 不放宽);客户端外壳复用、内核换 token。slug 保留当展示 @名。
- **现状核实**: ✅ **已实现 + 端到端验证(2026-06-01)**。DB(#191)+ Edge(#192/#193,已部署 prod worker)+ iOS 全返工(#194,签名构建装模拟器实测)。收件人路径真机验证链:universal link `/b/<token>` → 加机器人页 → resolve 预览(真 bot +「由 X 邀请你加入」)→ 添加 → redeem → 进聊天;DB 确认 `user_bot_contacts.added_via='invite_link'` + `invited_by` 留痕。无效 token 显示「邀请链接无效」。**残留(低风险,未单独视觉验)**:发件签发页(BotSharePage,创建者可进公开 bot 管理→分享验);CreateBotSheet slug 栏旧文案(#123)。

## D2 · 群加入码 = 每人一码、各自关联到本人(邀请者)
- **日期**: 2026-06-01
- **决策**: 群加入码也走"关联邀请者"模型,但形态是**每个群成员看到的是关联到自己的那份码**——使用时当"群的码"用(扫了就进这个群),但每个人的码不同,从而留痕"谁是被谁拉进来的"。
- **背景**: 现状群 handle 是单一共享码,任何人拿到就能请求加入,不记是谁分享的,与 D1 的 bot 邀请哲学不一致。统一成同一套"邀请关联到人"。
- **现状核实**（2026-06-01）:
  - **后端 ✅ 已落地**（迁移 `20260601082502`,push live + edge typecheck 绿）：`group_invite_links` per-inviter token 表 + `conversation_participants.invited_by` / `group_join_requests.invited_by` + RPC create/list/revoke/resolve/redeem;`group_join_request_decide` 批准时把 invited_by 落到成员行。Edge `/v1/groups/:id/invite-links` + `/v1/group-invites/:token`。RLS 不放宽。
  - **iOS 🟡 核心已编译验证**(2026-06-01,`4e5a58a7`,BUILD SUCCEEDED)：GroupInviteAPI client + `GroupShareLink`(/g/ token codec)+ GroupJoinView 改 token resolve/redeem(扫码 → 预览群信息 +「由 X 邀请」→ 加入,记 invited_by)+ GroupQRCard 改签发 per-inviter 群邀请链接 + QR(任何成员可签发)。**残留**:① /g/ universal-link 的 MessageTabView/TabRoot presenter 接线(扫码路径已通,深链点击未接);② simulator 视觉验证(结构同已端到端验证的 D1,低风险);③ 旧 `group_join_handles` 共享码 iOS 已不用作主分享,可后续清。

## D3 · 头像 / 昵称可见性 = 只走两条受限路径,不全局公开
- **日期**: 2026-06-01
- **决策**: 头像和昵称**不全局公开**。只有两个合法暴露场景,各自从不同来源拿对方信息+凭证:
  1. **加好友时** —— 需要看到对方头像+昵称(走 handle 查询路径)。
  2. **群聊里** —— 能看到非好友群成员的头像+昵称(走群成员路径)。
  - 除这两处外没有需要公开的地方,**就不公开**。
- **背景**: 现状 `attachments` RLS 让头像行(含 `r2_key`、文件名)对所有登录用户可读,和 Worker 下载口径不一致、可能泄露 r2_key。决策明确"头像不是全局公开资源",据此收紧 RLS 到这两条路径 + 闭合 metadata 泄露。
- **现状核实**（2026-06-01 亲验 + 部分落地）:
  - **Part 1（关 metadata 泄露）— ✅ 已落地**：迁移 `20260601080625` 删掉 `attachments_self_read` 的全局头像分支(原对任意 authenticated 暴露 r2_key,无合法消费者)。已 push live。
  - **Part 2（给两条场景服务头像字节）— ✅ 已落地**（2026-06-01,`53de193f`）：用户拍板"加好友和群成员都要能看头像"。设计选定 **id-as-capability**:`/v1/uploads/:id`(`apps/edge/src/routes/upload.ts`)加头像例外 —— 任意登录用户凭(不可枚举、只能从合法处拿到的)头像 attachment id 可取**头像图片字节**。同时覆盖加好友(lookup 给的 id)和群成员(成员列表给的 id)两场景。**只服务图片字节**;metadata(r2_key 等)仍由 part1 RLS 挡住;聊天附件仍消息引用 gated。这是标准头像模型。
    - 小遗留:`users.avatar_path` 上的查找未建索引(头像有 1yr immutable 缓存,每客户端每头像查一次,pre-launch 量级可接受);未来量大可加索引。

## D4 · Crew captain 来源 = 4 种(spec 补齐)
- **日期**: 2026-06-01
- **决策**: spec §6.3.1 从 3 种改为 **4 种**,补上代码已实装的 `spawned_by_captain`(父 crew 的 captain 主动创建子 crew → 子 crew captain 默认 = 父 captain)。
- **背景**: spec 写 3 种,迁移 `20260527090000` + `create_child_crew_inheriting_responsibility_*` RPC 已实装第 4 种,spec 没同步(tech-debt 🟡 已记)。决策是对齐到代码(4 种),不是删代码。
- **现状核实**: ✅ 代码已是 4 种;spec §6.3.1 已补(2026-06-01,feat/invite-model)。**已落地。**

---

## 反向核实记录(确认"没丢"的设计,留作证据)

### R1 · 责任主体快照 —— ✅ 已确认实装,未丢失
- **核实日期**: 2026-06-01
- **担心**: 用户记得"计费按责任主体记快照"反复确认过,怀疑设计丢失。
- **核实结论**: **在的。** `usage_events`([20260529124601:104](supabase/migrations/20260529124601_billing_v2_schema.sql:104))和 `ledger_entries` 都有 `owner_user_id` / `owner_subject_id` 列 + `usage_events_owner_exactly_one` CHECK 约束,落账即钉死 owner;`settleUsage(owner: OwnerRef)`([billing-v2.ts:51](apps/edge/src/lib/billing-v2.ts:51))显式传 user/subject 并写入。群语音 RealtimeKit 媒体路径正确解析 `responsible_subject_id` 传入。
- **真实剩余小项(非丢失)**: 语音 turn 的模型 token 一笔仍走 v1 audit→router 钩子、settle 时才解析 subject(而非 turn 当时盖章),最终 usage_event 仍被钉 owner,只是解析时机与其他路径不一致 —— 小一致性清理,记 tech-debt 即可,不是快照缺口。
- **教训**: 这条最初是 agent 读 voice v1 audit 老路径的误报被直接上报导致的虚惊。**agent 发现必须先验证再当结论用。**
