# Polar(钱包本体 / MoR)

Polar = 大绿豆**计费引擎的事实源**:收款 + 全球代税(Merchant of Record)+ 预付额度钱包 + 用量计量,一家收口。相关:[钱包与 PNC](../../shared/concepts/wallet-pnc.md) · [责任主体计费](../../shared/concepts/billing-subject.md) · [RevenueCat(iOS 入账)](../revenuecat/revenuecat.md) · [群分摊与认缴](../../shared/concepts/group-pledge.md) · [WalletDO 边缘门禁](../cloudflare/durable-objects.md)。

> 这块是一次"计费引擎大转向"的落点(自研引擎 → 外包 Polar),务必按现状理解,别照旧 spec 写回(见文末「注意」)。

**逻辑 — 它在系统里扮演什么**

- **钱包余额的事实源** — 每个计费主体(个人 / 群)在 Polar 里是一个 Customer,`externalId` = 我们的 subject_id。它的"还剩多少 PNC"以 Polar 的 meter 余额为准,边缘只是缓存。
- **MoR(代收 + 代税)** — web / Mac(App Store 外)的充值经 Polar 结账,Polar 作记录商收钱、全球代缴税。我们不持自己的 Stripe 账号 / 合同(Polar 底层用 Stripe,但只对接 Polar)。
- **充值入账(credit-in)走 webhook** — 用户付款后,Polar 发 webhook 到 edge,edge 给对应 Customer 钱包发 credit + 记一笔影子账。**送 / 兑换码也走这条同一通道**:都收敛成"给某个 Customer 钱包加 credit",不另起一套。
- **iOS 入账同构** — iOS 的 Apple 内购经 [RevenueCat](../revenuecat/revenuecat.md) 回流,最终也是 edge 给同一个 Polar Customer 钱包发 credit——**单一钱包跨 iOS / web**,不为两条支付路各起一个余额。
- **用量燃尽 + 门禁读** — 每次消费 edge 把成本算成 PNC 上报 Polar,meter 燃尽余额;调用前 / 周期性 edge 读余额做门禁(但因 Polar 余额有约 10 秒级延迟,实际门禁靠 [边缘缓存](../cloudflare/durable-objects.md),Polar 当对账基准)。

**为什么 — 关键取舍**

- **一家收口,省掉自研引擎** — MoR + 自带 credit 钱包 + usage 计量集于一身,不必再单独养 OpenMeter / Lago 之类的计量引擎,也不自建结算逻辑(未验证的 billing-v2 自研引擎被它替换)。
- **走 MoR 但不直连 Stripe** — 党纲商业立场:计费外包、不直连 Stripe。Polar 满足"走记录商、底层 Stripe 无妨,但我们不开自己的 Stripe 户"。
- **信任度优先选 Polar** — 在能"MoR + 自带预付钱包 + 单人自助"的少数家里,Polar 最成熟、开源(Apache-2.0)、且有专为高频鉴权读设计的余额端点;比它便宜的更年轻 / 计量弱,功能更全的有冻结资金投诉——钱的主干,信任度压倒费率。

**用在哪·长什么样**

- 用户感知到的是:web / Mac 上买 PNC 充值包时跳 Polar 结账页;买完钱包到账。背后的"记录商 / 代税 / 钱包"用户不直接看见。
- 运营侧:Polar 自带计费视图(支付 / 退款流水);admin 给钱包发 / 减 credit 的调整经 [board / 控制台](../../shared/concepts/config-as-cms.md) → edge,落审计。

**示例** — 你在 Mac 上点"充值",跳到 Polar 结账买一个 PNC 包。付款成功 → Polar 收款代税 → 发 `order.paid` webhook → edge 给你这个 Customer 钱包发 credit,同时记一笔影子账。之后你和 bot 聊天,每回合的模型成本被算成 PNC 上报 Polar、燃尽余额;余额掉到阈值以下时 edge 据缓存余额降级 / 拦截。

**边界 — 明确不做什么**

- **不进 LLM 热路径** — Polar 不在每次模型调用上同步扣费拦人;门禁判断在边缘缓存,Polar 只收用量事件 + 当余额事实源。Polar 自己**不在 0 处自动拦截**,拦不拦由 edge 负责。
- **不收聊天内容** — Polar 拿到的是计量元数据 + 支付信息(它本就是记录商),**不发**任何对话 / prompt 文本。
- **群分摊不外包** — 群账户的 share-index 池(注资 / 消费衰减 / 退群结算 / 链式退款)是自研核心,Polar 只持"群这个 Customer 的余额",怎么分是 edge 的事(见 [群分摊](../../shared/concepts/group-pledge.md))。
- **不追求 micros 级精度** — 用够粗的整数 credit 即可,显示层另算;精度约束已被用户主动松绑。

**注意 — 坑 / 已变更的决策**

- ❌ **billing-v2 自研结算引擎 / 本地账本当事实源** —— 已改为外包 Polar;本地只留**整数影子账**做对账基准 + 供应商风险兜底,不再是余额真源。
- ❌ **Lemon Squeezy / 旧 IAP 计费** —— 已弃(Lemon 被 Stripe 收购,与"不直连 Stripe"长期冲突)。
- ⚠️ **统一符号模型,别混用两套约定** — Polar 有"Credits Benefit(正=可用)"和"原始 meter 负值发 credit"两套相反约定,混用不自洽。本设计统一走**全事件模型**:不挂 Credits Benefit,充值=负值事件、扣费 / 退款=正值事件,余额落成正数=可用。
- ⚠️ **入账必须幂等** — webhook 可能重投;靠 Polar 事件的 `external_id` 去重 + webhook 侧再用支付订单 id 兜一层,防止重复加额度。
- ⚠️ **余额是最终一致(约 10–12 秒)** — 上报后不立即反映,所以门禁不能直接读 Polar,必须靠边缘缓存;Polar 余额仅作 reconciliation 基准。
- ⚠️ **退款不会扣成负** — Polar 无"作废 credit"API,退款=正值事件冲销;"只冲未消耗、不扣成负"必须 edge 自己夹。
- ⚠️ **签约 / 上架前确认收款国家在 Polar 支持列表**(payout 经 Stripe Express,约 120 国)。

**现状** — 🟨 引擎 / 钱包封装(pnc / polar-client / billing-polar / wallet-client)+ Polar / RevenueCat 入账 webhook + 群池自研,代码 + 单测齐;**P0/P1 资金流已在 Polar sandbox 直连实测通过**(充值去重不翻倍 / 扣费 / 退款 / 余额 / `external_id` 幂等全对,见 `apps/edge/scripts/polar-verify.ts`)。但现网**计费总开关默认关**(不拦人、不扣钱),生产真实端到端(填真 product_id + 配 webhook + 翻开开关 + 真支付到账)未验。证据见 [`docs/superpowers/specs/2026-06-01-billing-engine-design.md`](../../../superpowers/specs/2026-06-01-billing-engine-design.md) 顶部 spike 记录 + [`docs/progress.md`](../../../progress.md) §4b。
