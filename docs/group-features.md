# 群 —— 功能全景

> 写作口径：**只写代码里核得到的东西**。每一节的结论都能在文末「怎么复核」列出的
> 文件 / 迁移 / 命令上当场验。读数时刻 **2026-08-24**，对象 = `refs/heads/main`
> （`f8a52ede`；群相关文件与本次读取的工作树逐字节一致，已 `git diff` 核过）。
>
> 系统级视角（DO 清单、RLS、计费主体、提示词装配）在 `docs/architecture.md`，
> 本文不重复，只在需要时指过去。

---

## 0. 先分清三个都叫"群"的东西

代码里 `group` 这个词落在三处，含义完全不同，混了就会读错：

| 叫法 | 载体 | 是什么 | 本文 |
|---|---|---|---|
| **群聊** | `conversations.conversation_type = 'group'` + `conversation_group_meta` | 产品意义上的群：多人 + 多机器人同处一个会话 | §1–§6 |
| **群账号**（群钱包主体） | `subjects.kind = 'group_account'` + `group_pools` / `group_pledges` | 计费与归属主体，一个共享钱包。与群聊**一对一挂钩但不是同一张表** | §7 |
| **临时群**（crew） | `conversations.conversation_type = 'temporary_group'` + `temporary_group_meta` | PendingCrew 的多 Agent 编排群，复用会话基础设施但走另一套路由与权限 | §9（仅指路） |

下面除 §7、§9 外，「群」一律指**群聊**。

---

## 1. 数据模型

**核心两张表**（其余都挂在它们下面）：

- `conversations`（`conversation_type='group'`）—— 会话本体：标题、消息序号、责任计费主体
  `responsible_subject_id`。
- `conversation_group_meta`（主键 = `conversation_id`，与会话 1:1）—— 群元信息：
  `title` · `join_policy` · `max_members` · `router_model_slug`（本群路由模型覆写）·
  `created_by` · `avatar_url`。

**成员表是多态的**：`conversation_participants` 用
`(participant_type, participant_id)` 同时装人和机器人 —— `participant_type ∈ {'user','bot'}`。
带 `role` · `nickname`（群昵称/群备注名）· `muted` · `invited_by` · 已读游标
（`last_read_message_id` / `last_read_message_seq`）。

> ⚠️ 这一列**没有正式外键**（多态列没法同时指两张表）。后果是 supabase-js
> join 不了，凡是要"成员 + 资料"的地方都得分两次读再在内存里拼
> （`llm/group-router.ts`、`lib/group-mentions.ts` 里都有这段注释）。

**围绕群的其余表**：

| 表 | 用途 |
|---|---|
| `group_join_handles` | 群号 / 群二维码（`handle_type ∈ {number, qr}`，每类每群一条，全局唯一） |
| `group_join_requests` | 扫码/输号发起的入群申请（pending/approved/rejected/expired） |
| `group_member_invitations` | 定向邀请某个人入群（对方在收件箱里同意/拒绝） |
| `group_invite_links` | 每人一条的可复用邀请链接（64-hex token，可吊销） |
| `group_bot_descriptions` | **每群一份**的机器人自我介绍，喂给路由模型 |
| `group_continue_requests` | 「机器人还想继续说」的人类投票 |
| `group_pools` / `group_contributions` / `group_pledges` | 群钱包（§7） |

---

## 2. 建群

`POST /v1/groups` → RPC `open_group_conv`。

- 调用者自动成为 **owner**。
- 请求体：`title?`（≤80）· `memberUserIds`（≤29）· `memberBotIds`（≤29）。
- **人和机器人的入群方式不同**：机器人由 RPC 当场拉进来；人**不是直接拉进来的**，
  边缘层为每个 `memberUserIds` 落一条 `group_member_invitations`，对方同意才算数。
- 建完插一条 `metadata.source='group_system'` 的系统气泡「群聊已创建」。
- 建群那一刻触发器 `_mint_default_group_handles` 自动铸一个 8 位群号 **和** 一个二维码
  handle —— 不需要管理员多做一步（迁移 `0066`）。
- `GET /v1/groups/random-name` 给建群页预填一个随机地名（同 1v1 自动标题用的
  `random_place_name()`）。

