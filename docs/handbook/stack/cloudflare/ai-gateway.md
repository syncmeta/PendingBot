# AI Gateway(统一计费的模型入口)

Cloudflare AI Gateway = 所有模型推理流量的统一出口 + 计费 + 日志层。大绿豆所有 LLM 调用都经它走。相关:[Edge](edge.md) · [OpenRouter(fallback)](../openrouter/openrouter.md) · [模型概念](../../shared/concepts/models.md) · [计费 subject 概念](../../shared/concepts/billing-subject.md)。

> 这块是一次"provider 策略大转向"的落点,务必按现状理解(见文末「注意」)。

**逻辑**
- **它是什么** — 一个统一的模型网关:Edge 把每一次 LLM 请求都打到 AI Gateway,由它转发给上游 provider、记一条带成本的日志、并(在 Unified Billing 模式下)代账户从 AI Gateway 额度里付上游的钱。
- **统一计费(Unified Billing)是主路径** — 走 Unified Billing 的 provider,LLM 请求**只带一个网关鉴权头**、**不带任何 provider 密钥**:上游的钱由网关从账户额度里出。worker env 和网关面板里**都不存** openai / anthropic 的 provider key。
- **少数例外走 BYOK** — 个别还没进 Unified Billing 原生通道的模型(如较新的 Gemini),骑一个存在网关里的 BYOK 密钥,用别名头选中。
- **成本读自网关日志** — 有些 provider 在响应里自报精确成本(如 OpenRouter),用它的;不自报的(如某些实时语音),计费就**从 AI Gateway 的日志里读网关算出的成本**——不在本地自己估。一次聊天回合可能是好几次 provider 调用(工具循环 / fallback),按同一个回合 id 把日志里的成本求和。
- **OpenRouter 留作 fallback** — 主路径用网关原生通道;OpenRouter 作为兜底 / 透传层留着(详见 [OpenRouter](../openrouter/openrouter.md))。

**为什么**
- **provider 策略大转向** — 早期设想自建 / 走 WorldRouter 之类,已抛弃。现在主路径走 **AI Gateway Unified Billing**:一处统一计费、统一日志、统一鉴权,不在 worker 里散落各 provider 密钥。
- **不在热路径自算成本** — 让网关当成本权威,Edge 只读它的日志求和,避免"本地估价和账单对不上"。
- **零 VPS / 外包基础设施** — 党纲商业立场:模型走 Cloudflare AI Gateway 统一计费,OpenRouter 留 fallback。

**用在哪·长什么样**
- 用户感知不到网关;它表现为"所有 bot 回复、语音、网上冲浪用的模型调用"背后那条统一出口。
- 每个请求都被打上调用上下文(按 user / 会话切片)写进网关日志,后续计费 / 审计据此对账。

**边界**
- AI Gateway **不决定**"用哪个模型"——选型走模型角色 / 预设 / bot 的 model_id(见 [模型概念](../../shared/concepts/models.md));网关只负责转发 + 计费 + 日志。
- 不是钱包 / 账本:它只产出"这次调用花了多少"的成本数;余额门禁在 [WalletDO](durable-objects.md),事实源在 Polar。

**注意 — provider 策略 & 易错点**
- ❌ **WorldRouter / 自建路由当主路径** —— 已抛弃,主路径是 AI Gateway Unified Billing。
- ⚠️ **BYOK 密钥会"劫持"Unified-Billing provider**:如果网关面板里给一个本该走 Unified Billing 的 provider 留了陈旧 BYOK 密钥,网关会优先用 BYOK 那条路;一旦该密钥的 secret 没了,就报"BYOK 凭证不可用"而失败。给 Unified Billing 的 provider 别留 BYOK 残留。
- ⚠️ **成本日志有摄入延迟**:回合刚结束时网关日志可能还查不到成本,计费消费回合会带延迟重试(见 [Edge](edge.md) 的队列化审计);别误判成"无成本"。

**现状** — 🟨 AI Gateway 作为所有 LLM 流量的统一出口已在生产路径上使用(主路径 Unified Billing + Gemini 走 BYOK + OpenRouter fallback)。计费侧(读网关成本、扣费)代码 + 单测齐,但现网**计费总开关默认关**(不拦人、不扣钱),真实扣费链路待开关打开后验证。
