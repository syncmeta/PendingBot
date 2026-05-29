# PendingBot Billing v2 Design

日期：2026-05-29（首版） / 2026-05-29 r2（本次修订）
状态：设计定稿，准备 implementation

## 1. 目标

Billing v2 要把三件事拆开：

- **使用计量**：用户实际消耗了哪些供应商服务。
- **成本结算**：这些服务按供应商价格表折成多少 PNC。
- **销售定价**：用户用现金购买 PNC 包时，平台如何 markup。

v1 的问题是这些概念混在一起：`cost_usd`、`tool_cost_usd`、`cost_credits`、`markup`、余额门槛和钱包展示都在一条路径里互相耦合。v2 的方向是让系统内部只按真实服务成本记账，利润只在卖 PNC 包时体现。

## 2. PNC

PNC = Pending Name Credits，是系统内的基础计费单位。

换算规则：

- `27 PNC = 1 USD`
- 系统内部使用高精度 PNC 原子单位 `pnc_micros`
- UI 是否显示到小数点后两位由具体页面决定，不写进计费核心
- 原始供应商成本仍保留 USD 高精度字段，避免审计时丢失真实价格

**为什么是 27 而不是 100/1000：**`27` 是故意选择的"不便心算"的比例。和游戏内货币（V-Bucks、钻石、Robux）一样的策略——让用户没法瞬间把 PNC 换算成美元，从而降低每次消费时的痛感，进而提升正常用户的使用频率。这是一个产品决策，不是技术决策；后续不要因为"不直观"而改回 100。

成本换算：

```text
pnc_micros = vendor_cost_usd * 27 * 1_000_000
```

极小成本不能在每个事件上粗暴四舍五入，否则便宜模型和短工具调用会被系统性放大或漏计。v2 应保留高精度累计层：

- 原始事件记录 `vendor_cost_usd`
- 使用事件和钱包包余量都按 `pnc_micros` 结算
- UI 层按场景格式化，例如钱包可显示 `123.45 PNC`，审计页可显示更多位
- 不做每次事件的两位小数截断或进位

## 3. Markup 只发生在销售侧

运行时不再使用 per-call markup。

错误示例：

```text
provider_cost_usd * 27 * runtime_markup
```

v2 应改为：

```text
runtime debit = provider_cost_usd * 27 PNC
```

平台利润体现在**发放 PNC 包**那一刻。Markup 数值**不写在运行时配置里**，而是写在每一笔 pack 发放记录的 `sales_markup_snapshot` 字段里——以后改促销、改套餐、改渠道分成，都不会污染历史已售包，也不会污染运行账本。

例子：

```text
用户支付 10 USD（IAP，Apple 抽 30%）
平台净到手 7 USD
销售 markup 当时定为 2.0
发放 PNC = 7 / 2.0 * 27 ≈ 94.5 PNC

记录在 pack：
  gross_paid_usd_cents = 1000
  net_revenue_usd_cents = 700
  sales_markup_snapshot = 2.0
  initial_pnc_micros = 94_500_000
```

这让运行账本和供应商账单一一对应；销售记录又完整保留了每笔的真实经济参数。

## 4. PNC Pack

用户买的是 PNC 包，类似运营商流量包。**模型刻意简化**：没有优先级、没有限定服务、没有赠包/促销包等产品分类——v2 上线时只有"现金充值包"一种，未来真有更复杂产品再加字段。

钱包页面展示：

- 总可用 PNC
- 每个包的余量、名称（默认就是 "PNC 充值包"）、有效期
- 即将过期的包高亮提醒
- 最近账单摘要

不要在每次对话完成后弹"本次消耗多少"。

### Pack 字段

```text
packs
  id
  owner_kind: user | subject       -- subject = 群账户
  owner_id
  initial_pnc_micros
  remaining_pnc_micros
  expires_at                       -- nullable，NULL 表示永不过期（长期包）
  status: active | exhausted | expired | refunded
  sales_channel: iap_ios | iap_macos | lemon_squeezy | admin_grant
                | group_topup | group_refund
  external_purchase_id             -- Apple transaction id / LS order id，唯一索引
  gross_paid_usd_cents             -- 用户实付（销售渠道发放时填）
  net_revenue_usd_cents            -- 平台净到手（扣 Apple/LS 抽成后）
  sales_markup_snapshot            -- 发放当时的 markup
  created_at
  metadata jsonb
```

### 默认过期时间

