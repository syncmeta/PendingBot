# Crew 成员资格 × 账号「计费电池」模型 设计

日期：2026-06-19
分支：`feat/crew-account-battery`
状态：设计定稿，待评审

> **定位 = spec v2 §4 的增量续篇。**
> 本文不重写身份/权限地基，只写在 [`2026-05-28-pendingbot-pendingcrew-product-design-v2.md`](./2026-05-28-pendingbot-pendingcrew-product-design-v2.md) §4（身份与 Subject 模型）之上、为「bot / 人类账号作为远端成员参与本地 crew」这件事补的增量。上游链：
> - **接合 v2**（[`2026-06-10-pendingcrew-pendingbot-integration-v2.md`](./2026-06-10-pendingcrew-pendingbot-integration-v2.md)）：本地为家、edge 是邮差；bot/人类账号经信箱作为成员加入。
> - **block 3 relay**（[`2026-06-11-pendingcrew-block3-relay-mailbox-design.md`](./2026-06-11-pendingcrew-block3-relay-mailbox-design.md)）：relay 信箱 + `crew_add_member_for_subject` + Mac 同步代理（代码已落，待 E2E，task #297）。
> - **sidebar-by-machine**（[`2026-06-15-pendingcrew-sidebar-by-machine-design.md`](./2026-06-15-pendingcrew-sidebar-by-machine-design.md)）：登出 = 账号不再持有本机，本机 crew 本地照旧在。

---

## 1. 这份 spec 解决什么

接合 v2 让远端 bot / 人类能作为成员加入本地 crew。但「成员资格怎么界定、账号在其中是什么角色、登出之后这些远端成员怎么办」一直没有定清，导致两个具体债：

1. **误把 `bots.responsible_subject_id` 当成员归属判据**——它其实是计费字段（见 §7），拿它界定「谁能进 crew」是错位的。
2. **iOS 看不到 crew 群**——relay crew 会话挤在消息 tab，被 `user_unread_counts!inner` 空会话门挡掉（block 3 的 E2E 病根之一）。

本文给出一个收敛的模型把这些一起收掉：**账号是 crew 的「计费电池」，不是「户口」。**

## 2. 核心模型：账号 = 计费电池，不是户口

**一句话**：本地 crew 永远是 home；登录账号是给它远端能力**供电的电池**——只提供 ① 计费方 ② edge 接入身份；拔电（登出）远端成员休眠/退出，本地 session/captain 照常。

### 不变式（地基）

1. **crew 不搬家**。登录账号叠加远端能力，从不夺走本地 home，从不圈定成员边界。
2. **账号 = 计费 + 接入身份，不是成员边界**。crew 的 `responsible_subject`（= 登录账号）决定从哪个钱包扣、谁是 edge 身份；它**不**决定「谁能当成员」。
3. **群 ≠ crew**。iOS 单开 **crew tab**，数据源 = 「我作为成员的 crew」，绕开消息 tab 的 `!inner` 空会话门。
4. **bot 成员** = 登录用户自己的 bot + 已加联系人的非 private bot。
5. **人类成员** = 登录用户本人 + 好友；群账号登录时再加群成员。
6. **登出 = 拔电**：电池账号登出时弹「保留 / 不保留」，默认保留（休眠）。
7. **两级登出**：电池账号登出 = 整 crew 休眠/退出；单个好友/群成员在自己 iOS 登出 = 他个人退出，不动整个 crew。
8. **外部参与全程可见（透明强制）**：以群身份开 crew 必推送群内；crew 端常驻展示所有外部人类/bot；两者都不可关。

## 3. 既定地基（直接继承，不重写）

以下来自 spec v2 §4 与既有实现，本文**沿用**，仅在此登记以免重复发明：

| 既定 | 出处 |
|---|---|
| 双 subject（`user_account` / `group_account`）+ 群账号轻量化 | spec v2 §4.1 / §4.2 |
| 群权限矩阵（owner / admin / member，默认固定） | spec v2 §4.3 |
| **扫码选 subject 登录**：本人已登录 → PendingCrew 扫码 → 选「代表哪个 subject」→ device grant（含 subject scope） | spec v2 §4.4 |
| **以群身份登录 = owner/admin**（member 不能代表群登录跑本机 agent） | spec v2 §4.3 / §4.4 |
| `responsible_subject` 决定「谁付钱、谁能看、谁能批权限」 | spec v2 §4.1 |
| crew 计费走 `temporary_group_meta.responsible_subject` → 个人/群钱包 | [`usage-gate.ts`](../../../apps/edge/src/billing/usage-gate.ts) `resolveBillingSubjectId` |
| 成员可见性校验（bot：自己的/联系人的；human：好友/同 subject 成员） | [`crew_add_member_for_subject`](../../../supabase/migrations/20260611125617_crew_add_member_for_subject.sql) |
| 登出后本机 crew 本地照旧在 | sidebar-by-machine §（登出 = 账号不再持有本机） |

