# 计费引擎设计 —— 外包第 3/4 层

日期：2026-06-01
分支：`chore/billing-dashboard-specs`
状态：**草案,待评审**（2026-06-01 通读 billing-v2-design.md 后大改）

> 关联文档：
> - [`docs/billing-v2-design.md`](../../billing-v2-design.md) —— **概念模型源**。本设计保留它的全部业务语义(PNC、markup-at-sale、pack、share-index 群池、阈值、退款规则),只把它**自研的引擎实现**换成现成平台。
> - 同分支的 [`2026-06-01-dashboard-stack-design.md`](./2026-06-01-dashboard-stack-design.md)(dashboard 栈)。本设计落地后会缩小 dashboard 的「收入 BI」工作量。

## 目的

用成熟现成平台**重建计费的第 3、4 层**,替代未验证的 billing-v2 自研实现:

- **第 3 层** 收据校验 / 权益:iOS IAP 收据校验、Apple 服务端通知、退款回流 → **RevenueCat**。
- **第 4 层** 计量 + 钱包 + 计价账本 + 实时门禁 → **OpenMeter Cloud**。

「自己做计费很痛」的根因是把计费当一坨。它实为 5 层,每层都有现成方案,**只有第 5 层(群 share-index 池 + 退款编排)该自研**——但这一层是 billing-v2 明确的**产品核心**,不薄。

### 背景:为什么重建而非迁移