- 标准现金充值包：`expires_at = created_at + INTERVAL '1 year'`
- 长期包（高价档，未来上线）：`expires_at = NULL`
- 群退款包（用户退群时退回的）：`expires_at = created_at + INTERVAL '1 year'`，不继承原包剩余时间（简化）

### 消耗顺序

只有一条规则：**最快过期的先用**。

```sql
ORDER BY expires_at ASC NULLS LAST, created_at ASC
```

`NULL` 排到最后，自然让长期包垫底。不需要 `priority_rank`、`priority_policy` 这些抽象。

### 到期前通知

到期前 7 天和 1 天各推一次本地通知（复用 iOS 现有通道）：

```text
你的 PNC 包还剩 X PNC，将于 YYYY-MM-DD 过期
```

务必做，不然 App Store 评论会爆。

### 过期处理

后台 cron（每小时）：

```sql
UPDATE packs
SET status = 'expired'
WHERE expires_at <= now() AND remaining_pnc_micros > 0;
```

每条到期 pack 同步写一条 ledger entry：`entry_type: expired`，`delta = -remaining_pnc_micros`。

会计上：过期 PNC 对应的现金已在购买时入账，过期 = "用户主动放弃服务" → `breakage revenue`。先在 ledger 里留痕，财报口径以后定。

## 5. 服务成本全量纳入

原则：只要服务产生可归因的变量成本，就应该进入 PNC 账本。

| 分类 | 示例 | 计价来源 |
|---|---|---|
| `llm_tokens` | OpenAI / Anthropic / Gemini / OpenRouter tokens | AI Gateway cost、provider reported cost、或本地价格表 |
| `server_side_tools` | OpenAI web_search / code_interpreter / image_generation | AI Gateway 或 provider cost |
| `web_tools` | Exa / Brave / Tavily / Firecrawl / Serper | 对应 vendor pricebook |
| `voice_tokens` | OpenAI Realtime input/output/audio/cache tokens | OpenAI pricebook |
| `realtimekit_media` | RealtimeKit participant minutes | RealtimeKit pricebook |
| `sandbox_runtime` | container/runtime seconds、磁盘、网络 | Cloudflare/Sandbox pricebook |
| `storage_transfer` | 上传、下载、转码、R2 egress | Cloudflare pricebook |
| `push_delivery` | APNS 通常免费，未来短信/邮件另计 | vendor pricebook |

## 6. 成本事件与账本

两层：

### Usage event

每个供应商调用或服务片段一条 usage event。

```text
usage_events
  id
  owner_kind
  owner_id
  conversation_id
  audit_log_id
  event_category                   -- llm_tokens / web_tools / voice_tokens / ...
  provider
  vendor_sku
  model_id
  quantity
  quantity_unit                    -- tokens | minutes | calls | bytes | seconds
  vendor_cost_usd                  -- numeric(20, 8)
  pnc_micros                       -- bigint
  cost_source: gateway | provider | local_pricebook | manual
  raw_usage jsonb
  created_at
```

### Ledger entry

钱包实际扣包时写 ledger。

```text
ledger_entries
  id
  owner_kind
  owner_id
  pack_id
  usage_event_id                   -- nullable，过期/退款/admin 调整时为 NULL
  entry_type: debit | credit | release | adjustment | refund | expired
                | group_topup | group_refund | overdraft
  delta_pnc_micros
  balance_after_pnc_micros
  metadata jsonb                   -- 调整时存 admin_user_id / reason；退款时存 refund_event_id
  created_at
```

一个 usage event 可拆到多个 pack 扣减；一个业务 turn 可包含多个 usage event。

## 7. 余额检查：settle-only，无 reserve

**v2 不做 reserve/settle 状态机。** 经过权衡，pre-launch 阶段 reserve 引入的复杂度（估算函数、流式中续 reserve、worker 死亡后的 reserve 泄漏、并发竞争）远大于收益。所有路径走统一的 `settleUsage()` 函数。

### 策略

| 服务 | 策略 |
|---|---|
| LLM reply（同步/流式） | 调用完按实际 usage settle；流式中途余额跌破阈值不打断当前请求，下次请求按新阈值处理 |
| 带工具的 LLM reply | 每次工具调用是一条独立 usage event，独立 settle |
| OpenAI server-side tools | 调用结束后按 Gateway 报告的 cost settle |
| 语音 / Realtime | 周期 settle（每 15 秒结一次）；settle 后余额 ≤ 0 立即关闭会话 |
| RealtimeKit group media | 周期 settle（每 60 秒结一次），按 participant-minute |
| Sandbox / container | 周期 settle（每 30 秒），settle 后余额 ≤ 0 立即终止容器 |
| 群账号 | 和个人钱包同一套 settle 逻辑，扣群账户 packs |

