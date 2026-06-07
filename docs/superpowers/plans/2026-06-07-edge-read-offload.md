# T2 — Edge Read-Offload(Supabase 单区延迟 → CF 边缘读投影)

> Status: **设计稿(未动代码)**。来源是 2026-06-07 一次架构梳理 session。前置事实已对照实际代码 + CF 官方文档核实。
>
> 一句话:Supabase 单点部署在法兰克福,US/Asia 用户每次首屏吃 ~150–250ms 跨洋 RTT。本 spec 把**热读路径**从"客户端直连法兰克福"改成"CF 边缘投影",Supabase 退为最终一致真源 / 事件源 / 重建源。

## 1. Why this exists

Supabase 单 region(`eu-central-1`,法兰克福)。痛点高度集中在**冷启动读**:客户端有一批 `.from()` 直连 Supabase(绕过 worker),US/Asia 每次都吃跨洋 RTT。最频繁的两个——**会话列表 + 未读**(每次前台)、**消息尾**(每次开会话)——正是直连。

已经搬上 CF 的别重做:realtime(`REALTIME_HUB` DO 已替代 Supabase Realtime)、余额门禁(`WALLET` DO)、群路由(`GROUP_ROUTER` DO)、写入(`waitUntil` 异步)、计费审计(Queue)、附件 blob(R2)、persona/订阅 skills 热读(`persona-cache.ts` KV)、prompts(Langfuse + `PROMPTS_KV`)。

**目标不是搬空 Supabase,是把它移出同步热路径。** 角色从"前线、近、同步"→"SOT + 写入终点 + 身份源 + 喂投影的事件源 + 投影的重建源"。重要性不降,只是不再卡延迟。**写仍然回法兰克福**,即时感来自乐观 UI + worker 快速 ACK,不是 Supabase 变近。

## 2. 核心模型:CQRS 读投影

```
  写  ── client ──▶ worker ──▶ Supabase(SOT, RLS, 触发器)
                                   │
                                   │ pg_net 触发器(已有)
                                   ▼
                       POST /v1/realtime-internal/notify
                                   │
                  ┌────────────────┴───────────────┐
                  ▼                                 ▼
        ③ REALTIME_HUB DO                  ③ 读投影 DO(本 spec 新增)
          (实时增量扇出,已完成)           per-conv 消息尾 / per-user 列表+未读
                  │                                 │
                  ▼                                 ▼
  读  ── client ◀── ④ 本地缓存 ◀── ③ 投影(边缘) ◀── ② worker→Supabase(冷/重建兜底, RLS)
```

写 → Supabase(真源);读 → CF 边缘投影。投影是**可重建的派生,永不权威**。同一条 webhook 既扇出实时增量(已有),又顺手物化进读投影(新增)。

## 3. 四桶分类(所有数据存取操作)

记号:**① 客户端直连 Supabase | ② Worker→Supabase | ③ D1/KV/DO | ④ 客户端本地缓存(GRDB)**

### 7 条判定规则(套任意操作)

1. **写(任何改真源)** → **②**(SOT);发送者本地 **④** 乐观回显。永不①直连写,永不③当权威。
2. **身份(登录/session/刷新)** → **①** 直连 GoTrue。唯一合理的 client-direct。
3. **热读(会话列表/消息尾/未读)** → **④→③→②**(本地→CF 投影→冷/重建兜底带 RLS)。
4. **参考/配置(全局只读、低频变)** → **③ KV**(②webhook 喂 / 写时 purge)。
5. **冷/关系/枚举/罕见读** → **②**(RLS 白嫖)。枚举类必须②+限流,绝不①。
6. **实时增量** → **③ DO**(已完成)。
7. **真源/事件源/重建源永远是 Supabase** —— 在每条规则背后兜底,不被取代。

### 全量矩阵(粗体=主路径,括号=兜底/SOT)