**人数上限 30**（`max_members` 默认值 + CHECK，迁移 `0048` 从 100 收到 30）。
关键细节：`_group_member_count` **数的是 `conversation_participants` 全部行 ——
人和机器人共用这一个 30 的额度**，不是各 30。

---

## 3. 入群的五条路径

| 路径 | 入口 | 谁能发起 | 结果 |
|---|---|---|---|
| ① 建群时带上 | `POST /v1/groups` 的 `memberUserIds` | 建群者 | 生成邀请，待对方同意 |
| ② 定向邀请 | `POST /v1/groups/:id/invite-user` | owner / admin | 生成邀请，待对方同意 |
| ③ 群号 / 扫码 | `POST /v1/groups/join`（传 handle 值） | 任何登录用户 | 按 `join_policy` 分流 |
| ④ 邀请链接 | `POST /v1/group-invites/:token/redeem` | 任何持链接者 | 直接入群，记 `invited_by` |
| ⑤ 拉机器人 | `POST /v1/groups/:id/invite-bot` | owner / admin | 机器人立即入群 |

**收件箱侧**：`GET /v1/groups/invitations` 列出待我处理的邀请，
`POST /v1/groups/invitations/:inviteId/decide` 同意/拒绝。响应里带一段**常量**计费提示
（"加入后，机器人 Token 由群钱包统一结算"）—— 这段以前是落库的快照，
旧分摊模型退役后改成边缘合成，iOS 解码形状没变。

**入群策略**（`conversation_group_meta.join_policy`，owner/admin 可改）：

- `scan_open` —— 扫码即进
- `approval` —— 落一条 `group_join_requests`，owner/admin 在
  `GET /v1/groups/:id/join-requests` 里看到并 `POST /:id/join-decide`
- `closed` —— 不允许新成员

`POST /v1/groups/join` 与好友查号共用同一个限流桶（`HANDLE_LOOKUP_RL`）—— 群号是可枚举资源，
不限流就能被扫。

**邀请链接**（决策见 `docs/decisions.md` D2）：对齐 bot 邀请码模型 ——
**每个成员各自铸自己的链接**，可复用、可吊销、带过期；入群时把 `invited_by`
记在成员行上，所以"谁把谁拉进来的"是可追溯的。RLS 对 `group_invite_links` 全关，
一切走 SECURITY DEFINER RPC。

**拉机器人有三道门**（RPC `group_invite_bot`）：
机器人必须 `is_active` → `visibility='private'` 的机器人**一律不能进群** →
`public_invite` 的机器人，调用者必须是创建者本人或已持有该 bot 的 `bot_invites` 记录。

拉进来之后边缘**后台**调一次 LLM，为这只机器人写一份**本群专属**的自我介绍
（`generateInitialBotDescription` → `group_bot_descriptions`）。这份介绍不是给人看的，
是给 §5 的路由模型看的 —— 它决定"这条消息该谁答"。接口立刻返回
`descriptionPending: true`，不阻塞邀请 UI。

---

## 4. 角色与权限

角色存在成员行的 `role` 列上：**owner / admin / member**。

> `observer` 这个值在若干 RPC 的允许列表里出现过，但 `group_set_member_role`
> 只接受 `admin` / `member` —— **没有任何代码路径能把人设成 observer**，
> 它是遗留的死角色。

权限矩阵（服务端 `_assert_group_role` 强制，边缘只做请求整形，不复制判定逻辑）：

| 操作 | owner | admin | member |
|---|:--:|:--:|:--:|
| 改群名 / 改入群策略 / 改群号·二维码 | ✅ | ✅ | — |
| 邀人 / 拉机器人 / 踢人 / 踢机器人 | ✅ | ✅ | — |
| 审批入群申请 | ✅ | ✅ | — |
| 设机器人群昵称 / 群内介绍 | ✅ | ✅ | — |
| 升降管理员 | ✅ | — | — |
| 改自己的群昵称 / 免打扰 | ✅ | ✅ | ✅ |
| 对「机器人继续说」投票 | ✅ | ✅ | ✅ |
| 铸自己的邀请链接 | ✅ | ✅ | ✅ |
| 退群 | ❌ | ✅ | ✅ |

