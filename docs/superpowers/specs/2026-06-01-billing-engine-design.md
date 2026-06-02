# 计费引擎设计 —— MoR(Polar)+ 预付额度

日期：2026-06-01
分支：`chore/billing-dashboard-specs`
状态：**草案,待评审**（2026-06-01 定稿引擎 = Polar;**2026-06-02 P0 spike sandbox 实测通过**）

> **✅ P0 spike 实测(2026-06-02,sandbox)**:建 meter(SUM metadata.pnc)+ customer → `grantCredits` 负值 -94_500_000 + `reportUsage` 正值 +2700 → `getStateExternal` 读到 **balance=94_497_300(整数精确,无浮点漂移)**,`consumedUnits=-94_497_300, creditedUnits=0`。证实:① 全事件符号模型成立(grant 负/usage 正 → balance 正=可用);② **iOS 外部入账可行**(对无购买的 customer 直接 grant 成功);③ 精度无忧;④ 余额刷新 ~10–12s(门禁须靠 edge 缓存)。`polar-client` 与真实返回结构吻合,无需改。

> 选型历程(留痕,免得重走):OpenMeter Cloud → 发现被 Kong 收编(免费托管没了)→ 重扫全市场 → 用户松绑两条约束(**精度不必苛求**、**"不接 Stripe"= 不直连 Stripe 而走 MoR,底层 Stripe 无妨**)→ 锁定 **Polar**。完整 MoR 版图见本轮调研:能"MoR+自带预付 credit 钱包+单人自助"的只有 {Polar, Creem, Dodo}(+未核实的 Fungies);其余要么不是 MoR、要么没钱包。
>
> 关联:[`docs/billing-v2-design.md`](../../billing-v2-design.md)(概念模型源,保留)、同分支 [`2026-06-01-dashboard-stack-design.md`](./2026-06-01-dashboard-stack-design.md)。

## 目的

用 **Polar** 一家收口计费的**收款 + 代税 + 预付额度钱包 + 用量计量**,替代未验证的 billing-v2 自研引擎,且**不直连 Stripe**:

- **web / Mac(App Store 外)**:Polar 作 **Merchant of Record**(收款 + 全球代缴税)+ **credit 钱包**(买 PNC 包 → 按用量燃尽)+ usage 计量。
- **iOS**:Apple IAP(强制)+ **RevenueCat**(收据校验/退款回流)→ 入账到 Polar 钱包。
- **edge**:把成本算成 PNC → 调 Polar 上报用量 / 读余额做门禁;**群 share-index 池自研**;留**整数影子账**兜供应商风险。

## 为什么 Polar(而非别的)

- **MoR + 自带 credit 钱包 + usage**:一家收口,省掉单独的 OpenMeter/Lago/Metronome 引擎。
- **不直连 Stripe**:Polar 底层用 Stripe,但你只对接 Polar 的 API/SDK,没有自己的 Stripe 账号/合同——满足"走 MoR、不直连 Stripe"。
- **开源**(Apache-2.0)+ 三家 credit-钱包-MoR 里**最成熟可信**;有 `customers.getStateExternal` 这个"为高频鉴权读"设计的余额端点,正好做门禁。
- Creem 更便宜(3.9% vs 5%)但最年轻、usage 弱;Dodo 功能全但有**冻结资金投诉**——钱的主干,信任度优先,故选 Polar。

## 非目标

- **不**自建计费引擎(Polar 收口);**不**自托管(Polar 是托管 MoR;其开源版自托管会失去 MoR 资格,无意义)。
- **不**直连 Stripe;**不**用 Lemon Squeezy(已被 Stripe 收购、正并入 Stripe Managed Payments,与"不直连 Stripe"长期冲突)。
- **不**绕开 Apple IAP(iOS 强制)。
- **不**追求 micros 级精度(用户已松绑):用够粗的 credit 单位即可,显示层另算。

## 决策栈总览

| 层 | 职责 | 方案 |
|---|---|---|
| 收款(web/Mac)+ 代税(MoR) | 收钱 + 全球税 | **Polar**(MoR,~5%+$0.50) |
| 收款(iOS) | App 内购 | Apple IAP + **RevenueCat**(<$2,500 MTR/月免费) |
| 计量 + 钱包 + 余额事实源 + 门禁读 | 用量→燃尽→余额→拦截 | **Polar**(meters + credits + `getStateExternal`) |
| 业务策略 | 群 share-index 池、退款/链式退款编排、阈值/节流、periodic settle | **自研(edge)** |
| 兜底事实源 | 整数影子账(防供应商锁定/冻结) | **自研(edge / Supabase)** |