### Overdraft buffer

允许账户瞬时扣到 `-0.5 PNC`，不打断当前请求。目的是兜住流式 LLM 在最后几个 token 上估算误差。

- 余额跌入 `[-0.5, 0)` 时，下次请求触发硬停（按 §7.3 阈值规则）
- 用户充值时优先偿还 overdraft
- 滥用（频繁触发 overdraft）→ 平台审计后人工处理，v2 不做自动惩罚

### 余额阈值与节流

三档阈值，作用于个人钱包总余量或群账户总余量：

| 阶段 | 阈值 | 行为 |
|---|---|---|
| 充足 | ≥ 50 PNC | 正常，不打扰 |
| 低额提醒 | < 50 PNC（≈ 1.85 USD） | 正常调用，但在 AI 回复尾部 / 会话顶部注入一行 `余额已低于 50 PNC，建议充值`；每 24h 最多提醒一次 |
| 节流模式 | < 5 PNC（≈ 0.18 USD） | 强制切到 **OpenRouter `cost_quality_tradeoff=max`**（让 OpenRouter 自动选当时最便宜的可用模型）；所有工具关闭；system prompt 注入 `用户余额已低于阈值，请简短回复并提示充值`。用户发起昂贵模型请求时，节流模型生成一条 `余额不足以调用 [model]，已为你切换到 [cheap]，建议充值` |
| 硬停 | ≤ 0 PNC | 模型路径：no-balance notice 模型说一句 `余额花完了`，每 24h 最多触发 3 次，超出退化为纯文本同样文案。非模型路径：直接固定文案 `余额花完了` |

阈值数字写在 edge config（不进 DB），方便临时调。OpenRouter 路由参数 `cost_quality_tradeoff=max` 由 LLM router 在节流模式下传给 OpenRouter，不在代码里硬编码具体模型 id。

群账户的阈值检查独立于成员个人钱包：群账户余额低 → 群内开销走节流；个人余额低 → 个人开销走节流。

## 8. 钱包体验

钱包页像运营商查流量余量：

- 顶部显示总余量：`123.45 PNC`
- 下方显示包列表：`充值包 80.00 / 100.00 PNC（2027-05-29 过期）`
- 即将过期的包高亮
- 显示近 7/30 天消耗趋势
- 显示按服务分类汇总：模型、搜索、语音、沙盒、存储
- 进入明细页查看某天、某个会话、某类服务的成本

不在聊天完成后展示单次消耗。打断用户只在这几种情况：

- 余额跌入节流（注入提醒）
- 余额耗尽（硬停文案）
- 当前服务即将因余额不足中断（voice / sandbox 周期 settle 触发）
- pack 即将过期（7 天 / 1 天）

## 9. 群账户（Group Wallet）—— 产品核心

群账户是 PendingBot 的核心协作场景，不是销售手段。v2 必须支持：

1. 任意群成员注资
2. 任意群成员查看群余额与近期消耗
3. 群内所有 LLM / 工具 / 语音 / sandbox 开销自动从群账户扣
4. 群账户余额不足时，群内消费走节流（§7）
5. **用户退群时按比例退回未消耗部分到自己钱包**
6. 用户解散群时按比例退回所有 active 成员

不支持（v2 不做）：

- 群账户提现成现金
- 注资人指定第三方接收退款
- 任意"群内转账"

### Share Index 模型

为了既支持退款又不在每次消费时 update N 行 contribution，用 share index（DeFi staking 池标准模型）：

```text
group_pools
  subject_id                       -- 群 id（一群一行）
  total_remaining_pnc_micros       -- 群当前可用余额（事实源）
  share_index numeric(40, 20)      -- 单调缩减的份额因子，初始 1.0
  updated_at

group_contributions
  id
  subject_id
  contributor_user_id
  contributed_pnc_micros           -- 注资时的 PNC 数量
  share_index_at_join              -- 注资当时的 share_index 快照
  status: active | refunded
  source_pack_id                   -- 资金来源 pack（如果是从钱包转入；直接 IAP 充群账户则 NULL）
  created_at
  refunded_at
```

### 三种操作