（「设机器人群昵称 / 群内介绍」这两个 RPC 还有一条**服务端旁路**：`auth.uid()` 为空时
跳过角色校验 —— 那是 worker 以 service_role 身份替机器人自己写介绍的通道，不是给客户端的。）

两条容易漏的规则：

- **群主不能退群**（v1 明确不做转让，RPC 直接拒）。
- **管理员不能被直接踢** —— owner 必须先降级再踢。这条 2026-07-05 之前只在 iOS
  的 `canRemove()` 预检里挡着，服务端是敞的（任何 owner/admin 直调 RPC 就能绕过）；
  迁移 `20260705024819` 把它补进了 RPC。这是一个**真安全洞的修复记录**，不是新功能。

---

## 5. 群里的机器人怎么被叫醒 —— 全项目最独特的一块

1v1 里"谁说话"没有歧义；群里有 N 只机器人，让它们全答就是灾难。这套机制解决的就是这个。

### 5.1 两条唤醒通道

一条人类消息进来（`POST /v1/messages` 的 group 分支），先做 @提及解析，
然后把信号 fire-and-forget 打给 **`GroupRouterDO`（每群一个实例）**：

- **@提及命中** → 绕过一切节流，**立刻**派发被点名的机器人。
  提及只认**机器人**：`@某个人`纯粹是渲染，服务端不触发任何东西。
  匹配顺序是 **群内昵称优先，其次 `bots.display_name`**，大小写不敏感，
  正则 `@([\p{L}\p{N}_-]{1,32})`（所以 `@SciBot,` 能匹配 `SciBot`）。
- **没提及** → 交给 DO 的节流器决定什么时候跑路由。

### 5.2 节流：DO 里的滑窗 + 防抖

`GroupRouterDO` 只存三个极小的值（近 60s 消息时间戳数组、待触发的 alarm 时刻、
上次路由的水位），全部加起来 <1KB：

- 60 秒滑窗内 **<10 条**（清闲）→ 立刻跑路由。
- **≥10 条/分**（热闹）→ 进防抖模式，"最后一条消息之后再静 8 秒"才跑，
  上限 5 分钟（兜住 DO 账单）。
- 路由本体跑在 `alarm()` 里 —— **天然串行**，同一个群永远不会有两次路由打架。

> 为什么不用 Cloudflare Queues：队列是 1 分钟批次粒度、且没有按 key 的串行保证，
> 同群事件还得自己去重。DO state + alarm 正好是这个形状。（源码注释原话。）

### 5.3 路由：一次小模型分类

`runGroupRouter` 把「群成员机器人清单 + 各自的群内介绍 + 最近消息」拼成一个
**2000 token 预算**的提示词，让一个便宜的小模型返回 `{ wake_bots: [...] }`。

两个刻意的设计：

- **不用 function-calling 把成员注册成工具** —— 100 人的群就是 100 份工具 schema，
  提示词直接爆掉；而且小模型做"从列表里挑"远比做并行工具调用稳。
- 模型选择两级：本群覆写 `conversation_group_meta.router_model_slug` >
  后台可配的 `groupRouter` 模型角色。

返回的是**有序**列表：最相关的排第一，因为第一个说话的会塑造整个回合。

### 5.4 派发：串行 + 两道闸

`dispatchGroupTurn` 在真正跑机器人之前有两道闸：

**闸一 · 余额**。先 `gateConversation` 查群的责任主体还有没有钱（§7）。
没钱就**不发起**回合 —— 否则跑完才事后扣，会把群池扣穿。读失败时 fail-open。

**闸二 · 防机器人自嗨（continue-vote）**。如果最近 30 秒里**有消息、但一条人话都没有**，
说明机器人们正在互相接话 —— 这时不派发，改为：

1. 插一条 `role='log'`、`log_kind='continue_request'` 的系统气泡；
2. 落一条 `group_continue_requests`；
3. 返回。

人类在群里看到「机器人还有话想说，是否让它继续？」，任一成员点 ✅ / ❌
（`POST /v1/groups/:id/continue-decision`）。同意会经 DO 的 `/resume` 通道回到派发器，
并以 `reason='continue_resume'` **跳过这道闸**（不然刚投完票又被拦一次）。
30 秒窗口内**没有任何消息**不算触发条件 —— 那只是群安静，不是自嗨。