| 域 / 操作 | 频率 | 当前 | 目标 | 状态 |
|---|---|---|---|---|
| **身份** 登录/注册/刷新/session/登出 | 低 | ① | **①** GoTrue | 不动 |
| 注销账号 request/cancel | 罕见 | ① `.rpc` | **②** | 🟢 收口(SOT 不该 client rpc) |
| **会话列表 + 未读快照** | 每次前台 | ① 直连 | **④→③ user DO→②** | 🔴 待做 |
| 标记已读 | 中 | ② read-ack | **②**→③扇出 | ✅ |
| 未读增量 | 常驻 | ③ | **③** user hub | ✅ |
| **消息尾(开/切会话)** | 每次开会话 | ① 直连 | **④→③ conv DO→②** | 🔴 待做 |
| 深翻历史 | 罕见 | ① | **②**(或暂留①+RLS,见 §11) | prefetch 藏延迟 |
| 发消息 | 核心 | ② waitUntil | **②(SOT)+④乐观** | ✅ |
| 撤回/编辑 | 中 | ② recall | **②**→③投影(带 tombstone)+realtime | 投影要带删改 |
| 消息实时增量 | 常驻 | ③ | **③** REALTIME_HUB | ✅ |
| 附件元数据 | 中 | ① attachments | **②** 或随消息投影带下 | blob 在 R2 ✅ |
| **参考** /models、pricing、i18n、place_names、task_routing | 中 | ②(部分KV) | **③ KV** | 部分 |
| prompts / 系统 skill 提示词(bot-social-graph 等) | 每轮 | ③ KV+Langfuse | **③** | ✅(main) |
| bots 目录(公共) | 中 | ① `.from×11` | **③ KV**(公共)/②(自有) | 混 |
| 用户自建 skills / skill_subscriptions | 每 bot 轮 | ③ KV(persona-cache) | **③** | ✅(热读已缓存) |
| 好友/联系人列表 | tab 开 | ①+② | **②+④ 本地** | 不上 DO |
| 加好友 / 好友请求 decide | 中 | ② RPC | **②** | ✅ |
| handle/二维码:管理自己 | 低 | ① 自限 | ① 或 ②(无安全风险) | 无害 |
| handle/二维码:按号查别人 | 中 | ② `/friend-requests/lookup` | **②+限流** | ✅ 已网关化 |
| 群元数据/成员/角色读 | 中 | ①+② | **②**;roster→③ conv DO | roster 给授权门用 |
| 群操作(建群/加人/邀请/加入码/decide) | 中 | ② 海量 RPC | **②**(SOT) | ✅ |
| crew announcements/sessions/messages | 中 | ②+③ | **②**+③ realtime | ✅ |
| 余额门禁 | 每次发送/工具 | ③ WALLET DO | **③**(Polar SOT) | ✅ |
| 钱包/账单读 | 中 | ② | **②** | ✅ |
| 账本/审计/对账 | — | ② | **②**(append-only SOT) | 永不③权威 |
| 来信(envelope)feed | tab 开 | ① envelope_runs+③ | **④→②**,增量③ | DO 投影可选 |
| arena leaderboard | 罕见 | ②/① | **②** | 冷 |
| portraits / ai_picks | 罕见 | ② | **②** | 冷 |
| 设备/VoIP token 注册 | 低 | ② devices/register | **②** | ✅ |
| 头像图片 | 每行/每条 | ④ URLCache | **④** 收口+长缓存头 | 🟡 细碎 |

## 4. 聚焦:频繁 × 延迟敏感(真正驱动迁移的)

把上表收敛到"延迟明显影响体验、且频繁"的交集,除已完成的,**真正还要做的只有两件半**:

1. 🔴 **会话列表投影**(per-user DO)
2. 🔴 **消息尾投影**(per-conversation DO)
3. 🟡 **conv DO 顺带存 roster**(授权门用,T2 内自然包含)
4. 🟡 **头像缓存收口**(独立小活)

其余热的(realtime / 未读 / 余额门 / persona·skills)**全已在 CF**。

**被排除的**:频繁但不敏感(联系人列表、settings、billing log、envelope)→ 留 ②/④,不急;敏感但不频繁(语音建连已CF、深翻历史 prefetch 藏、邀请 resolve)→ 留 ②。

## 5. CF 存储选型(KV vs DO vs D1)

核实过的硬限制:DO SQLite **10GB/对象**、软顶 **1000 req/s**、行/值 2MB;D1 每库 **10GB 硬顶不可调**、读副本(Sessions API,session 内顺序一致、bookmark 跨 session)、写只走 primary 区;KV **最终一致 ~60s 传播**、不适合同 key 高频写;DO/KV/R2 全部 **AES-256 at-rest**。

| | 决定轴 | 选 |
|---|---|---|
| 参考/配置 | 读多写少、全局、小 | **KV** |
| 每用户列表+未读 | 同 key 高频写(多群 bump)+ 强一致(红点准)+ 已有 user hub DO | **DO** |
| 每会话消息尾 | 每消息写 + 扇出时本就拿着消息 + 强一致 | **DO**(挂在 `conv:<id>` hub) |