## 核心建模

> 保留 billing-v2 语义:**PNC** 单位、markup 只在卖包体现(`sales_markup_snapshot`)、pack 过期、50/5 PNC 阈值、群 share-index 池、退款 3-case。换掉的只是引擎实现。

### 单位与精度(已松绑)
- **PNC** 仍是面向用户的展示单位(27 PNC=1USD,产品不变量)。
- 内部 credit 单位用够粗的整数即可(精度不苛求);edge 按真实成本算出要扣的 PNC/credit 整数,上报 Polar。Polar meter 余额是 float,但量级小、整数为主 → 实践上无碍。
- **edge 保留整数影子账**(pack 审计 + outbox),既是 reconciliation 基准,也是 Polar 出问题时的迁移底稿。

### 概念映射(Polar)

| PendingBot 概念 | Polar 原语 |
|---|---|
| 用户 / 群账户 | **Customer**,`externalId` = 我们的 subject_id |
| 钱包余额 | Customer 的 **meter balance**(`getStateExternal` 一次返回所有 active meter + 余额) |
| PNC 充值包(web/Mac) | Polar checkout 卖包 → `order.paid` webhook → edge `grantCredits`(负值事件)。**不挂 Credits Benefit**(见下「统一符号模型」) |
| PNC 充值包(iOS) | ✅ **已核实**:`events.ingest` 一条**负值**事件即给该 Customer 发 credit(Polar 官方《Grant Meter Credits Before Purchase》),无需 checkout。iOS IAP→RevenueCat→edge→负值事件 |
| 一次用量扣费 | `events.ingest` 上报 usage event,meter 燃尽余额 |
| 调用前「够不够」 | `customers.getStateExternal` 读 meter 余额(门禁) |
| 退款 | Polar 购买→Polar 退款;credit 冲销机制待核实(开放问题-2) |

## 端到端架构

### 充值入账(credit-in)
```
web/Mac:  用户在 Polar checkout 买 PNC 包 → Polar 收款+代税 → `order.paid` webhook → edge grantCredits(负值)+ 影子账
iOS:      Apple IAP → RevenueCat webhook(NON_RENEWING_PURCHASE)→ edge grantCredits(负值)+ 影子账
```
- **两条路同构**:都经 webhook → edge `grantCredits` 给同一个 Polar Customer(`externalId`=subject_id)发 credit。不用 Credits Benefit。
- **幂等**:Polar `events.ingest` 的 `external_id` 做去重(重复跳过);webhook 侧再用 RevenueCat `event.id`/`transaction_id`、Polar `order id` 兜一层。

> **统一符号模型(避 Polar 双约定坑,2026-06-01 调研)**:Polar 有两套相反约定——Credits Benefit 走 `credited−consumed`(正=可用),而原始 SUM meter 走负值发 credit;**混用不自洽**。本设计统一走**全事件模型**:不挂 Credits Benefit,**充值=负值事件、扣费/退款=正值事件**,`getStateExternal.balance` 落成正数=可用。确切符号 spike 实跑锁定。

### iOS 入账细节(RevenueCat,P1)
- `app_user_id` = 我们的 subject_id(iOS 端购买前先 `logIn(subject_id)`;webhook 兜 `original_app_user_id`/`aliases`)。
- 事件:充值 `NON_RENEWING_PURCHASE`;退款 `CANCELLATION`(cancel_reason=CUSTOMER_SUPPORT);退款撤销 `REFUND_REVERSED` 重发。
- 鉴权:RevenueCat 只有**共享密钥 Authorization 头**(无签名)→ edge 常量时间比对,密钥进 wrangler secret。
- RevenueCat **不记 consumable 余额**(Polar/影子账才是事实源);webhook 非 exactly-once、consumable 退款投递可能延迟 → **配 reconciliation 兜底**。

### 用量计量 + settle(settle-only,无 reserve)
服务成本全量纳入(billing-v2 §5,8 类:llm_tokens / server_side_tools / web_tools / voice_tokens / realtimekit_media / sandbox_runtime / storage_transfer / push_delivery)。计价来源 = AI Gateway / provider / 本地 pricebooks(先 hardcoded)。

