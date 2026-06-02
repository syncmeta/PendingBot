# 计费 P2 架构岔路 —— 用量计量 + 门禁的地基选择

日期：2026-06-02
分支：`chore/billing-dashboard-specs`
状态：**已定案(2026-06-02)= 路 2 + WalletDO + push 同步**(见文末「定案」)

## 背景:Explore 测绘的关键发现

billing-v2 **不是空壳,是一套已建成的完整本地账本**:
- 统一入口:LLM/群聊/语音/web 工具 → `enqueueAudit()`(`llm/router.ts`)→ `AUDIT_QUEUE` → `persistAuditMessage()`(`index.ts:162`,消费端)→ `settleTurnV2()` → **`settleUsage()`(`lib/billing-v2.ts:234`)**。
- `settleUsage()` 已实现:`vendorCostUsd → pnc_micros` 换算、**FIFO 多包扣减**(packs)、ledger_entries、**群 share-index 池**(`billing-v2-group.ts`)、阈值状态返回。
- 门禁:`requireBalance()`(`billing.ts:248`,LLM 调用前硬停)、`enforceBalance()`(`realtime-meter.ts`,语音逐 turn 后挂断)。读**本地** `getOwnerBalanceMicros()`(packs 聚合,快)。
- 成本三源:provider 自报(同步)/ AI Gateway logs(异步,queue 重试)/ 本地定价(语音媒体)。
- owner 解析:`resolveConversationBillingTarget` → `responsible_subject_id` 或 user。

> 含义:billing-v2 那套"不可外包的难点"(FIFO 燃尽、群池、阈值)**已经写好且在工作**。"unverified、大概率错"指的是没真机验过,不是没实现。

## 矛盾点(为什么必须拍板)

1. **门禁要快 → 必须读本地余额**。Polar 余额 ~10s 最终一致(P0 spike 实测),进不了 LLM/语音热路径的门禁。所以**本地必须有一个权威的实时余额**。
2. **现在有两套重叠账本**:我 P1 新建的 `pnc_ledger`(简单流水)+ billing-v2 的 `packs`/`ledger_entries`/`group_pools`(完整)。P1 的充值进了 Polar + `pnc_ledger`,但门禁读的是 `packs`——**两者没打通**。P2 必须合并成一套。

## 两条路(请选一条)

### 路 1 —— 复用 billing-v2 本地账本;Polar = 钱包本体/MoR/iOS 钱包面/对账(推荐)
- **本地 `settleUsage`/packs/群池 = 实时门禁的权威**(已工作,快)。
- **Polar = 收款(MoR)+ 对外钱包余额(iOS 钱包页读它)+ 对账事实源**。
- P2 工作:
  - 用量:保留现有 `settleUsage`(本地扣 + 门禁),**加 outbox → Polar `reportUsage` 镜像**(让 Polar 余额跟随)。
  - 充值:P1 的 webhook 除了 grant Polar,还要 `issuePack()` 进本地(让门禁余额也涨)→ 合并 `pnc_ledger` 与 `packs`(二选一保留;建议保留 packs,`pnc_ledger` 退役或并入)。
  - 门禁:复活 4 档阈值节流(Explore 说 v2 把节流删了只剩硬停;spec 要 4 档)。
  - 群池:`group_pools` 已实现,直接用。
- **优点**:复用大量已工作代码、门禁快、风险最低、最快能跑通。
- **代价**:本地仍是"自建账本"(违背"别自建账本"初衷)——但账本已建成,且门禁延迟逼着本地必须有余额,这条初衷在技术上本就难全。Polar 退到"MoR + 对外钱包",仍解决了收款/税/iOS 入账。

### 路 2 —— Polar = 余额事实源;edge 只留薄缓存 + 群池
- **Polar 是钱包本体**;edge 只保留:一个**快缓存余额**(从 Polar 同步)+ 群 share-index 池。
- P2 工作:**拆掉 `settleUsage`/packs/ledger_entries**;用量异步扣 Polar;门禁读缓存余额(事件驱动 + 定时从 Polar 同步);自己建缓存同步 + 失效逻辑。
- **优点**:最贴 spec 的"干净 Polar"愿景;本地不再有完整账本要维护。
- **代价**:**扔掉已工作的 FIFO/阈值/群池本地实现**;要新建"Polar→edge 余额缓存同步"这层(Polar ~10s 延迟下做实时门禁缓存,易出一致性 bug);风险与工作量都更高。

## 我的推荐:**路 1**
理由:billing-v2 的难点已经建成并工作,门禁延迟现实又**强制**本地要有权威余额——既然本地账本无论如何躲不掉,复用已工作的那套(而非推翻重建一个缓存层)风险最低、最快见效。Polar 退一步当"MoR + 对外钱包 + 对账",依然兑现了你要的"收款/代税/iOS 入账/不直连 Stripe"。代价是"别自建账本"这条初衷打折,但它在"实时门禁"约束下本就难完全实现。

> 若你更看重 spec 的纯粹性、愿意承担重建缓存层的风险与工时,选路 2。