**D1 不进主路径**:仅作"跨洲大群冷读"被实测证伪后的兜底(读副本让分散读者各读近副本,DO 单点给不了)。KV 被消息尾/列表排除(同 key 高频写打架 + 60s 陈旧 → 红点/尾巴会错)。

最省:**复用现有 hub DO 做投影**——对象已为扇出在跑,投影是"加存储不是加对象"。注意 `REALTIME_HUB` 当前是纯内存扇出,要物化需让该 class 变 SQLite-backed(`new_sqlite_classes`)或另起同名寻址的投影 DO。

## 6. 消息尾尺寸:按条数,不按时间

按条数够(手机一屏就那么点;深翻时 prefetch 藏延迟)。拆两个数:

- **`N_read`(首屏返回)= ~200**,对齐现状 `MessagesFetch.latest()`,1:1 平替,UI 不改。按时间在两极都崩(热群爆 payload / 冷群白屏),所以**必须按条数**。
- **`N_keep`(DO 留存)≈ N_read**(不必大):深翻直接回 Supabase(②),`prefetch-on-scroll-intent` 藏延迟。存储免费,但既然深翻走②,留存压到 ~200 即可。
- **硬约束**:单行 2MB。带巨大 tool-trace 的消息要裁字段 / 重字段懒加载 / 截断。
- 写放大:群**无流式输出**(`messages.ts:280` 群分支直接 return,bubbles 插 `status:'done'`,realtime 扇出已定型回合),投影写 ≈ 1/bubble,且 `GROUP_ROUTER` 8s 防抖兜底 → 离 1000/s 顶差好几个数量级,**不用节流**。(待定确数:重连 gap p95 验 N_read 是否够;最忙群峰值 settled 消息/秒。)

## 7. 授权模型(RLS 消失后怎么补)— 最重的一节

**RLS 是数据层强制。数据搬到 CF 后这层自动保护没了,授权必须在 worker 显式重做。** 分两层:

### 7.1 粗:成员/属主门(明显)
- worker 每请求**本地验 JWT** → `userId`(不回法兰克福)。
- 单 owner 会话:`conv:<id>` KV 里 owner_id === userId ? pass : 403。
- 群:`userId ∈ roster`,roster 由 `conversation_participants` webhook 喂进 conv DO(本就是 realtime 推送表)。复用现有 `/realtime-hub/conv/:id` upgrade 时的成员校验。

### 7.2 细:RLS **隐式**过滤必须显式复刻(← 头号泄漏源)
RLS 还静默滤掉很多行/列,投影 builder 必须一条条搬:
- `status='deleted'` 撤回消息(`group-dispatch.ts` 已手动 `.neq('status','deleted')`);
- 迁移 #41 用 RLS 藏的 `voice_call_summary`;
- admin-only 字段、其它 RLS 挡的列。

**忘复刻哪条,哪条静默放行。** 实现时建一张"RLS 可见性规则对照表",逐条搬,测试覆盖。

### 7.3 不变量(纵深)
> 投影永不放宽访问:(a) 成员来源 = RLS 用的同一批 `conversation_participants` 行;(b) 任何 miss/冷启动降级成"带 user JWT 读 Supabase",RLS 自动兜底。

冷路径天然安全(走 RLS),只有热命中走边缘门。**保留 Supabase+RLS 当冷路径 = 免费的第二道防线。** fail-closed:门按 `userId` 查、默认拒,绝不信客户端传来的 conversationId 本身。

### 7.4 残留风险(需决策)
- **吊销延迟**:踢人后 `conversation_participants` DELETE → webhook 到 DO 前有几秒窗口,被踢者还能从边缘读。群踢人罕见、几秒可接受 → webhook 喂;若要即时,让踢人 RPC **同步 evict 那个 DO**。**默认走 webhook,除非产品要求即时。**

### 7.5 CF 安全 vs RLS(澄清)
- **基础设施层(谁碰得到)**:CF **≥** Supabase+RLS——KV/D1/DO 无公网端点(只 binding 经 `env.X` 可达)、service binding 内部零信任、at-rest 加密。比挂公网域名靠 RLS 入口挡的 PostgREST 攻击面更小。
- **行级授权层(谁看哪行)**:CF **无** RLS 等价物(D1 无 RLS;KV/DO 是裸存储)。Cloudflare Access 是端点级不是行级,**不顶**。100% 由 worker 代码决定,且**无第二道防线**(代码写错无人兜底)→ 用 §7.3 的冷路径 RLS 把纵深赚回来。