| 服务 | settle |
|---|---|
| LLM 同步/流式 | 调用完按实际 usage 上报;流式中途不打断 |
| 带工具 LLM | 每次工具调用独立 usage event |
| 语音/Realtime | 周期 settle 15s;余额≤0 立即关会话 |
| RealtimeKit 群媒体 | 周期 settle 60s,按 participant-minute |
| Sandbox/容器 | 周期 settle 30s;余额≤0 立即终止容器 |
| 群账户 | 同套逻辑,扣**群 Customer** 余额 |

```
调用前/周期: edge 读缓存余额(源自 Polar getStateExternal)→ 按阈值决策(含杀活动会话)
settle:      edge 算 PNC → 写 outbox → 异步 events.ingest 到 Polar → meter 燃尽
```
- **门禁/settle 留 edge**:计费平台不进 LLM token 热路径;edge 持 Polar 同步来的缓存余额做亚毫秒判断 + periodic settle 调度 + 杀会话。Polar **不自动在 0 拦截**(明确文档),拦截由 edge 负责——与原设计一致,无回归。
- **outbox**:用量先落 edge 本地表(与记业务同事务),异步推 Polar,带重试,不丢可计费事件。

### 阈值与节流(4 档,沿用 billing-v2)
≥50 PNC 正常 / <50 提醒(24h 一次) / <5 节流(OpenRouter `cost_quality_tradeoff=max`、关工具) / ≤0 硬停。**Overdraft buffer = −0.5 PNC**;充值优先偿还透支。阈值写 edge config。群/个人独立(群消费默认走群账户)。

### 群账户(share-index 池,自研,产品核心)
**群消费直接扣群 Customer 余额,不在消费时按成员拆分;share-index 只在退款时算"我那份"。**
- 群 = 独立 Polar Customer;edge 保留 `group_pools(share_index)` / `group_contributions(share_index_at_join)` 簿记。
- 注资:用户钱包扣 N → 群池 += N、记 contribution → 群 Customer 加 credit。
- 群消费 X:`share_index *= (total-X)/total; total-=X`(只更新池一行)。
- 退群:`share_now = contributed*(当前 share_index / join 时)`;群池减 share_now;给该用户钱包发退款 credit;contribution 置 refunded。解散 = 对每个 active 成员各跑一次。
- 链式退款(Apple/LS 退款的钱已进群池):按 share_now 冲销,超出已花部分平台自担,记 chargeback_loss。

### 退款(3-case)
按 consumed 分:A 未消耗整笔冲销 / B 部分消耗只冲未消耗、已耗记 chargeback_loss / C 已耗尽仅改状态不扣成负。Polar 购买的退款走 Polar;credit 冲销机制见开放问题-2。`refund_risk` 标记后 web/MoR 路径限速。

### 过期 / admin / 对账
- 过期:credit 过期 → 记 breakage revenue(能否从 Polar 拿过期事件 → 开放问题-3);到期前 7d/1d 本地通知(务必做)。
- admin 赠送/调整:走 **Appsmith 控制台**(dashboard spec)→ 给 Customer 钱包加/减 credit + ledger adjustment,>100 PNC 或 ≥10 owner 二次确认,落 audit_log。
- 对账 cron:以 Polar 余额为准核对 edge 影子账 + 群池不变量,漂移告警。

## 组件与接口(edge,薄)
- `POST /v1/billing/iap/notify`(RevenueCat / Apple ASN)+ Polar webhook handler —— 验签 + 幂等入账。
- usage reporter —— 算 PNC → outbox → `polar.events.ingest`(含 periodic settle + 杀会话)。
- balance gate + 缓存同步 —— 读 `polar.customers.getStateExternal`,事件驱动 + 定时刷新缓存。
- 群池簿记 + 退款编排;redemption(兑换码→credit);admin 调整。
- 影子账 + reconciliation cron。
- Polar SDK:`@polar-sh/sdk`。

## 与 billing-v2 表的关系(纯绿地,不保旧路径)
| 表 | 去向 |
|---|---|
| `packs` | 降级为 edge 支付/markup 审计 + **影子账**;余额由 Polar credit 接管 |
| `ledger_entries`/`billing_ledger` | Polar 即账本 → 退役(或留薄审计/影子账) |
| `usage_events` | 改作 edge outbox / 原始日志 |
| `topups`/`refund_events` | 保留为支付事件审计 |
| `redemption_codes` | 保留;发额度走 Polar |
| `group_pools`/`group_contributions`/`group_billing_config`/`group_member_billing` | 保留(share-index 自研核心) |
| `pricebooks` | 保留/新建(edge 计价来源,先 hardcoded) |