**关键继承**：不变式 4/5（成员范围）与既有 `crew_add_member_for_subject` 的校验**逐字吻合**——这块**零改动**，本文只是把它确认为最终语义（早先「收紧到账号内部」的想法已废）。

## 4. 增量 I1 — 「账号=计费电池」正名

spec v2 把「谁付钱 / 谁能看 / 谁能批权限 / （被误用的）谁能当成员」都压在 `responsible_subject` 一个词里。本文显式拆开：

- **计费**：crew.`responsible_subject` → 钱包（个人 or 群）。**唯一**由账号决定的事。
- **接入身份**：device grant 的 subject scope = edge 通道身份。
- **成员资格**：由「登录用户能访问哪些 bot/人」决定（不变式 4/5），**与账号身份正交**——好友的 bot、好友本人都能进，账单记电池账号头上。

产出：文档层正名 + 计费链路注释对齐；**无新计费逻辑**（继承现有 usage-gate）。

## 5. 增量 I2 — 成员范围（确认 = 现有校验，零改动）

- **bot 成员**：`bot.creator_id == 登录 user`（自己的），或 `visibility != 'private'` 且登录 user 已 `user_bot_contacts` 加为联系人。
- **人类成员**：登录 user 本人，或 `user_contacts`（好友），或（群账号登录时）`group_subject_members`（群成员）。

这正是 `crew_add_member_for_subject` 现有分支。**本文不改 RPC**，仅作为不变式登记。计费含义：任何成员产生的远端用量（bot 应答、人类 @bot）都记 crew.`responsible_subject`。

## 6. 增量 I3 — 登出成员生命周期（核心增量）

### 6.1 数据三层（local-first 决定「数据」范围）

| 层 | 在哪 | 角色 |
|---|---|---|
| 本地 crew + 白板 | Mac | **home，登出永不受影响** |
| edge relay 投影（crew 会话 + 消息 + 成员名册） | edge | 可弃的中转信箱 |
| 远端成员名册（加过哪些 bot/人） | **Mac 本地 crew JSON** | 权威，用于重登恢复 |

### 6.2 状态机（电池账号 = L1 登出）

```
接入(绑 remoteConversationId) → 加成员(crew_add_member) → 运行
    │                                                        │
    │                                            电池账号登出 → 弹「保留/不保留」(默认保留)
    │                                                        │
    ├── 保留(休眠) ───→ Mac 停 CrewRelayAgent              │
    │                   edge: crew 标 dormant、成员标 inactive
    │                   本地名册保留
    │                   重登 → 同步重启 + 成员标回 active → 自动恢复成员与历史
    │
    └── 不保留(退出) → 删 edge crew 会话 + messages + 成员名册 + 解绑 remoteConversationId
                       清本地名册
                       本地 crew/白板不动 → 「跟没来过一样」只对远端成立
                       重登 → 从头接入
```

### 6.3 两级登出

- **L1 电池账号登出**（Mac PendingCrew，扫码登出 / 换号）：整 crew 的远端接入休眠/退出，走 6.2 弹选。
- **L2 单成员登出**（iOS PendingBot 上的好友/群成员）：他个人从该 crew 退出 = `temporary_group_members` 标 inactive + `conversation_participants` 移除 + roster 吊销（复用 [edge-read-offload](../plans/2026-06-07-edge-read-offload.md) 的 webhook evict）；**不触发整个 crew 的休眠/退出**。重登后：若电池账号侧名册仍含他（保留态），下次 L1 恢复会把他重新加回候选；他自己重新登录 PendingBot 即可再次参与。

### 6.4 实现抓手

- edge `temporary_group_meta.status` 新增状态值 `dormant`（休眠）；成员休眠用 `temporary_group_members.status = 'inactive'`（列已存在）。
- 新端点：`POST /v1/crews/:id/detach { mode: 'hibernate' | 'purge' }`（device grant + owner/admin for 群）。
- Mac：登出流插入弹窗 → 调 detach；`LocalCrewStore` 已有 `remoteConversationId`/名册，加 `detachedState`。

## 7. 增量 I4 — DROP 死列 `bots.responsible_subject_id`

**证据**（已核）：`resolveBillingSubjectId` 只读 conversation/crew 的 responsible，**从不读 bots 表**；全 edge 无任何处读 `bots.responsible_subject_id`；除回填迁移外零运行时改写。它是「给所有实体加 responsible」那次渐进迁移顺手加在 bot 上、填完 creator 就再没用过的死列。

动作：新迁移 `DROP COLUMN pendingbot.bots.responsible_subject_id` + `types:db` regen + typecheck。计费不受影响（本就不读它）。