## 选定后我会做的(P2 实现计划,届时细化)
- 合并 `pnc_ledger` ↔ `packs`(留一套)。
- 用量:`settleUsage`(路1)或 Polar 扣(路2)+ outbox。
- 门禁:4 档阈值(≥50 正常 / <50 提醒 / <5 节流走 OpenRouter cheap+关工具 / ≤0 硬停),挂在 `enqueueAudit`(LLM)、`realtime-meter`/`room-voice`(语音)、sandbox start(**sandbox 计费目前未实现,需补**)。
- 群池接 Polar 侧(路1 群池已在本地;Polar 只收镜像)。
- sandbox_runtime 计费补齐(Explore 标注:目前完全没接)。

## 定案(2026-06-02)= 路 2 + WalletDO + push 同步

用户决定:**Polar 当钱包本体,不为门禁让步**。门禁用 **Cloudflare Durable Object 缓存**解决。

### 架构
- **Polar** = 余额事实源 + credit 授予/过期/燃尽 + MoR + iOS 钱包面读它。
- **`WalletDO`(每 subject 一个)** = Polar 在边缘的**强一致缓存 + 门禁闸 + 用量 outbox**。**不是账本**——只存一个 `balanceMicros` + `pendingUsage[]` 缓冲(DO 自带 SQLite,持久)。
  - `gateAndDebit(pncMicros, meta)`:DO 内原子——按 4 档阈值判定 → 允许则 `balance -= pnc` + 记 `pendingUsage` → 返回 `{allowed, thresholdState, balanceAfter}`。强一致、不超支。
  - `credit(pncMicros)` / `applyAbsolute(polarBalance)`:被 edge push 调用。
  - `alarm()` 稀疏兜底:把 `pendingUsage` flush 到 Polar(`events.ingest`)+ 极低频从 Polar 拉绝对值纠偏(防丢包)。
  - **冷启动/首次门禁**:DO 无缓存时,惰性从 Polar `getStateExternal` 拉一次初始化。
- **为什么 DO 不是 KV**:余额是高频递减计数器,KV 最终一致 + last-write-wins 会**丢扣减/超支**;DO 单线程强一致,串行扣减不竞争。
- **billing-v2 的 settleUsage/packs/ledger_entries → 退役**(路 2 不要本地账本)。`pnc_ledger`(P1)保留为**支付/对账审计**,不再当门禁余额。
- **群**:群=Polar customer + 群的 WalletDO;share-index 池(退款分摊数学)留 Supabase(`group_pools`),Polar 不管这个。

### 同步模型(全 push,几乎零轮询)
| 余额变动源 | 通知 DO 的方式 |
|---|---|
| 用量扣减 | 发生在 DO 内,自知 |
| 充值/退款/admin/群充资退群 | 都从 edge 发起 → handler 直接 push DO |
| Polar 侧自变(过期、后台手改) | Polar **`customer.state_changed`** webhook → edge → push DO(对齐绝对值) |
- 兜底:**仅**一个极稀的安全对账(DO alarm 几分钟/更久,或"久无事件才拉一次"),专防 webhook 丢包。不是高频轮询。

## ⚠️ 坑清单(实现时必须处理)

1. **回环双扣**:DO 本地扣 + flush 用量给 Polar → Polar 处理后 `customer.state_changed` 回来。处理:**state_changed 带绝对余额,DO 对齐到 `绝对值 − 在途未被Polar反映的pending`,不再减 delta**。
2. **丢 webhook → 余额偏高 → 用户超花**(钱!):靠"稀疏安全对账"兜底纠偏;关键扣费路径宁可保守。
3. **DO 必须用强一致存储扣减**(不是 KV),否则并发调用丢扣减/超支。
4. **pendingUsage 必须落 DO SQLite(持久)**:崩溃不丢可计费量,下次 alarm 补发(= outbox 语义)。
5. **Polar ~10s 最终一致**:门禁只读 DO 本地值;Polar 当 SoR/对账,绝不进热路径读。
6. **符号约定沿用**:充值=负值事件、用量=正值事件、`getStateExternal.balance` 正=可用(P0 已验)。
7. **`customer.state_changed` 字段待核**:是否含 meter 余额、是否每笔用量都触发(影响回环处理)——P2 spike 时核。
8. **owner=最终责任主体**(group→responsible_subject_id,非发起 userId);路由到对应 subject 的 WalletDO。
9. **上报给 Polar 的是 vendor 成本(不含平台 markup)**;markup 只在卖包体现。
10. **系统级级联**(title-runner/lookback/bot_note 等)按现状跳过门禁/或归属正确 subject——别误扣误拦。
11. **DO 路由延迟**:gate 多一次 DO 往返(几~几十 ms),相对一次 LLM 调用可忽略;语音/ sandbox 周期 settle 同理可接受。

## P2 范围(含 sandbox)
- WalletDO(gate+debit+credit+alarm flush/reconcile)。
- 门禁 + 用量上报挂到:LLM(`enqueueAudit`/`persistAuditMessage`)、语音(`realtime-meter`/`room-voice`)、web tools、**sandbox(代码执行,目前完全没接计费 → P2 一并补:执行前 gate + 执行后按时长/资源 settle)**。
- Polar `customer.state_changed` webhook handler → push DO。
- 充值/退款 push DO(P1 webhook 接 DO)。
- 退役 billing-v2 settleUsage/packs/ledger_entries;`pnc_ledger` 转审计。
- 群 WalletDO + share-index 池保留。
- 4 档阈值节流(复活;Explore 指出 v2 把节流删了只剩硬停)。
