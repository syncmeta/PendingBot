# 计费 P0：Polar 集成地基 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 或 superpowers:executing-plans。步骤用 `- [ ]` 跟踪。

**Goal:** 在 edge 建立 Polar 薄封装与 PNC 换算,并用真实 spike 验证 ①"上报用量→meter 燃尽→读余额"闭环、②**头号开放问题:iOS 外部入账能否给 Polar 钱包加 credit**。

**Architecture:** Polar 作 MoR + 预付 credit 钱包 + usage 计量(`@polar-sh/sdk`)。Customer 以 `externalId = subject_id` 标识;用量 `events.ingest`,余额 `customers.getStateExternal`,门禁在 edge 缓存余额上做。不直连 Stripe;iOS 仍 IAP+RevenueCat。详见 [`../specs/2026-06-01-billing-engine-design.md`](../specs/2026-06-01-billing-engine-design.md)。

**Tech Stack:** Cloudflare Workers + Hono + TS,vitest,`@polar-sh/sdk` 0.47.x,bun。

> **范围**:本计划 = spec 的 **P0(地基 + spike)**。P1–P7(入账/用量+outbox/settle+门禁/群池/退款/admin/iOS钱包)各自成计划,依赖 P0 锁定的 Polar payload + open-question-1 结论。

---

## 已完成(本 session 内联执行,3 commit,8 测试绿,typecheck 绿)

- [x] **T1**:`@polar-sh/sdk` 依赖 + Env `POLAR_ACCESS_TOKEN`/`POLAR_SERVER`(`apps/edge/package.json`、`src/types.ts`)。
- [x] **T2**:PNC 换算 `apps/edge/src/billing/pnc.ts`(+ test,4 过)。27 PNC=1USD,整数 micros(精度已松绑,够粗即可)。
- [x] **T3**:Polar 薄封装 `apps/edge/src/billing/polar-client.ts`(+ test,4 过):`reportUsage`(events.ingest)、`getBalance`(customers.getStateExternal 取我们 meter)。结构化 Sdk 类型解耦;`polarFromEnv` 用 Env 构造,typecheck 证实 `new Polar({accessToken,server})` 成立。

> 注:引擎从 OpenMeter 换 Polar 时,`pnc.ts` + 测试结构原样保留,只重写了 client ——接缝兑现。

---

## 前置(人工,非代码)

- [ ] **P-1:Polar 账号 + sandbox 配置**
  - 注册 Polar,进 **sandbox**,拿 **access token**(设 `apps/edge/.dev.vars` 的 `POLAR_ACCESS_TOKEN` + `POLAR_SERVER=sandbox`;生产 `wrangler secret put POLAR_ACCESS_TOKEN`)。
  - 建一个 **meter** `pnc`:按 event name `pnc.usage` 聚合 `metadata.pnc`(SUM)→ 记下 `meterId`。
  - 建一个带 **Credits Benefit** 的产品(用于 web/Mac 买 PNC 包发 credit)。
  - 核实费率(~5%+$0.50 当前值)+ Stripe Express 是否支持你的收款国家(spec 开放问题-5)。

---

### Task P0-A:Spike —— 验闭环 + 头号开放问题

**Files:** 已就绪 `apps/edge/scripts/polar-spike.ts`;`package.json` 有 `polar:spike`。

- [ ] **Step 1:在 Polar 给一个测试 Customer 充 credit**
  - 关键验证(spec 开放问题-1):iOS 充值**不走 Polar checkout**,看 Polar 是否提供"**外部手动授予 credit** 的 API/后台"。
    - 路径 a:经带 Credits Benefit 的产品做一笔 sandbox 测试购买 → 自动发 credit(web/Mac 路径,确定可行)。
    - 路径 b:查 Polar 是否有"直接给 Customer meter 加 credit / 负向 usage 事件冲抵"的手段(给 IAP 入账用)。**这是必须有结论的点。**
  - 记下该 Customer 的 `externalId`、`meterId`。

- [ ] **Step 2:跑 spike**

Run:
```bash
cd apps/edge && POLAR_ACCESS_TOKEN=<token> POLAR_SERVER=sandbox \
  SPIKE_METER_ID=<meterId> SPIKE_EXTERNAL_ID=<customer externalId> bun run polar:spike
```
Expected: 打印 balance before → ingest 2700 → 轮询 balance 下降 ~2700 → `✅ 精确燃尽 2700`(float 微差可接受,精度已松绑)。

- [ ] **Step 3:处理结果(回填 spec)**
  - ✅ 闭环通 + open-question-1 路径 b 可行 → **Polar 单一钱包跨 iOS/web 成立**,选型最终敲定,开 P1。
  - ⚠️ 闭环通但 **open-question-1 路径 b 不可行**(Polar 不支持外部加 credit)→ 决策:**iOS 钱包以 edge 影子账为事实源、Polar 只覆盖 web/Mac**;回填 spec 架构,再开 P1。
  - ❌ 闭环不通/报错(payload 字段不符)→ 按报错修 `polar-client.ts` 的 events.ingest / getStateExternal 形状(spike 本就是锁 payload),重跑。

- [ ] **Step 4:commit**
```bash
git add apps/edge/scripts/polar-spike.ts docs/superpowers/specs/2026-06-01-billing-engine-design.md
git commit -m "chore(billing): polar spike 验收 + 回填 open-question-1 结论"
```

---

## Self-Review
- **覆盖**:P0 = 地基(T1–3 已完成)+ Polar setup(P-1)+ spike(P0-A)。P1–P7 留后续计划。
- **占位符**:无;spike 的 "按报错修字段" 是锁 payload 的本职。
- **类型一致**:`reportUsage`/`getBalance`/`createPolarClient`/`polarFromEnv`/`PNC_EVENT_NAME`/`PNC_METADATA_KEY` 在 T3 定义,spike 引用一致。
- **已知风险(P0 验收点)**:open-question-1(iOS 外部加 credit)是选型成立的关键;events.ingest / getStateExternal 的确切 payload 由 spike 锁定。