> 注：计费的「谁用谁付钱」由 crew/会话的 responsible 承担，bot 不该自带责任主体——本删除是把这个语义钉死。

## 8. 增量 I5 — 透明度（强制可见）

1. **以群身份开 crew → 推送群内**：crew 接入（建 relay 会话）时，若 `responsible_subject` 是群 subject，向该群 subject 的 `group_conversation` 发一条系统消息：「<user> 以本群身份在 <machine> 启用了 crew《<name>》」。不可关。
2. **Mac 端常驻展示外部成员**：改造现有 crew roster（[#239](../../../supabase/migrations/20260611125617_crew_add_member_for_subject.sql)），把**外部人类 + bot** 单独拎成一个明显常驻区（视觉区别于本地 session），让本地操作者一眼看清谁从外面进来。不可关。

理据：远端成员能看到 crew 群聊层投影 → 知情必须双向（群内知道有人以群身份开了 crew；本地知道现在有谁在里面）。这与 local-first「本地干活现场不外泄」的安全边界同源。

## 9. 增量 I6 — iOS crew tab

- **单独 tab**，与「消息」分离。
- **数据源** = 「我作为成员的 crew」：查 `temporary_group_members where user_id = me and status = 'active'` → 对应 crew 会话（我作为人类成员参与的 crew；「我的 bot 在某 crew」的 owner 视角留后续）。**不复用** `ConversationFetch.list()` 的 `user_unread_counts!inner` 路径（那道空会话门正是人类此前看不到群的病根）。
- 新端点：`GET /v1/me/crews`（返回我参与的 crew 摘要 + 成员 + 状态 dormant/active）。
- 本 spec 只定数据源与可见性原则；列表/会话视图布局沿用现有 `CrewChatView`/roster，细节留实现。

## 10. 数据模型改动汇总

**edge / DB（迁移）**：
- `DROP COLUMN bots.responsible_subject_id`（I6）。
- `temporary_group_meta.status`：新增状态值 `dormant`（休眠）。
- 成员休眠复用 `temporary_group_members.status = 'inactive'`（无 schema 改动）。
- 新 RPC/端点：`crew_detach`（hibernate/purge）、`GET /v1/me/crews`、群身份接入推送系统消息（复用 messages 写入）。

**Mac 本地（`LocalCrewStore` JSON）**：
- 远端成员名册（botId/userId + display）已随 block 3 部分存在，补全为「权威恢复源」。
- `detachedState`（active / hibernated）。

**iOS**：crew tab + `GET /v1/me/crews` 消费。

## 11. 边界 case

- **登出时 edge 不可达**：本地先标 detached（local-first），下次上线补同步 detach。
- **退出（purge）时远端成员正在群里**：删 edge crew 会话 → 他们的 crew tab 里该 crew 消失（「跟没来过一样」对所有远端成立）。
- **好友 @bot 烧电池账号的钱**：是 feature（你请客），但成本对电池账号可见；电池钱包余额烧光 → usage-gate 拦，bot 停答（现成）。
- **同一群账号多台 Mac 各开 crew**：每个 crew 独立绑定，并发扣群钱包由 WalletDO 串行化（现成）。
- **member 试图以群身份接入**：edge 按 spec v2 §4.3 拒（owner/admin 门），device grant 颁发阶段就挡住。

## 12. 非目标（YAGNI）

- **不引入** bot `owner_subject` / 「群拥有 bot」所有权模型——电池模型下不需要（这次明确否决）。
- **不动** BYOK 未登录路径——已删（task #364）。
- **不重做** 计费链路——继承现有 usage-gate / WalletDO。
- **不做** crew tab 的完整视觉设计——本 spec 只定数据源与可见性原则。
- **不收紧** 成员范围到「账号内部」——已废，沿用现有宽松校验。

## 13. 验证策略

- **edge**：vitest 覆盖 `crew_detach`（hibernate 标 inactive / purge 删投影 + 权限矩阵）、`GET /v1/me/crews`（dormant/active 过滤 + 成员渲染）、群身份接入推送系统消息、DROP 列后 typecheck 绿。
- **Mac**：登出弹选 → detach 调用；重登恢复名册（纯逻辑单测）；外部成员常驻区渲染。
- **iOS**：crew tab 数据源不走 `!inner`；被加成员能看到 crew（这是 block 3 #297 一直没验的病根，本 spec 修它）。
- **E2E（真机/真账号，人工拍）**：① 个人账号接入 + 邀好友 → 好友 iOS crew tab 见群 → 好友 @bot 得到应答 + 账单记电池账号；② 群身份登录推送群内可见；③ 登出弹选「保留」→ 重登成员与历史恢复；选「不保留」→ 远端清空、本地白板无损。