**注资（user → group）：**

```text
1. 从 user 钱包按 §4 顺序扣 N PNC（生成 ledger entry: group_topup, delta=-N）
2. group_pools.total_remaining += N
3. INSERT group_contribution { contributed: N, share_index_at_join: pools.share_index }
4. 生成群账户 pack: sales_channel=group_topup, initial=N, 1 年过期
   （群账户的 pack 是为了让群 wallet 的扣账路径和个人完全一致；
    退款逻辑仍走 share index，不直接动这个 pack）
```

**群消费 X PNC：**

```text
new_total = total_remaining - X
pools.share_index *= new_total / total_remaining
pools.total_remaining = new_total
```

`share_index` 按比例缩减，所有 active contribution 的"我那份"自然按比例缩水，不需要 update N 行。

**用户 Alice 退群退款：**

```text
1. 找到 Alice 在此群的所有 active contributions
2. 对每条计算 share_now = contributed * (pools.share_index / share_index_at_join)
3. alice_total = SUM(share_now)
4. pools.total_remaining -= alice_total
   pools.share_index 保持不变（池子小了，剩下人的份占比上升）
5. 在 Alice 个人钱包发一个 pack:
     sales_channel = group_refund
     initial_pnc_micros = alice_total
     expires_at = now() + 1 year
6. 所有相关 contribution 置 refunded
```

**群解散：** 对所有 active 成员各执行一次"退群退款"，直到 `pools.total_remaining ≈ 0`。

### 不变量

```text
SUM over active contributions of (contributed * pools.share_index / share_index_at_join)
  ≈ pools.total_remaining
```

定期跑 reconciliation job 校验，偏差超过 `1 PNC` 报警（浮点累计误差）。

### 公平性

- 早注资的人在群里待得久 → 被消费按比例分摊得多 → 退款时剩得少
- 晚注资的人 share_index_at_join 是当下值 → 不沾历史消耗 → 不薅老成员羊毛
- 群消费的钱来自所有 active contribution 的"共池"，符合用户对"群基金"的直觉

### Apple/LS 链式退款

如果 Alice 的某笔 IAP 后续被 Apple 退款，且这笔钱已经进过群账户：

1. 先按 Apple 退款金额对应的 PNC 反查到 Alice 的 contribution
2. 计算 `share_now`（这笔贡献当前还剩多少）
3. 群账户冲销 `share_now`（按 share index 模型扣回）
4. 把这部分冲销给 Apple（即对应的 pack 作废 / 部分作废）
5. 超出 `share_now` 的部分（已经被群里花掉了）→ **平台自担，不向其他成员追讨**
6. 记 `chargeback_loss` 审计，超频用户标记 `refund_risk = true`

## 10. 销售渠道与退款

### Sales channels

v2 launch 时支持两条收款路径：

| Channel | 适用 | 抽成 | 处理路径 |
|---|---|---|---|
| `iap_ios` | iOS App | Apple 30% | StoreKit 2 → edge webhook → 验签 → 发 pack |
| `iap_macos` | Mac App Store 内 | Apple 30% | 同 iOS |
| `lemon_squeezy` | Mac 端 App Store 外、Web | LS 5% + 支付通道费 | LS webhook → 验签 → 发 pack |
| `admin_grant` | 客服赠送 | 0 | Board → admin RPC |
| `group_topup` | 用户钱包 → 群账户 | 0 | edge 内部转账 |
| `group_refund` | 退群退款 → 用户钱包 | 0 | edge 内部转账 |

Edge 提供两个 webhook 端点：

- `POST /v1/billing/iap/notify`：Apple App Store Server Notifications V2
- `POST /v1/billing/lemonsqueezy/webhook`：LS webhook

各自验签后用 `external_purchase_id` 唯一索引去重，幂等发 pack。

具体 markup 数值（每个 channel 各自的）等真正上架前在 Board 配置，**写入每个 pack 的 `sales_markup_snapshot`，不在运行时引用全局 markup 配置**。

### 退款处理

监听两个退款源：

- Apple ASN V2 的 `REFUND` / `REFUND_DECLINED` / `REVOKE` 通知
- LS webhook 的 `order_refunded`

退款流程（个人钱包 pack）：