`billing-v2`(task #180–190)**从未服役、不确定是否完成、未经验证**。按「基线未验证就大胆重写」,视为**绿地**直接搭。**纯绿地、不做双轨对账**(没有服役系统可对账,平行对账是伪命题)。

要换掉的只是 billing-v2 的**引擎实现**(`settleUsage`、`packs`/`ledger_entries` 当事实源、多包手写扣减);它的**设计语义全部保留**。

## 非目标

- **不**改收款通道与 MoR(已定:iOS = Apple IAP;Mac/Web = Lemon Squeezy)。
- **不**绕开 Apple IAP 抽成(iOS 卖数字额度强制走 IAP)。
- **不**自托管计费引擎(挂掉=收不了钱的高代价系统;第 4 层选托管,即便 OpenMeter 开源)。
- **不**做订阅制;当前是**预付额度**(买 PNC 包 → 钱包 → 按用量扣)。
- **不**做 reserve/settle 状态机(沿用 billing-v2 §7「settle-only」决策)。

## 决策栈总览

| 层 | 职责 | 方案 | 形态 / 成本 |
|---|---|---|---|
| 1 收款通道 | 把钱收进来 | Apple IAP / Lemon Squeezy | 已定 |
| 2 税务 / MoR | 法律卖家、代缴税 | Apple(IAP)/ Lemon Squeezy(~5%+50¢) | 已定 |
| **3 收据/权益** | IAP 收据校验、退款回流 | **RevenueCat** | <$2,500 MTR/月免费,超出 1% |
| **4 计量+钱包+计价+门禁** | 余额事实源、grant、按过期燃尽、实时余额查询 | **OpenMeter Cloud** | 托管(上限/精度签约前核实) |
| 5 业务策略 | 群 share-index 池、退款/链式退款编排、阈值/节流、periodic settle | **自研** | 长在第 4 层之上 |

## 核心建模决策

### 计价单位 = `pnc_micros`(整数,已定)

- **PNC** = Pending Name Credits,系统基础单位;**27 PNC = 1 USD**(故意不整除,防心算、降消费痛感——产品不变量,**别改回 100/1000**)。
- 内部用高精度原子单位 **`pnc_micros`(bigint)**:`pnc_micros = vendor_cost_usd * 27 * 1_000_000`。
- **运行时只按真实成本扣**(`provider_cost_usd * 27`),**无 per-call markup**;利润只在卖包时体现(见下)。
- **OpenMeter 的 credit 单位 = 1 pnc_micro(整数)**。**禁止每事件四舍五入**(否则便宜模型/短工具被系统性放大或漏计)。
- **精度已核实(2026-06-01,源码)**:OpenMeter 的 grant `Amount`/余额是 **`float64`**(`openmeter/credit/grant.go:26`)。float64 尾数 53 位 → **整数在 ±2^53(≈9.007×10¹⁵)内精确**。量级:2^53 ≈ 90 亿 PNC ≈ 单账户 $3.3 亿,永不接近;单次扣费(便宜模型≈2700 micros)远小于。**结论:float64 对本设计精确,不阻断选型**,但靠以下硬约束保证:
  1. **只发整数 `pnc_micros`**,永不发小数 credit。
  2. **不用 OpenMeter 的 reset / rollover / proration**(我们的 grant = 一次性充值包 + 到期,无周期重置 → 不触发除法/取整)。
  3. **不在 OpenMeter 内做 rating**(edge 先算成整数 micros 再上报,平台只 SUM/减法,burn-down 只做减)。

### Markup 只在销售侧(已定)

利润体现在**发放 PNC 包**那一刻,markup 写进**每笔 pack 的 `sales_markup_snapshot`**,不进运行时配置。例:实付 10 USD(IAP,Apple 抽 30%)→ 净 7 USD,markup=2.0 → 发 `7/2.0*27 ≈ 94.5 PNC`(`94_500_000 pnc_micros`)。这让运行账本与供应商账单一一对应,销售记录保留真实经济参数。

### 商品形态(照 billing-v2,不简化不扩张)

- **单一「现金充值包」**,1 年过期,无促销/优先级/限定服务分类。
- 多包消耗规则只有一条:**最快过期先用**(`ORDER BY expires_at ASC NULLS LAST, created_at ASC`)→ **正好等于 OpenMeter grant 的按过期/优先级 burn-down**(需核实其燃尽顺序可配为 earliest-expiry-first)。
- pack 字段(markup 快照、gross/net、external_purchase_id 唯一索引)留在 edge 作**支付/会计审计**;余额燃尽交 OpenMeter grant。

### 概念映射

| PendingBot 概念 | OpenMeter 原语 |
|---|---|
| 用户 / 群账户 | 各是一个独立 **subject/customer** |
| 钱包余额(`pnc_micros`) | metered **entitlement** 余额 |
| PNC 充值包 | 一笔 **credit grant**(带过期、按过期燃尽) |
| 一次用量扣费 | 上报 credit meter 的 usage event(单位 pnc_micros) |
| 调用前「够不够」 | entitlement **实时余额查询**(门禁) |
| 退款(冲销未消耗) | revoke 该 grant 的**剩余**额度(不扣成负) |
| 过期 | grant 过期 → 需捕获事件记 **breakage revenue** |
| admin 赠送 | `admin_grant` credit grant(经控制台) |

## 端到端架构

### 充值入账(credit-in)

```
iOS IAP  → RevenueCat ─┐  (Apple ASN V2: 购买/REFUND/REVOKE)
                       ├─→ edge 入账逻辑(幂等,external_purchase_id 唯一)
Web      → Lemon Squeezy ┘     ├─ 算 net_revenue → markup → initial_pnc_micros
                               ├─ 写 edge pack 审计记录(快照 markup/gross/net)
                               ├─ OpenMeter: 创建 credit grant(1 年过期)
                               └─ 刷新 edge 余额缓存(优先偿还 overdraft)
```

- 两个收款源各自 webhook 验签后归一成「给 subject X 授予 N pnc_micros」。
- 幂等:按 provider 交易 id 去重,防 webhook 重投。

### 用量计量 + settle(settle-only,无 reserve)

服务成本**全量纳入**(billing-v2 §5,8 类):`llm_tokens`、`server_side_tools`、`web_tools`、`voice_tokens`、`realtimekit_media`、`sandbox_runtime`、`storage_transfer`、`push_delivery`。计价来源 = AI Gateway cost / provider reported / 本地 **pricebooks**(先 hardcoded constants 起步)。

| 服务 | settle 策略 |
|---|---|
| LLM(同步/流式) | 调用完按实际 usage settle;流式中途跌破阈值不打断当前请求 |
| 带工具的 LLM | 每次工具调用一条独立 usage event,独立 settle |
| 语音 / Realtime | **周期 settle 每 15s;settle 后余额 ≤0 立即关会话** |
| RealtimeKit 群媒体 | **周期 settle 每 60s**,按 participant-minute |
| Sandbox / 容器 | **周期 settle 每 30s;settle 后余额 ≤0 立即终止容器** |
| 群账户 | 同一套 settle,扣**群 subject**余额 |

```
调用前/周期: edge 读缓存余额 → 按 §阈值决策(可含杀活动会话)
settle:      edge 算 pnc_micros → 写 outbox → 异步上报 OpenMeter → 扣 entitlement
```

- **门禁/settle 留 edge**:计费平台不进 LLM token 热路径;edge 持 OpenMeter 同步来的缓存余额做亚毫秒判断,并负责 periodic settle 调度与**杀活动会话/容器**。
- **outbox(发件箱)**:扣费先落 edge 本地表(与记业务同事务),异步 worker 推 OpenMeter、成功标记、失败重试 —— **崩溃不丢可计费事件、可重试、与延迟解耦**。

### 余额阈值与节流(4 档,作用于个人或群账户总余量)

| 阶段 | 阈值 | 行为 |
|---|---|---|
| 充足 | ≥ 50 PNC | 正常 |
| 低额提醒 | < 50 PNC | 正常调用 + AI 回复尾部/会话顶部注入提醒(每 24h 一次) |
| 节流 | < 5 PNC | 强制 OpenRouter `cost_quality_tradeoff=max`(不硬编码模型 id)、关全部工具、注入简短回复+充值提示 |
| 硬停 | ≤ 0 PNC | no-balance notice 模型说「余额花完了」(24h 最多 3 次,超出退纯文本);非模型路径固定文案 |

- **Overdraft buffer = 精确 −0.5 PNC**(兜流式最后几 token 估算误差),不打断当前请求;跌入 `[-0.5, 0)` 下次请求触发硬停;充值优先偿还 overdraft。
- 阈值数字写 **edge config(不进 DB)**,方便临时调。
- 群/个人独立:群余额低→群内开销节流;个人余额低→个人开销节流。**群消费默认走群账户**(§开放问题-2)。

### 群账户(share-index 池)—— 产品核心,自研,且不薄

> ⚠️ 关键:**群消费直接扣群账户余额,不在消费时按成员拆分。** share-index 只在**退款**时算"我那份"。这是为了「消费时不更新 N 行 contribution」。

- **群 = 独立 OpenMeter subject**,有自己的 grant(注资发 grant、消费扣群 subject 余额)。
- edge 保留簿记(承接 billing-v2 §9):
  - `group_pools(subject_id, total_remaining_pnc_micros, share_index numeric(40,20))` —— `share_index` 单调缩减,初始 1.0。
  - `group_contributions(... contributed_pnc_micros, share_index_at_join, status, source_pack_id)`。
- **注资**:从用户钱包扣 N → 群池 += N、记 contribution(快照当前 share_index)、群 subject 发 grant。
- **群消费 X**:`share_index *= (total-X)/total; total -= X`(只更新池一行;各 active 份额自然按比例缩水)。
- **退群退款**:`share_now = contributed * (当前 share_index / share_index_at_join)`;群池减 share_now、share_index 不变;给该用户钱包发 `group_refund` grant;contribution 置 refunded。**解散** = 对所有 active 成员各跑一次。
- **不变量**:`Σ contributed*(share_index/share_index_at_join) ≈ total_remaining`,reconciliation 偏差 >1 PNC 报警。
- **Apple/LS 链式退款**:退款的钱已进群池 → 按 share_now 从群池冲销 + 作废对应 pack;**超出 share_now 的已花部分平台自担**,不向其他成员追讨;记 `chargeback_loss`、标记 `refund_risk`。

### 退款(个人 pack,3 case)

按 `consumed = Σ ledger.debit+expired (pack=X)` 分三种:
- **A 未消耗**:整笔作废(remaining→0、status=refunded)。
- **B 部分消耗**:作废剩余(remaining→0),**已消耗部分不追讨**,记 `chargeback_loss`。
- **C 已用完**:仅状态改 refunded,**不扣成负**,全额计 `chargeback_loss`。
- 映射 OpenMeter:**revoke 该 grant 的剩余额度**(永不把余额扣成负);`refund_count++`,超阈值 `refund_risk=true` → Web/LS 路径限速或人工审批(IAP 仍放行)。

### 过期 / admin / 对账

- **过期**:OpenMeter grant 原生过期;edge cron 同步记 **breakage revenue** 审计(需确认能从 OpenMeter 拿到过期事件——§开放问题-3)。到期前 7 天/1 天本地通知(复用 iOS 通道,**务必做,否则 App Store 评论会爆**)。
- **admin 赠送/调整**:走 **Appsmith 控制台** → `admin_grant` grant / ledger adjustment;必填 `reason`/可选 `ticket_ref`;`|delta|>100 PNC` 或影响 ≥10 owner 触发二次确认;进 `audit_log` + 通知。
- **对账 cron**:OpenMeter 为余额事实源,核对 edge 缓存 + 群池不变量,漂移告警(进 dashboard / Sentry)。

## 组件与接口(edge,薄)

- `POST /v1/billing/iap/notify`(Apple ASN V2)、`POST /v1/billing/lemonsqueezy/webhook` —— 验签 + 幂等入账/退款。
- usage reporter —— 各路径算 `pnc_micros` → outbox → 推 OpenMeter(含 periodic settle 调度 + 杀会话/容器)。
- balance gate + 缓存同步 —— 事件驱动 + 定时双通道。
- 群池簿记 + 退款编排(注资/消费/退群/解散/链式退款)。
- redemption(兑换码 → grant)、admin grant/adjustment(控制台触发)。
- reconciliation cron。
- OpenMeter SDK(Node/TS)。

## 与现有 billing-v2 表的关系（纯绿地,不保旧路径）

| billing-v2 表 | 去向 |
|---|---|
| `packs` | 降级为 edge 的**支付/markup 审计记录**;余额燃尽交 OpenMeter grant |
| `ledger_entries` / `billing_ledger` | OpenMeter 即账本 → **退役**(或留薄审计) |
| `usage_events` | 改作 edge **outbox / 原始日志** |
| `topups` / `refund_events` | 保留为**支付事件审计** |
| `redemption_codes` | **保留**(码库存),发额度走 OpenMeter |
| `group_pools` / `group_contributions` | **保留**(share-index 簿记,第 5 层核心) |
| `group_billing_config` / `group_member_billing` | **保留**(分摊策略) |
| `pricebooks` | **保留/新建**(edge 计价来源,先 hardcoded) |

## 数据 / 隐私 / 安全

- OpenMeter 只收**计量元数据**(subject id、pnc_micros、event_category),**不发**聊天内容 / PII。
- 入账端点 internal-only、webhook 验签、幂等防重投。
- 聊天/账单真身只在 Supabase;OpenMeter 是余额事实源,非内容存储。核实数据区域(优先 EU,与 PostHog 一致)。

## 已拍板(2026-06-01)

- 计价单位 = `pnc_micros`(整数,edge 计价);否决「OpenMeter 内 rating」。
- 门禁 = 软 overdraft(**精确 −0.5 PNC**)+ billing-v2 4 档阈值。
- 商品形态 = 单一现金充值包、1 年过期、markup 快照。
- settle-only,无 reserve。
- 退役节奏 = 纯绿地,不做双轨对账。

## BYOK 边界(2026-06-01 对齐产品 spec v2)

BYOK **没被移除**:它是 **PendingCrew 未登录(开源)模式**专用(产品 spec v2 §5.2)。task #97 移除的只是**主 PendingBot** 的 BYOK 提供商目录。计费含义:

- **BYOK 路径完全在计费系统之外**:LLM 调用直接走用户自己的 native key,**永不进 PNC 账本 / 不发 OpenMeter / 无 subject 可计费**。
- BYOK 未登录态只能跑**本地 crew**,不能开 Fly/云端 → 不会产生 PendingBot 托管服务(云 sandbox/托管搜索/存储)的可计费成本。
- **群账号永远 unified billing,无 BYOK**(spec v2 §4.3)。
- ∴ billing-v2 §11 的 BYOK 规则在 PendingCrew 语境下**仍然有效**,不作废。

## 开放问题(评审/写计划时定)

1. **群 vs 个人节流优先级**:billing-v2 默认「群开销走群账户、个人余额只管个人」,确认沿用。
2. **breakage 事件捕获**:OpenMeter 过期 grant 能否回吐事件供 edge 记 breakage revenue?
3. **OpenMeter Cloud 上限/数据区域**:免费/低价档事件量、超出价、EU 区——签约时核实。
4. **outbox 落地**:Supabase vs D1?draining 用 CF Queue vs cron?重试/去重/死信。
5. **pricebook 表结构**(vendor×sku×effective_at vs model_id×period)+ 月度软上限是否要做。
6. **iOS 商品接入**:consumable 充值包的 RevenueCat 产品配置 + 恢复购买语义。
7. **缓存余额新鲜度**:软 overdraft 下缓存允许多旧?刷新窗口取值。

## 成本

- OpenMeter Cloud:托管,免费/低价档起(核实);RevenueCat:<$2,500 MTR/月免费,超 1%;Lemon Squeezy:~5%+50¢;**无额外 VPS**。

## 分阶段落地 checklist

> 设计阶段,以下为待办。

- [ ] **P0** 核实 OpenMeter Cloud 上限/EU 区(精度已核实=float64,靠整数 micros 约束保精确);OpenMeter 账号 + 定义 pnc_micros credit entitlement + subject 模型;打通「查余额 + 发 grant + revoke」最小调用。
- [ ] **P1** 入账主干:RevenueCat(ASN V2)+ LS webhook → 验签/幂等 → markup 算 initial_pnc_micros → 发 grant + pack 审计记录。
- [ ] **P2** 用量主干:pricebooks(hardcoded)+ 8 类 event 计价 → outbox → 上报 OpenMeter。
- [ ] **P3** settle 策略:LLM 即时 + 语音/群媒体/sandbox periodic settle + **余额≤0 杀会话/容器**;4 档阈值 + −0.5 overdraft + 缓存同步。
- [ ] **P4** 群 share-index 池:注资/消费/退群/解散 + 不变量 reconciliation(产品核心)。
- [ ] **P5** 退款 3-case + Apple/LS 链式退款 + chargeback_loss + refund_risk。
- [ ] **P6** 兑换码 + admin grant/adjustment(Appsmith 控制台)+ 过期 breakage + 对账 cron。
- [ ] **P7** iOS 钱包页(总余量/包列表/过期高亮/消耗趋势/分类汇总)改读新余额源。