**多只机器人被唤醒时是串行跑的**，一只跑完下一只才开始，这样后说话的能看到前面说了什么。
每个回合完成即经 realtime hub 推给 iOS。

### 5.5 已知缺口（这一节的诚实披露）

- **群里机器人的回复不发推送**。人类消息会推给其他成员
  （`messages.ts` 的 group 分支里 `notifyConversationUsers`），
  但机器人回复是从 DO 派发的，那条路径上没有接推送 —— 源码注释自己标着 "not pushed here yet"。
- **群会话从来没写进过 Honcho 记忆**。`maybeRefreshMemory` 全仓只有一处调用点
  （`routes/messages.ts:405`），而群分支在此之前就 `return` 了。
  设计意图是"群里不许把 1v1 私聊内容抖出来"，效果确实达到了，
  但达成方式是**那里本来就是空的**，而不是"过滤住了"。同时 `query_user_memory`
  仍在群里发给模型，基本空转。

---

## 6. 群语音

挂在 `/v1/groups/:id/voice/*`，10 个端点。控制面在
`RoomVoiceDO`，**音频不在 DO 里** —— 媒体走 `RoomMediaContainerDO`
（Bun 容器，`apps/voice-container`，`max_instances: 3`），底座是
**Cloudflare RealtimeKit** 的 meeting（TTL 2 小时）。

产品上最要紧的一条规则：**`/bootstrap` 之后房间里只有发起人**。
机器人不会被自动拉进来、真人也不会被自动打电话 —— 必须在通话界面里
点「叫机器人来」（`/add-bot`）或「叫真人来」（`/ring`，走 VoIP 推送）。

| 端点 | 作用 |
|---|---|
| `/voice/bootstrap` | 建/复用 meeting，铸调用者的 WebRTC 参与者令牌 |
| `/voice/add-bot` · `/voice/ring` · `/voice/cancel-invite` | 拉机器人 / 呼真人 / 撤回邀请 |
| `/voice/roster` | 重新同步当前名单 |
| `/voice/kick` · `/voice/designate-admin` · `/voice/end` | 特权操作 |
| `/voice/leave` · `/voice/heartbeat` | 自己离开 / 保活（没心跳视为已走） |

机器人的人格是**服务端组装**的（`buildSystemPrompt` + 记忆），
**从不下发到客户端**。谁能踢人、谁能散会由 `RoomVoiceDO` 独家裁定
（它持有发起人 / 群管理员 / 通话管理员三个集合），边缘只转发调用者身份。

---

## 7. 群钱包

群的钱不是"每人各付各的"，是**一个共享池**。主体是 `subjects.kind='group_account'`，
与群会话通过 `conversations.responsible_subject_id` 挂钩
（`ensure_group_subject_for_conversation` 负责建立）。

**余额的事实源是 Polar**（群 = 一个 Polar customer），`WalletDO` 是边缘缓存，
`group_pools` 是公平性镜像。

### 7.1 两种出钱方式

- **实缴（contribution）** —— 真把 PNC 转进群池。每笔注资快照当时的 `share_index`。
- **认缴（pledge）** —— 只承诺一个额度，钱还在自己口袋里；群消费时按
  `min(承诺额, 个人当前余额)` 从个人钱包直扣。

群的可用额度 `S = 群池余额 + Σ各成员认缴份额`，`gateConversation` 用的就是这个 `S`。

### 7.2 share-index：为什么早注资的人吃亏得多

用的是质押池（DeFi）那套数学，避免每次消费都去 update 每一行注资：

```
share_now = 注资额 × (当前 share_index / 注资时 share_index)
```

群花钱时按比例缩 `share_index`，所有人的"我那份"自然一起缩水，一行不用改。
早注资的人 join 时 index 高 → 当前比值小 → 历史消耗吃得多。这是**有意的公平性设计**：
你在群里待得久、蹭得多，你那份就应该被消耗得多。退款一律 `floor`，
零头留在群里，保证永不超退。

### 7.3 端点（`/v1/group-subjects/*`，13 条）

