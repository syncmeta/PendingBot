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

> **沿用 billing-v2 的概念模型。** 见 [`docs/billing-v2-design.md`](../../billing-v2-design.md)。要换掉的只是 billing-v2 **自研的引擎实现**(`settleUsage`、账本表当事实源);它的**设计——PNC 单位、markup 只在卖包体现、pack 过期、低额/节流阈值、群结算——基本全部保留**,改用 OpenMeter + RevenueCat 实现。

### 计价单位 = PNC(单一 credit,已定)

计价规则是 PendingBot 的**专有逻辑**(模型价格倍率从 OpenRouter 派生、语音按分钟、web/sandbox 各有费率),不适合塞进通用计费平台。billing-v2 早已选定此路:**系统内部只按真实服务成本记 PNC,利润只在卖 PNC 包时体现**。因此:

- **edge 把每次用量按真实成本换算成 PNC**(它已持有目录与倍率),向 OpenMeter 上报**已消耗的 PNC**。
- **OpenMeter 以单一 credit(= PNC)为单位**做:额度授予(grant)、按优先级燃尽 + 过期、余额事实源、**实时 entitlement 门禁**。

这样专有计价留在 edge,而账本/余额/燃尽/门禁这些最容易出错、最该外包的全归 OpenMeter。

> 否决的备选:向 OpenMeter 上报**原始用量**(token/分钟)并在平台内定义费率 rating。要把动态派生的倍率搬进 OpenMeter 费率表并持续同步 = 新的漂移源,与 billing-v2 既有的 PNC 模型也冲突。不采用。

### 商品形态(照 billing-v2,不简化也不扩张)

- **PNC 包**:上线只有**单一「现金充值包」**,1 年过期,无促销/优先级/限定服务分类。
- **markup 快照**:每笔 pack 落 `sales_markup_snapshot`,不引用运行时全局 markup 配置(改促销/套餐不污染历史已售包与运行账本)。
- **映射**:一个 PNC 包 = 一笔 **OpenMeter credit grant**(带过期 + 优先级燃尽,天生匹配);markup 快照留在 edge 的 pack 记录(作支付审计,OpenMeter 不需要)。

### 概念映射

| PendingBot 概念 | OpenMeter 原语 |
|---|---|
| subject(用户 / 群账号) | customer / subject |
| 钱包余额(PNC) | metered **entitlement**(credit 计) 的余额 |
| PNC 充值包(IAP/LS) | **credit grant**(1 年过期、优先级燃尽) |
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
调用前: edge gate(subjectId) ── 读缓存余额/entitlement ──→ 按阈值决策(见下)
调用后: edge 算 PNC 成本 → 写 outbox → 异步上报 OpenMeter usage event → 扣减 entitlement
```

- **门禁是薄的、留在 edge**:任何计费平台都不该进 LLM 的 token 热路径。edge 持一份从 OpenMeter entitlement 同步来的**缓存余额**做亚毫秒判断。
- **门禁策略 = 软 overdraft(已定)**,沿用 billing-v2 阈值:
  - `< 50 PNC`:正常调用,AI 回复尾部/会话顶部注入低额提醒(每 24h 一次)。
  - `< 5 PNC`:**节流模式** —— 强制切最便宜可用模型、关全部工具、提示充值;**允许小额透支**(余额可短暂为负)。
  - 充值入账时**优先偿还透支**(grant 先抵负余额)。
- **可靠投递用 outbox**:用量事件先落 edge 的 outbox 表,再异步推 OpenMeter,带重试 —— **不能丢可计费事件**(崩溃也留着、可重试、与请求延迟解耦)。

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

## 与现有 billing-v2 表的关系

billing-v2 **从未服役、未验证、大概率有误** → **纯绿地直接建,不做双轨并行对账**(无服役系统可对账,平行对账是伪命题)。这些表按需重用/退役,不必保旧路径:

| billing-v2 表 | 去向 |
|---|---|
| `subject_wallets`(余额事实源) | 降级为 edge **缓存**(SoR 移到 OpenMeter) |
| `billing_ledger` / `ledger_entries` | OpenMeter 即账本 → **退役**(或留薄审计) |
| `usage_events` | 改作 edge **outbox / 原始日志**,可靠投递后可裁剪 |
| `packs` | 降级为 edge 的**支付/markup 审计记录**(`sales_markup_snapshot` 留此);余额燃尽由 OpenMeter grant 接管 |
| `topups` / `refund_events` | 保留为**支付事件审计**(触发 grant 的凭据) |
| `redemption_codes` | **保留**(码库存),发额度走 OpenMeter |
| `group_billing_config` / `group_member_billing` | **保留**(专有分摊策略,第 5 层) |

## 数据 / 隐私 / 安全

- OpenMeter 只收**计量元数据**(subject id、credits、资源类型),**不发**聊天内容 / PII。
- 入账端点 internal-only,幂等防重投;webhook 验签。
- 聊天 / 账单真身仍只在 Supabase;OpenMeter 是余额/额度事实源,非内容存储。
- 核实 OpenMeter Cloud 数据区域(优先 EU,与 PostHog 一致)。

## 已拍板(2026-06-01)

- **计价单位** = **PNC(单一 credit,edge 计价)**。否决「OpenMeter 内 rating」。
- **门禁** = **软 overdraft**,沿用 billing-v2 的 50/5 PNC 阈值 + 充值优先偿还透支。
- **商品形态** = 照 billing-v2:单一现金充值包、1 年过期、markup 快照(`sales_markup_snapshot`)。
- **退役节奏** = 纯绿地,不做双轨对账(billing-v2 未服役,无从对账)。

## 开放问题(写实现计划时逐条落)

1. **群分摊优先级**:群账号钱包 vs 成员钱包的扣减先后与回退规则(billing-v2 已有 share-index 实现,核对其语义后沿用)。
2. **outbox 实现位置 + 可靠性**:落 Supabase 还是 D1?draining worker 用 CF Queue 还是 cron?重试 / 去重(幂等键)/ 死信细节。
3. **OpenMeter Cloud 上限与数据区域**:免费/低价档事件量上限、超出价格、EU 区可用性 —— 签约时核实。
4. **iOS 商品形态接入**:consumable 充值包的 RevenueCat 产品配置 + 恢复购买语义。
5. **缓存余额新鲜度**:软 overdraft 下缓存允许多旧?事件驱动刷新 + 定时兜底的窗口取值。

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
- [ ] **P6** 对账 cron + billing-v2 表退役/repoint(按「与现有 billing-v2 表的关系」一节)。
- [ ] **P7** iOS 钱包页改读新余额源。
