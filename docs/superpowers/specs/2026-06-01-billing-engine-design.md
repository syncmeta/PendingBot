# 计费引擎设计 —— 外包第 3/4 层

日期：2026-06-01
分支：`chore/billing-dashboard-specs`
状态：**草案,待评审**

> 关联文档：同分支的 [`2026-06-01-dashboard-stack-design.md`](./2026-06-01-dashboard-stack-design.md)(dashboard 栈)。两者独立,但本设计落地后会缩小 dashboard 的「收入 BI」工作量(OpenMeter 自带计费视图)。

## 目的

用成熟的现成平台**重建计费的第 3、4 层**,替代未验证的 billing-v2 自研实现:

- **第 3 层** 收据校验 / 权益:iOS IAP 收据校验、Apple 服务端通知、退款回流 —— 交给 **RevenueCat**。
- **第 4 层** 计量 + 钱包 + 计价账本 + 实时门禁:`usage_events` → 计价 → 扣预付额度 → 余额事实源 → 调用前拦截 —— 交给 **OpenMeter Cloud**。

「自己做计费很痛」的根因是把计费当成一坨。它实为 5 层(见下),每层都有现成方案,**只有第 5 层(群分摊业务策略)该自己写**。本设计把自研面积缩小一个量级。

### 背景:为什么是重建而非迁移