建群账号 · 列成员 · 读钱包 · 加/移成员 · 升/降管理员 · 转让 ·
**注资**（`/topup`，全员开放）· **部分取出**（`/withdraw`，≤当前 `share_now`，留在群里）·
**认缴**（`/pledge`）· **退群结算**（`/leave`）· **解散**（`/dissolve`）。

> ⚠️ 文件顶部的注释还写着 **"No withdrawal endpoint"**，但 `/withdraw` 就在同一个文件的
> 第 563 行 —— 注释已过期。需要澄清的是 `/withdraw` 是**退回个人 PNC 余额**，
> 不是提现到银行卡；"不做提现"这条产品红线仍然成立，过期的只是那句注释。
> （合规理由：规避金融服务性质。）

还有一条链式规则：用户被上游（Apple / Polar）退款时，
`clawbackFromGroups` 会先从他在各群的现有份额里冲减，冲减的钱**留在群里不返还给他** ——
防止"充值 → 注资进群 → 申请退款 → 群里的钱白拿"。

### 7.4 已退役的旧模型（别被残留误导）

2026-06-11（迁移 `20260611013529`）**物理删除**了按会话逐条分摊的旧计费：
`group_member_billing` · `group_billing_config` · `group_billing_custom_shares` 全没了。

但 DB 里还留着两样**没有任何代码引用**的残骸：
`group_split_mode` 枚举（custom/per_head/per_message/per_token/hybrid）和
`audit_log_splits` 表。读旧迁移或旧设计文档时**不要**把它们当成还活着的功能。

---

## 8. 客户端表面（iOS / iPadOS / macOS，一套 SwiftUI 代码）

| 文件 | 承担 |
|---|---|
| `Features/Group/GroupSettingsView.swift`（1076 行） | 群设置主界面：成员列表、角色操作、群名、入群策略、群号/二维码、免打扰、退群 |
| `Features/Group/GroupJoinView.swift` | 扫码/输号入群 |
| `Features/Group/JoinRequestsInboxView.swift` | 入群申请收件箱 |
| `Features/Group/GroupQRCard.swift` | 群二维码名片 |
| `Features/Group/GroupWalletView.swift` + `GroupWalletShared.swift` | 群钱包：注资 / 认缴 / 取出 / 份额展示 |
| `Features/Message/ConversationView+Group.swift` | 群气泡的发送者头衔、**@提及输入器**、继续投票条 |
| `Features/Call/GroupCallView.swift` + `GroupCallSession.swift`（1683 行） | 群语音通话界面与会话管理 |
| `Components/GroupAvatar.swift` | 群头像 |
| `Networking/GroupInviteAPI` · `GroupSubjectService` · `GroupWalletService` | 网络层 |

两个值得知道的实现选择：

- **群成员列表不走边缘接口**，iOS 直接读 Supabase（`conversation_participants` /
  `conversation_group_meta` / `group_join_handles`），靠 RLS 兜住权限；
  先用本地缓存立刻上屏，再用网络结果覆盖。所以**没有** `GET /v1/groups/:id/members` 这个端点。
- **群头像是算出来的，不是存的**：`GroupAvatar` 按群 id 确定性地挑 3 个 emoji 摆成三角
  （区别于 1v1 的单 emoji `BotAvatar`），同一个群每次启动长得一样。
  `conversation_group_meta.avatar_url` 这一列**建了但全仓没有任何读写** —— 死列。

---

## 9. 临时群（crew）—— 只说边界

`conversation_type ∈ {'temporary_group','crew'}` 是 **PendingCrew** 的多 Agent 编排群，
元信息在 `temporary_group_meta`（含 `captain_bot_id` · `working_directory` ·
`parent_temporary_group_id` 父子链），成员在 `temporary_group_members`，
可见性靠 RLS 函数 `can_view_temporary_group`。

它**复用**会话/消息/实时/推送这套底座，但：
不走 `GroupRouterDO`、不走 `conversation_group_meta`、不走本文 §3–§5 的任何一条规则，
计费主体读的是 `temporary_group_meta.responsible_subject_id` 而不是 `conversations` 上的那一列。

PendingCrew 已于 2026-08-17 拆为独立仓库；本仓库只留下它在服务端的这一半。
要写 crew 的文档请另起一篇，别并进本文。