## 8. Delta-sync / 对账协议

客户端已有"先本地渲染、再跟服务器对账"(GRDB + `client_message_id` 去重)。投影替换掉对账时**直连 Supabase 那一跳**。三层读:

```
L1 设备 GRDB(加密)    即时、离线   → 开屏先渲染(④)
L2 CF 边缘投影         10–30ms      → 追赶源(③),替代原直连 Supabase
L3 Supabase            跨区、RLS     → 冷 miss / 深翻 / 投影重建(②)
```

四个咬合细节:
1. **delta sync,不傻拉 200**:客户端报"本地到 seq X",L2 只回 X 之后。**每会话单调序列号**(`messages` 可排序键基本已有)。
2. **撤回/编辑带 tombstone**:L2 的"自 cursor 以来变更"必须含删除/改动,不只新增。否则离线期撤回同步不到。
3. **read-your-writes 已解决**:自己发的乐观写进 GRDB,靠 cmid 去重塌缩(#145/#146 已做),投影不破坏。
4. **授权面不扩大**:本地旧数据被踢出群后收不回(任何 IM 都这样);授权门只管新读(L2/L3)。

## 9. 回填 / 幂等 / 空洞检测(真正的工程风险)

webhook 至少一次、可能乱序/丢。投影喂养必须:
- **幂等**:按 message id / sequence upsert。
- **空洞检测**:序列号断层 → 触发回填。
- **冷启动/驱逐回填**:DO 第一次或被驱逐后,从 Supabase 拉一次重建尾巴/列表(一次法兰克福读,之后全本地)。**主要新增代码在此。**

## 10. 客户端侧:Repository 统一(三端缓存)— 与 #212 对接

**现状(已核实,比"Mac 没缓存"精确)**:
- 单 target 多平台(iOS 17 + macOS 14),`Sources/Mac/` 是 `#if os(macOS)` 原生视图;**iPad = iOS 家族**,缓存已与 iOS 一致。
- `LocalDatabase`(GRDB,`Sources/Storage/`)无平台条件,三端共编。
- `ChatDataSource`(`Sources/Networking/`)已是 **write-through 共享门面**:`cachedConversations/cachedMessages` 即时读、`listConversations/loadMessages` 拉服务器后写回同表(注释明写"the SAME table iOS uses")。Mac 的消息/会话列表已走它、已 cache-first。

**真实 gap**:写回(upsert/replace)调用点全景里 **`Mac/` 目录零个写回**。凡写回收进 `ChatDataSource`(共享)的实体(conversations/messages)→ Mac 自动填满;凡写回还散在 iOS-only `Features/` 视图的实体(**bots / contacts / groupMembers / groupMeta**,只有 `FriendsTabView`/`GroupSettingsView`/`ConversationView+Loading` 写)→ Mac 只读不写,而 GRDB **per-device**(Mac/iPhone 各一份不互填)→ **Mac-only 装机后这部分缓存永远空** = 用户看到的"Mac 没缓存"。

**统一原则(= T2 客户端缝)**:
1. 把 `ChatDataSource` 升成**唯一 Repository**,覆盖所有缓存实体;把散在 iOS `Features/` 的 `upsert*/replace*` 全搬进 Repository 方法。
2. 所有视图(iOS + Mac)只调 Repository,不直接碰 `LocalDatabase`、不裸 `.from()`(Mac `MacBotManagement`/`MacProfileEdit` 的 `.from()` 一并收口)。
3. T2 的 L1/L2/L3 + delta-sync **挂在 Repository 一层** → 三端自动继承,不 per-platform 接三遍。

**与 #212 对接**:`feat/mac-login-align` 已合 main(`a46e2ab2`),Mac cache-first 基础已落;但"缓存编排抽成两端完全共享 store" + "cmid 透传根治重发双投"仍是**开着的** tech-debt follow-up——**那个"共享 store"就是这里的 Repository**。本 T2 不另起,接续这两条 follow-up,且**碰 iOS 已验证加载路径需用户在场真机回归**(沿用 #212 的安全约束)。

## 11. 留在 Supabase 的(设计,非妥协)

- **客户端直连(只剩 Auth)**:登录/注册/刷新/session/OAuth(GoTrue,为 client-direct 设计;低频)。深翻历史(L3)看 §11 决策。
- **worker→Supabase**:所有 SOT 写、所有 RPC + 触发器不变量(`create_group_for_subject`、计费 settle、未读触发器、subject 创建、crew 防环、handle 上限、skill 快照…在 PG 里跑搬不走)、账本/审计/对账(append-only)、冷/关系/admin 读、**webhook 源本身**(喂每个投影)。

## 12. 更正 / 清理 / 安全(本 session 核出)

- ✅ **handle 枚举非债**:按号查别人已走 `/v1/friend-requests/lookup`(worker + `HANDLE_LOOKUP_RL`);客户端 7 处 `.from("user_handles")` 是自管理(RLS 自限,无害)。
- 🟢 **surf/scroll 死表**:`surf_runs`/`scroll_runs` 已被 envelope 取代,edge+iOS 活代码零引用,仅 schema 残留(`surf_runs` 还挂在 realtime publication 上)。已记 tech-debt。
- 🟢 **注销账号走 client `.rpc()`**:SOT 变更不该 client-direct,收进②(低频,低优先)。
- 🟡 **头像缓存收口**:已大量走 URLCache(19 处)+ 3 处裸 AsyncImage;补 ① R2/头像源发长 `Cache-Control`(内容寻址 key → immutable)② 3 处 AsyncImage 统一到缓存路径。

## 13. 分期实施(T2.x)

- **T2.0 前置(客户端)**:`ChatDataSource` → 单一 Repository,收口散落写回 + Mac 裸 `.from()`;补 bots/contacts/groups 在 Mac 的写回。**需用户在场 iOS 真机回归**(碰已验证路径)。对接 #212。
- **T2.1 投影 DO(edge)**:`conv:<id>` 消息尾 + `user:<id>` 列表/未读,SQLite-backed;webhook 喂养(幂等 + 空洞检测);冷启动回填。授权门 + RLS 可见性对照表 + fail-closed。
- **T2.2 读端点(edge)**:`GET /v1/conversations`、`GET /v1/messages?conv=&since=`(delta-sync,含 tombstone),命中投影、miss 回落 Supabase+RLS。
- **T2.3 客户端接 L2**:Repository 的 `loadX` 改 `④→③(delta)→②`;迁移那批 `.from()` 直连读(conversations/messages/attachments/envelope/skills…)到 Repository。
- **T2.4 配置 → KV**:/models、pricing、i18n、place_names、task_routing、公共 bots 目录;写时 purge。(prompt 那条已由 Langfuse session 闭环。)
- **T2.5 头像收口** + **T2.6 注销账号收进 worker**(细碎,可并)。

## 14. 决策(2026-06-07 已定)

1. **深翻历史(L3)**:热路径走 worker+投影;**深翻暂留客户端直连 Supabase+RLS**(省事、RLS 白嫖),终局再收 worker。
2. **吊销即时性**:**A — webhook 喂 roster**(最终一致,几秒窗口可接受;被踢者本地本有旧消息)。不做同步 evict。
3. **投影粒度**:**只做 2 个 DO 投影 = 消息尾(per-conv)+ 会话列表/未读(per-user)**;envelope/roster/contacts 不单独投影(roster 作为授权数据存进 conv DO,但不当独立 UI 读投影)。
4. **Auth 代理**:**不进 T2**,延后与 #252 反滥用合并(无延迟收益 + 新实现风险;footgun 在移除数据 `.from()` 时已治)。

### 实现决策(scout 后定,均无需迁移)

- **delta 序列号:不加 Postgres 列、无迁移。** 用**投影 DO 自己的单调 revision 计数器**(webhook 摄入时 ++,每行盖最后改动 revision,含 tombstone)。客户端 cursor = `DO revision`;DO 重建→换 baseline epoch,cursor 过期则客户端全量重取。`messages` 现有 `idx_messages_conv_time (conversation_id, created_at DESC)` 供回填查询。
- **独立投影 DO,不扩 REALTIME_HUB。** 新增 `ConvProjectionDO`(per conv:消息尾 + roster + revision)+ `UserProjectionDO`(per user:会话列表 + 未读 + revision),SQLite-backed,wrangler 加新 migration tag;不动正在工作的 realtime 扇出。写穿点 = `routes/realtime-internal.ts`(同一 webhook payload 顺手写穿)。
- **pre-launch 放手做**:无人使用,不保证可用性,不做灰度/兼容垫片;直接干净实现。

## 15. 非目标

- 不搬空 Supabase;不消灭写的法兰克福往返(乐观 UI 藏)。
- 不引入 staging/多环境(pre-launch 单环境立场)。
- 不做 E2E 加密(边缘投影需明文授权/服务)。
- prompts 管理不在本 spec(Langfuse + KV,另 session)。
