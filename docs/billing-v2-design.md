# PendingBot Billing v2 Design

日期：2026-05-29
状态：设计草案，待 implementation

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
- 系统内部使用高精度 PNC 原子单位，例如 `pnc_micros`
- UI 是否显示到小数点后两位由具体页面决定，不写进计费核心
- 原始供应商成本仍保留 USD 高精度字段，避免审计时丢失真实价格

成本换算：

```text
pnc_micros = vendor_cost_usd * 27 * 1_000_000
```

极小成本不能在每个事件上粗暴四舍五入，否则便宜模型和短工具调用会被系统性放大或漏计。v2 应保留高精度累计层：

- 原始事件记录 `vendor_cost_usd`
- 使用事件和钱包包余量都按 `pnc_micros` 结算
- UI 层按场景格式化，例如钱包可显示 `123.45 PNC`，审计页可显示更多位
- 不做每次事件的两位小数截断或进位

这样系统不会丢掉大量小额成本，也不会把一次极小调用硬收成 `0.01 PNC`。

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

平台利润体现在售卖 PNC 包时。例如：

```text
用户支付 10 USD
销售 markup = 2.0
发放 PNC = 10 / 2.0 * 27 = 135 PNC
```

这让运行账本和供应商账单一一对应。平台以后改价格包、促销、订阅折扣，不会污染历史使用成本。

## 4. PNC Pack

用户不是买一条抽象余额，而是买 PNC 包，类似运营商流量包。

钱包页面展示：

- 总可用 PNC
- 每个包的余量
- 每个包的名称和来源产品
- 每个包的有效期
- 每个包的消耗优先级
- 最近账单摘要

不要在每次对话完成后弹出“本次消耗多少钱”。正常产品不会把每次极小成本打到用户脸上。消耗明细只在钱包、账单详情、异常提醒、管理员审计里出现。

### Pack 字段

建议核心字段：

- `id`
- `owner_kind`: `user | subject`
- `owner_id`
- `pack_product_id`
- `initial_pnc_micros`
- `remaining_pnc_micros`
- `cash_price_usd_cents`
- `sales_markup`
- `priority_policy`
- `priority_rank`
- `expires_at`
- `created_at`
- `metadata`

### 消耗优先级

具体的消耗优先级还没定死。v2 只需要支持“每个 pack 有可配置优先级”，不要把赠送包、促销包、付费包这些产品假设写死进核心模型。

可能的策略：

- 纯按过期时间排序：`expires_at asc nulls last, created_at asc`
- 按 pack 产品配置的 `priority_rank` 排序
- 按 `priority_rank` 后再按过期时间排序
- 特定 pack 锁定只能用于特定服务分类

用户侧心智仍然是运营商流量包：用户看包余量和有效期，具体消耗顺序由产品规则决定。核心约束是包**不允许转移、不允许提现**。

## 5. 服务成本全量纳入

原则：只要服务产生可归因的变量成本，就应该进入 PNC 账本。

第一批成本分类：

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

用户滥用某个服务时，账单应直接反映该服务消耗。正常用户只会在钱包页看到余量下降，不会被每次极小消耗打扰。

## 6. 成本事件与账本

v2 不应把一个业务 turn 的所有成本塞进单列。建议拆成两层：

### Usage event

每个供应商调用或服务片段一条 usage event。

核心字段：

- `id`
- `owner_kind`: `user | subject`
- `owner_id`
- `conversation_id`
- `audit_log_id`
- `event_category`
- `provider`
- `vendor_sku`
- `model_id`
- `quantity`
- `quantity_unit`
- `vendor_cost_usd`
- `pnc_micros`
- `cost_source`: `gateway | provider | local_pricebook | manual`
- `raw_usage`
- `created_at`

### Ledger entry

钱包实际扣包时写 ledger。

核心字段：

- `id`
- `owner_kind`
- `owner_id`
- `pack_id`
- `usage_event_id`
- `entry_type`: `debit | credit | reserve | release | adjustment`
- `delta_pnc_micros`
- `balance_after_pnc_micros`
- `created_at`

一个 usage event 可以拆到多个 pack 扣减；一个业务 turn 可以包含多个 usage event。

## 7. 余额检查：reserve/settle

固定 `min_balance_threshold` 不适合 v2。便宜请求会被过度阻拦，昂贵请求又可能预估不足。

改成 reserve/settle：

1. 请求开始前按模型、max tokens、工具开关、语音时长上限估算最坏或保守成本。
2. 从用户/subject 的 packs 里冻结一笔 PNC。
3. 请求结束后按实际 usage events 结算。
4. 实际低于 reserve：释放剩余冻结额度。
5. 实际高于 reserve：允许小额 overdraft buffer，或继续扣可用 pack。
6. 如果 reserve 都无法满足：进入余额耗尽处理，不直接把“充值”打到用户脸上。

### 余额耗尽处理

模型调用路径：

- 原本要调用昂贵模型时，如果余额不足，不直接失败。
- 改调用系统配置里最便宜、最稳定的 no-balance notice 模型。
- 这个模型只生成一条自然的说明消息，告诉用户余额花完了、当前请求无法继续。
- 这条说明消息标记为 `no_balance_notice`，不按原请求模型计费；是否计入平台自担成本由运营审计决定。
- 任意“因为没余额而无法调用模型”的路径都复用这个逻辑，包括聊天、crew、工具代理、自动回复等。