---

## 10. 端点清单（49 条）

| 文件 | 挂载点 | 条数 |
|---|---|:--:|
| `routes/groups.ts` | `/v1/groups` | 21 |
| `routes/group-subjects.ts` | `/v1/group-subjects` | 13 |
| `routes/group-voice.ts` | `/v1/groups/:id/voice` | 10 |
| `routes/group-invites.ts` | `/v1/groups/:id/invite-links` + `/v1/group-invites` | 5 |

注意 `/v1/groups` 这个前缀上**挂了三个不同文件**（groups / group-invites / group-voice），
读 `index.ts` 时别以为只有一处。

架构上有一条贯穿全部的约定：**边缘只负责请求整形、JSON、把 Postgres 异常翻成 HTTP 错误；
角色判定和不变量全在 SECURITY DEFINER 的 `group_*` RPC 里**。
不要在路由层重复写权限判断 —— 那正是 §4 那个安全洞的成因。

---

## 11. 成熟度：这块到底能不能用

按 `docs/fact-sheet.md` 的四档口径，群整体落在 **②「代码完整、有测试覆盖，但未做过端到端真机验证」**。

具体到本文各节：

| 能力 | 状态 |
|---|---|
| 建群 / 入群五路 / 角色权限 | 代码完整 + RPC 侧规则齐全，未真机端到端验 |
| 路由唤醒 + @提及 + 继续投票 | 代码完整，未真机端到端验 |
| 群语音 | 代码完整，**依赖容器**，本地开发需要 Docker |
| 群钱包 | 代码完整 + 有单测（`group-wallet.test.ts` / `share-index.test.ts`），未真机端到端验 |
| 群里机器人回复的推送 | **未接** |
| 群会话的 Honcho 记忆 | **从未写入过**（见 §5.5） |
| 群头像自定义 | **未做**（`avatar_url` 是死列） |
| 按会话分摊计费 | **已退役**，DB 残骸勿用 |

---

## 12. 怎么复核本文

```bash
# 端点条数（本文 §10）
for f in groups group-invites group-subjects group-voice; do
  printf '%s: ' "$f"
  grep -cE "^[a-zA-Z]+\.(get|post|patch|delete|put)\(" apps/edge/src/routes/$f.ts
done

# 人数上限 30、且人和机器人共用额度
grep -n "max_members" supabase/migrations/0048_group_member_cap_30.sql
sed -n '63,75p' supabase/migrations/0045_group_chat_rpcs.sql

# 权限矩阵（_assert_group_role 的调用点）
grep -n "_assert_group_role" supabase/migrations/0045_group_chat_rpcs.sql
sed -n '1,25p' supabase/migrations/20260705024819_group_remove_member_admin_guard.sql

# 路由节流的三个常量
grep -n "WINDOW_MS\|BUSY_THRESHOLD\|DEBOUNCE_MS\|MAX_ALARM_TTL_MS" \
  apps/edge/src/durable-objects/group-router.ts

# 继续投票的 30 秒窗口
grep -n "CONTINUE_VOTE_WINDOW_MS" apps/edge/src/lib/group-dispatch.ts

# 旧分摊模型已死（两条都应无输出）
grep -rn "split_mode" apps/edge/src apps/pendingbot/Sources | grep -v db/schema.ts
grep -rn "audit_log_splits" apps/edge/src | grep -v db/schema.ts

# 群头像 avatar_url 是死列（应无输出）
grep -rn "avatar_url" apps/edge/src apps/pendingbot/Sources | grep -v db/schema.ts | grep -i group

# 群会话不进 Honcho（唯一调用点在 messages.ts:405，群分支在此之前 return）
grep -rn "maybeRefreshMemory" apps/edge/src | grep -v '\.test\.'
sed -n '284,340p' apps/edge/src/routes/messages.ts
```

## 相关文档

- `docs/architecture.md` —— 系统级：DO 清单、RLS 三函数、计费主体解析、提示词装配
- `docs/decisions.md` —— D2（每人一条邀请链接）等决策原文
- `docs/fact-sheet.md` —— 对外可公开的能力边界四档口径
- `docs/tech-debt.md` —— 结构性风险登记册
