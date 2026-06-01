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
- **现状核实**: ❌ 未实现(待返工)。#121-127 代码是旧 slug 模型,保持 pending。

## D2 · 群加入码 = 每人一码、各自关联到本人(邀请者)
- **日期**: 2026-06-01
- **决策**: 群加入码也走"关联邀请者"模型,但形态是**每个群成员看到的是关联到自己的那份码**——使用时当"群的码"用(扫了就进这个群),但每个人的码不同,从而留痕"谁是被谁拉进来的"。
- **背景**: 现状群 handle 是单一共享码,任何人拿到就能请求加入,不记是谁分享的,与 D1 的 bot 邀请哲学不一致。统一成同一套"邀请关联到人"。
- **现状核实**: 🔍 当前群加入流程(`group_join_request_create`,edge userClient)需核实,再定 delta。

## D3 · 头像 / 昵称可见性 = 只走两条受限路径,不全局公开
- **日期**: 2026-06-01
- **决策**: 头像和昵称**不全局公开**。只有两个合法暴露场景,各自从不同来源拿对方信息+凭证:
  1. **加好友时** —— 需要看到对方头像+昵称(走 handle 查询路径)。
  2. **群聊里** —— 能看到非好友群成员的头像+昵称(走群成员路径)。
  - 除这两处外没有需要公开的地方,**就不公开**。
- **背景**: 现状 `attachments` RLS 让头像行(含 `r2_key`、文件名)对所有登录用户可读,和 Worker 下载口径不一致、可能泄露 r2_key。决策明确"头像不是全局公开资源",据此收紧 RLS 到这两条路径 + 闭合 metadata 泄露。
- **现状核实**（2026-06-01 亲验 + 部分落地）:
  - **Part 1（关 metadata 泄露）— ✅ 已落地**：迁移 `20260601080625` 删掉 `attachments_self_read` 的全局头像分支(原对任意 authenticated 暴露 r2_key,无合法消费者)。已 push live。
  - **Part 2（给两条场景服务头像字节）— ❌ 未做 + 需设计决策**：亲验发现 **跨用户头像字节本来就下不到** —— Worker `/v1/uploads/:id`(`apps/edge/src/routes/upload.ts:347`)用 serviceClient 自鉴权,只放行上传者 / 有未删消息引用的参与者,**没有头像例外**;0063 当年加的 RLS 头像例外在 upload.ts 改用 serviceClient 后已失效。所以现在别人上传的头像一律回退种子占位。要实现 D3 的"加好友 + 群成员两条场景能看头像",得在 Worker 加一条**受 scope 的头像服务路径**(群成员:caller 与头像主人同会话即可;加好友:lookup 流程带凭证)。**两条场景的服务机制 = 待决策**,我没有臆造。
    - 关联 tech-debt:这条升级了原"附件 RLS 与 Worker 口径不一致"条目 —— 现确认是"metadata 过宽(已修)+ 字节跨用户不可达(待设计)"两面。

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