非模型路径：

- 如果不是模型调用，只弹出固定文案：`余额花完了`
- 不追加充值引导、不弹复杂说明。

### 不同服务的检查方式

| 服务 | 检查策略 |
|---|---|
| 普通 LLM reply | 开始前 reserve，结束 settle |
| 带工具的 LLM reply | LLM reserve + 每次工具调用前二次 reserve |
| OpenAI server-side tools | 按启用工具加保守 buffer，结束后按 Gateway cost settle |
| 语音 / Realtime | 按时间片 reserve，余额不足就停止会话 |
| RealtimeKit group media | 按 participant-minute 分片 reserve，周期 settle |
| Sandbox/container | 启动前 reserve，运行时按秒/分钟续租 |
| 群账号 | 和个人钱包一样按 group account packs reserve/settle |

### Overdraft buffer

可以保留一个很小的系统级 overdraft buffer，目的不是赊账，而是避免流式请求因估算误差在最后几个 token 上失败。

建议：

- 只允许已登录、有正常 pack 记录的 owner 使用
- buffer 很小，例如 `0.50 PNC`
- buffer 进入 `unbilled` 或 `overdrawn` 状态
- 下次充值或获得 pack 时优先偿还
- 滥用用户直接触发更严格 reserve

## 8. 钱包体验

钱包页像运营商查流量余量：

- 顶部显示总余量：`123.45 PNC`
- 下方显示包列表：`月度包 80.00 / 100.00 PNC`、`团队包 230.12 / 500.00 PNC`
- 显示有效期和优先级提示
- 显示近 7/30 天消耗趋势
- 显示按服务分类汇总：模型、搜索、语音、沙盒、存储
- 允许进入明细页查看某天、某个会话、某类服务的成本

不在聊天完成后展示单次消耗。只有以下情况才打断用户：

- 余额不足，且当前路径不是模型路径
- 当前服务即将因余额不足中断
- 某类服务短时间异常消耗
- pack 即将过期

余额不足的非模型打断文案固定为：

```text
余额花完了
```

模型路径不弹窗，改由便宜模型生成一条消息。

## 9. Group Account Wallet

群账号和个人账号一样持有 packs，群内开销从群账号公用余额扣。

当前产品逻辑：

- 成员进入群时可以注资。
- 中途也可以继续注资。
- 群内 LLM、工具、语音、sandbox 等开销从群账号余额统一扣。
- 群账号余额不足时，停止逻辑和个人一致：模型路径走 no-balance notice，非模型路径显示 `余额花完了`。
- 不做群聊 per-message split，不把每轮费用拆给成员个人钱包。

为了避免把群账号做成余额转移工具，v2 必须限制资金流：

- 用户 pack 不允许任意转给其他用户。
- PNC 不允许提现成现金。
- 群账号余额不允许指定收款人取出。
- 如果支持“取出群内剩余额度”，只能按注资账本退回到原注资人自己的账户。

建议实现一个 group capital account ledger：

- `group_contributions` 记录每次注资人、金额、时间、来源 pack。
- 群内开销按所有未消耗注资权益比例消耗 contribution basis。
- 群余额退回时，只能按剩余 contribution basis 的比例退回。
- 退回目标只能是原注资人的个人钱包或原支付主体，不允许指定第三方。
- 已被群开销消耗掉的部分不能退。

这更接近“公司注资后按剩余权益清算”，而不是用户之间转账。具体是否要做取出功能仍需产品和合规确认；在不确定前，默认只允许注资和消费，不开放取出。

## 10. BYOK

BYOK 不进入 PendingBot PNC 账本。用户自己的 key 直接承担供应商费用，PendingBot 没有使用自己的供应商服务，就不产生 PNC usage event。

原则是：用了 PendingBot/PendingName 付费服务才记 PNC。BYOK 本身不是 PendingBot 代付服务，不记账；如果 BYOK 流程同时调用了 PendingBot 自己的服务，例如云端 sandbox、托管搜索、存储或 RealtimeKit，这些服务仍按对应 usage event 计 PNC。

## 11. 迁移方向

现有字段与 v2 的关系：

- `balance_credits` -> `wallet_total_pnc_micros` 或由 pack 汇总替代
- `cost_credits` -> `pnc_micros`
- `cost_usd` -> `vendor_cost_usd`
- `tool_cost_usd` -> 独立 `usage_events`，不再折进 parent audit 单列
- `billing_status` -> usage event 与 ledger entry 分别记录状态
- `markup` -> 从运行时配置移到 sales pack 发行记录

迁移优先级：

1. 建新表：packs、usage_events、ledger、pricebooks、group contributions。
2. Edge 写双账：保留旧 `audit_log`，同时写 v2 usage events。
3. 钱包页先读 v2 pack 余额。
4. 余额门槛改成 reserve/settle。
5. group account、voice、tools、sandbox 逐个接入 usage events。
6. 历史旧余额迁成一个 `migration` pack。
7. 验证无读旧账路径后废弃 `cost_credits` 和 runtime `markup`。

## 12. Open questions

- 是否开放群余额取出；如果开放，只能按 contribution basis 退回原注资人。
- Pack 优先级具体按过期时间、产品配置，还是混合排序。
- 某些 pack 是否限制只能用于特定服务分类，例如 sandbox/runtime。
- 是否给每个服务分类设置默认月度软上限，作为滥用提醒而非硬拦截。