## 数据 / 隐私 / 安全
- Polar 收**计量元数据 + 支付**(它是 MoR,本就持支付信息);**不发**聊天内容。
- webhook 验签;入账幂等。
- 聊天真身只在 Supabase;**余额双写**:Polar(事实源)+ edge 影子账(兜底/迁移)。

## 已拍板(2026-06-01)
- 引擎/收款/钱包 = **Polar**(MoR,不直连 Stripe);iOS = IAP + RevenueCat。
- 精度松绑;软 overdraft −0.5 PNC + 4 档阈值;商品=单一现金充值包;settle-only;纯绿地;群池自研;edge 影子账兜底。

## 开放问题(P0 spike 必须核实)
1. ✅ **已解决(2026-06-01,文档核实)**:**iOS 外部入账 → Polar 加 credit 可行**。机制 = `events.ingest` 一条**负值**事件(Polar 官方《Grant Meter Credits Before Purchase》),用 `externalCustomerId` 指定,无需 checkout → **Polar 单一钱包跨 iOS/web 成立**,不需要 edge-影子账分支。残留(spike 锁):确切符号约定 + `getStateExternal.balance` 在"benefit 发放"与"负值事件发放"混用时的语义。
2. ✅ **退款机制已明**(文档核实):无"void credit"API;退款=`reduceCredits`(正值事件)。**Polar 不在 0 处夹**,所以退款 3-case 的"只冲未消耗、不扣成负"必须 **edge 自己 `min(退款额, 可用余额)` 夹**。已落 `polar-client.reduceCredits`。
3. **过期 breakage 事件**:能否拿到 credit 过期事件记账?(全事件模型下"过期"需自己实现,spike/P6 定)
4. ✅ **余额新鲜度**(spike 实测):~**10–12 秒**才反映 ingest(最终一致,非读写即时)。→ 门禁必须靠 **edge 缓存**,Polar 余额当 reconciliation 基准。
5. ✅ **费率/去重已核实**:Starter **5%+$0.50**(2026-05-27 后新组织;+1.5% 国际卡;$15/争议);payout 经 Stripe Express(约 120 国,银行须同国;[supported-countries](https://polar.sh/docs/merchant-of-record/supported-countries));`events.ingest` 用 **`external_id` 去重**(重复跳过,返回 `duplicates` 计数)。**签约/上架前确认你的收款国家在列**。
6. RevenueCat 产品配置(consumable 充值包)+ logIn 时机(购买前)。
7. outbox 落地(Supabase vs D1;Queue vs cron;幂等键用 external_id/死信)。

## 成本
- Polar **Starter 5%+$0.50**(含 MoR+税+钱包+计量,单一费率;量上来后付费档可降到 3.4–3.8%);RevenueCat <$2,500 MTR/月免费;**无单独引擎费、无 VPS**(计费侧)。

## 分阶段 checklist
> 设计阶段,待办。
- [x] **P0** ✅ **完成(2026-06-02)**:Polar sandbox + meter + polar-spike 实测通过——闭环/符号/精度/iOS外部入账/刷新延迟全部确认(见顶部 spike 记录)。
- [ ] **P1** 入账:web/Mac Polar checkout + iOS(RevenueCat→edge→Polar 加 credit)→ 双落影子账(幂等)。
- [ ] **P2** 用量:pricebooks(hardcoded)+ 8 类 event 计价 → outbox → events.ingest。
- [ ] **P3** settle(LLM 即时 + 语音/群媒体/sandbox periodic + 余额≤0 杀会话)+ 4 档阈值 + −0.5 overdraft + 缓存同步。
- [ ] **P4** 群 share-index 池(注资/消费/退群/解散 + 不变量对账)。
- [ ] **P5** 退款 3-case + 链式退款 + chargeback_loss + refund_risk。
- [ ] **P6** 兑换码 + admin 调整(Appsmith)+ 过期 breakage + 对账 cron。
- [ ] **P7** iOS 钱包页(总余量/包列表/过期高亮/趋势/分类)读新余额源。