```text
1. 收到退款通知 → 写 refund_events 表
2. 通过 external_purchase_id 反查原 pack
3. consumed = SUM(ledger.delta where pack_id = X and entry_type in (debit, expired))
4. 三种情况：
   case A: consumed = 0（未消耗）
     → 整笔作废，pack.status = refunded，pack.remaining = 0
     → 写 ledger refund 条目
   case B: 0 < consumed < initial（部分消耗）
     → 作废剩余部分（remaining → 0, status = refunded）
     → 已消耗部分不追讨（成本已发生，追讨用户体验毁灭性差）
     → 写 ledger refund 条目 + chargeback_loss 审计
   case C: consumed >= initial（已用完）
     → 整笔标记 refunded（仅状态变更）
     → 不向用户追讨负余额
     → 全额计 chargeback_loss
5. 用户标记 refund_count++，超阈值 → 标记 refund_risk = true
   → 后续 IAP 仍允许，Web/LS 路径限速或要求人工审批
```

退款进过群账户的情况见 §9 链式退款。

`refund_events` 表：

```text
refund_events
  id
  source: apple | lemon_squeezy | manual
  external_refund_id
  pack_id
  refund_amount_usd_cents
  consumed_pnc_micros_at_refund
  chargeback_loss_pnc_micros
  created_at
  raw_payload jsonb
```

## 11. BYOK

BYOK 不进入 PendingBot PNC 账本。用户自己的 key 直接承担供应商费用，PendingBot 没有使用自己的供应商服务，就不产生 PNC usage event。

原则：用了 PendingBot/PendingName 付费服务才记 PNC。BYOK 本身不是 PendingBot 代付服务，不记账；如果 BYOK 流程同时调用了 PendingBot 自己的服务（云端 sandbox、托管搜索、存储、RealtimeKit），这些服务仍按对应 usage event 计 PNC。

## 12. 管理员操作

所有 admin 调整走 Board UI，落地为 ledger `entry_type: adjustment`。必填字段：

```text
metadata: {
  admin_user_id
  reason             -- 必填自由文本
  ticket_ref         -- 可选客服工单号
}
```

金额阈值（任一满足则触发二次确认）：

- 单次 `|delta_pnc_micros|` > 100 PNC
- 单次操作影响 ≥ 10 个 owner

二次确认走 Board 上的二次输入（重新输入金额 / 工单号匹配）；不需要双人审核（暂时单人开发，留接口未来扩）。

全部进 `audit_log` + Slack/邮件通知（如果配置了）。

## 13. 表结构总览

```text
packs                   -- §4
usage_events            -- §6
ledger_entries          -- §6
group_pools             -- §9
group_contributions     -- §9
refund_events           -- §10
pricebooks              -- vendor 价格表（独立 migration）
```

pricebooks 设计独立成段，下一稿补；先用 hardcoded constants 起步，跑通主路径后再做。

## 14. 迁移方向（pre-launch 简化版）

我们 pre-launch、单人单环境（参考 [[project_pre_launch_single_env]]），所以不需要 v1↔v2 双写过渡，直接切：

1. 建新表（§13）。
2. 旧 `audit_log` 中尚未结算的部分（如果有）一次性 ETL 进 `usage_events` 和 `ledger_entries`；存量极少，可手工脚本。
3. 历史钱包余额 → 每个用户发一个 `sales_channel=admin_grant` 的 pack（`expires_at=NULL`，给老用户做迁移红利）。
4. 钱包页改读新表。
5. Edge 所有路径切到 `settleUsage()`，删 v1 的 `cost_credits` / runtime `markup` 配置。
6. 群账户接入 group_pools / contributions。
7. 删 v1 表（保留一次性备份）。

旧字段对照：

- `balance_credits` → 由 `packs.remaining_pnc_micros` 汇总
- `cost_credits` → `pnc_micros`
- `cost_usd` → `vendor_cost_usd`
- `tool_cost_usd` → 独立 `usage_events`，不再折进 parent audit 单列
- `billing_status` → 由 `usage_events` 和 `ledger_entries` 状态共同表达
- `markup`（runtime 配置）→ `packs.sales_markup_snapshot`（per-pack 快照）

## 15. Open questions（剩下的）

- Pricebook 表结构（按 vendor × sku × effective_at 还是按 model_id × period？）
- 每类服务月度软上限是否需要做（异常消耗主动提醒，不阻断）
- 节流模式下，群账户和个人账户余额检查冲突时谁优先（群优先 = 群成员不会因为个人余额低被节流；个人优先 = 个人余额高的成员可以"垫付"群内消费？v2 默认走群账户，个人余额只管个人消费，避免歧义）