`billing-v2`(task #180–190)**从未在生产跑过、不确定是否完成、未经验证**。因此按「基线未验证就大胆重写」的原则,本设计将其视为**绿地**,直接照现成方案搭,不为旧代码对冲、不做风险迁移。旧 billing-v2 的表如何退役/复用见 §7。

## 非目标

- **不**改收款通道与 MoR(已定:iOS = Apple IAP;Mac/Web = Lemon Squeezy)。
- **不**绕开 Apple IAP 抽成(iOS 卖数字额度强制走 IAP,任何工具都绕不开;模型注定预付)。
- **不**自托管计费引擎。计费是「挂掉=收不了钱/扣不了费」的高代价系统,自托管钱的账本与「想少痛」相悖 —— 故第 4 层选**托管**(OpenMeter Cloud),即便它开源也可自托管。
- **不**在本期做订阅制(recurring plans)。当前模型是**预付额度**(买额度包 → 钱包 → 按用量扣)。

## 决策栈总览

| 层 | 职责 | 方案 | 形态 / 成本 |
|---|---|---|---|
| 1 收款通道 | 把钱收进来 | Apple IAP(iOS)/ Lemon Squeezy(Web) | 已定 |
| 2 税务 / MoR | 法律卖家、代缴税 | Apple(IAP)/ Lemon Squeezy(MoR ~5%+50¢) | 已定 |
| **3 收据/权益** | IAP 收据校验、退款回流 | **RevenueCat** | <$2,500 MTR/月免费,超出 1% |
| **4 计量+钱包+计价+门禁** | usage→计价→扣额度→余额→拦截 | **OpenMeter Cloud** | 托管;免费/低价档(签约时核实上限) |
| 5 业务策略 | 群分摊 share-index | **自研(薄)** | 长在第 4 层之上 |

## 核心建模决策

### 单一「credit」计价单位(推荐)

计价规则是 PendingBot 的**专有逻辑**(模型价格倍率从 OpenRouter 派生、语音按分钟、web/sandbox 各有费率),不适合塞进通用计费平台。因此:

- **edge 负责把每次用量换算成 credits**(它已持有目录与倍率),向 OpenMeter 上报**已消耗的 credits**。
- **OpenMeter 以单一 credit 为单位**做:额度授予(grant)、按优先级燃尽 + 过期、余额事实源、**实时 entitlement 门禁**。

这样专有计价留在 edge,而账本/余额/燃尽/门禁这些最容易出错、最该外包的全归 OpenMeter。

> 备选(开放问题 §8-1):向 OpenMeter 上报**原始用量**(token/分钟),在 OpenMeter 内定义费率做 rating。更「正统」但要把专有倍率搬进平台,耦合更高。本设计先选单一 credit 单位。

### 概念映射

| PendingBot 概念 | OpenMeter 原语 |
|---|---|
| subject(用户 / 群账号) | customer / subject |
| 钱包余额 | metered **entitlement**(credit 计) 的余额 |
| 充值入账(IAP/LS) | **credit grant**(可带过期) |
| 兑换码促销额度 | promotional credit grant(低优先级先燃) |
| 一次用量(LLM/语音/web/sandbox) | 上报到 credit meter 的 usage event |
| 调用前「够不够」 | entitlement **实时余额查询**(门禁核心) |
| 退款 / chargeback | 负向 grant / 调整 |

## 端到端架构

### 充值入账(credit-in)——两个收款源汇到一个端点

```
iOS IAP  → RevenueCat ─┐
                       ├─→ edge POST /v1/billing/credit (internal)
Web      → Lemon Squeezy ┘        │
                                  ├─ OpenMeter: 创建 credit grant
                                  └─ 刷新 edge 余额缓存
```

- RevenueCat / Lemon Squeezy 各自的 webhook handler 解析「购买成功」事件,归一成「给 subject X 授予 N credits」,调用内部入账逻辑。
- 入账逻辑**幂等**(按 provider 交易 id 去重),防 webhook 重投重复加额度。

### 用量计量(usage-out)+ 实时门禁(gate)

```
调用前: edge gate(subjectId) ── 读缓存余额/entitlement ──→ 允许 / 拦截 / 预警(overdraft 策略)
调用后: edge 算 credits 成本 → 写 outbox → 异步上报 OpenMeter usage event → 扣减 entitlement
```

- **门禁是薄的、留在 edge**:任何计费平台都不该进 LLM 的 token 热路径。edge 持一份从 OpenMeter entitlement 同步来的**缓存余额**做亚毫秒判断。
- **可靠投递用 outbox**:用量事件先落 edge 的 outbox 表,再异步推 OpenMeter,带重试 —— **不能丢可计费事件**。
- 门禁硬度(硬拦 vs 允许软 overdraft 后补)见开放问题 §8-2。

### 群分摊(第 5 层,唯一自研,且薄)

- 一笔群用量发生时,edge 按 share-index 算出**各成员应分的 credits**,据 `group_billing_config` / `group_member_billing` 决定扣**群账号钱包**还是**按成员钱包**。
- 据此向 OpenMeter 上报**按 subject 拆分**的多条 usage event。余额账本仍是 OpenMeter 的;edge 只决定「这笔分给谁、各多少」。

### 退款 / chargeback / 兑换码 / 对账

- **退款**:RevenueCat / LS 退款 webhook → 负向 credit grant(或调整);chargeback 记为损失调整。
- **兑换码**:核销 → 发促销 credit grant(优先燃尽、可设过期);`redemption_codes` 仍管码库存。
- **对账 cron**:以 OpenMeter 余额为**事实源**,定期核对 edge 缓存,漂移告警(进 dashboard / Sentry)。

## 组件与接口

edge 侧新增 / 调整(全部薄):

- `POST /v1/billing/credit`(internal)—— 入账,幂等;被两个 webhook handler 调用。
- RevenueCat webhook handler —— 购买 / 退款 → 入账 / 负向调整。
- Lemon Squeezy webhook handler —— 同上。
- usage reporter —— 在 LLM / 语音 / web / sandbox 路径算 credits → 写 outbox → 推 OpenMeter。
- balance gate + 缓存同步 —— `checkBalance(subjectId)`;事件驱动 + 定时双通道刷新缓存。
- redemption —— 兑换码 → 促销 grant。
- reconciliation cron —— 拉 OpenMeter 余额,核对 edge 缓存。
- OpenMeter SDK:Node/TS,在 edge 调用。

## 与现有 billing-v2 表的关系(需谨慎,见 §8-7)

| billing-v2 表 | 去向 |
|---|---|
| `subject_wallets`(余额事实源) | 降级为 edge **缓存**(SoR 移到 OpenMeter);或保留作缓存表 |
| `billing_ledger` / `ledger_entries` | OpenMeter 即账本 → **退役**(或留薄审计) |
| `usage_events` | 改作 edge **outbox / 原始日志**,可靠投递后可裁剪 |
| `topups` / `refund_events` | 保留为**支付事件审计**(触发 grant 的凭据) |
| `redemption_codes` | **保留**(码库存),发额度走 OpenMeter |
| `group_billing_config` / `group_member_billing` | **保留**(专有分摊策略,第 5 层) |

## 数据 / 隐私 / 安全

- OpenMeter 只收**计量元数据**(subject id、credits、资源类型),**不发**聊天内容 / PII。
- 入账端点 internal-only,幂等防重投;webhook 验签。
- 聊天 / 账单真身仍只在 Supabase;OpenMeter 是余额/额度事实源,非内容存储。
- 核实 OpenMeter Cloud 数据区域(优先 EU,与 PostHog 一致)。

## 开放问题(评审需拍板)

1. **计价单位**:单一 credit(edge 计价,推荐)vs 上报原始用量在 OpenMeter 内 rating?
2. **门禁硬度**:硬拦(余额不足即拒)vs 软 overdraft(允许小额透支后补扣)?影响缓存新鲜度与同步策略。
3. **群分摊优先级**:群账号钱包 vs 成员钱包的扣减先后与回退规则。
4. **outbox 可靠性**:用量事件投递的重试 / 去重 / 死信处理细节。
5. **OpenMeter Cloud 上限与封顶**:免费/低价档的事件量上限、超出价格、数据区域 —— 签约时核实。
6. **iOS 商品形态**:consumable 额度包的 RevenueCat 产品配置 + 恢复购买语义。
7. **billing-v2 退役节奏**:绿地直接切 vs 双轨并行验平再切(钱正确性高风险,倾向先并行对账)。

## 成本

- OpenMeter Cloud:托管,免费/低价档起(核实上限);超量按事件计。
- RevenueCat:<$2,500 MTR/月免费,超出 1%。
- Lemon Squeezy:MoR ~5%+50¢。
- **无额外 VPS**(第 4 层托管)。

## 分阶段落地 checklist

> 设计阶段,以下为待办,非已完成。

- [ ] **P0** OpenMeter Cloud 账号 + 定义 credit entitlement + subject 模型;打通「查余额 + 发 grant」最小调用。
- [ ] **P1** 入账主干:RevenueCat + Lemon Squeezy webhook → `/v1/billing/credit` → grant;充值端到端跑通(幂等)。
- [ ] **P2** 用量主干:edge credits 计价 → outbox → 上报 OpenMeter(LLM / 语音 / web / sandbox 逐路径)。
- [ ] **P3** 实时门禁 + 缓存同步(事件驱动 + 定时)。
- [ ] **P4** 群分摊策略(第 5 层)长在 OpenMeter 之上。
- [ ] **P5** 退款 / chargeback / 兑换码。
- [ ] **P6** 对账 cron + billing-v2 表退役/repoint(按 §8-7 节奏)。
- [ ] **P7** iOS 钱包页改读新余额源。
