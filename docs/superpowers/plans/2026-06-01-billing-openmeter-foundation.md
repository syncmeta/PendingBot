# 计费 P0：OpenMeter 集成地基 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 edge 建立 OpenMeter 的薄封装与 PNC 单位换算,并用一次真实 spike 验证「整数 pnc_micros 收/扣/查余额」端到端精确,锁定真实 API payload。

**Architecture:** OpenMeter 用 `entitlementsV1`(subject 维度,subject=用户/群账号)。edge 把成本先换算成整数 `pnc_micros` 再上报,平台只做 SUM/减;一个 metered feature `pnc` + 每 subject 一个 metered entitlement,充值/赠送=credit grant,扣费=ingest usage event,门禁读 entitlement value 的 `balance`。本计划只做地基(client 封装 + 单位换算 + bootstrap + spike 验证),不含 webhook/settle/群池/退款——那些是后续独立计划,依赖本计划锁定的 payload。

**Tech Stack:** Cloudflare Workers + Hono + TypeScript,vitest 测试,`@openmeter/sdk`(fetch-based JS SDK),bun。

> **范围说明(writing-plans 范围检查)**：计费 spec([`../specs/2026-06-01-billing-engine-design.md`](../specs/2026-06-01-billing-engine-design.md))是多子系统。本计划 = spec 的 **P0**。后续各自成计划:P1 入账 webhook、P2 用量计量+outbox、P3 settle+门禁、P4 群 share-index 池、P5 退款/链式退款、P6 兑换码+admin+对账、P7 iOS 钱包页。**每份后续计划都以本计划锁定的 `om-client.ts` 接口与 spike 发现为前提。**

---

## 前置(人工,非代码)

- [ ] **P-1: 注册 OpenMeter Cloud + 拿 API key + 核实区域/上限**
  - 注册 OpenMeter Cloud,创建一个 organization。
  - 记录 `baseUrl`(Cloud 默认 `https://openmeter.cloud`)与 API key。
  - 核实:数据区域是否可选 EU(与 PostHog 一致);免费/低价档的月事件量上限与超出价(记进 spec §开放问题-3)。
  - 把 API key 设为 edge secret(见 Task 1)。**不要**提交到仓库。

## 文件结构

- Create: `apps/edge/src/billing/pnc.ts` —— PNC↔USD↔micros 纯换算 + 常量。
- Create: `apps/edge/src/billing/pnc.test.ts` —— 换算单测。
- Create: `apps/edge/src/billing/om-client.ts` —— OpenMeter 薄封装(我们需要的领域操作)。
- Create: `apps/edge/src/billing/om-client.test.ts` —— 封装的本地逻辑单测(mock SDK)。
- Create: `apps/edge/scripts/om-bootstrap.ts` —— 一次性创建 meter `pnc` + feature `pnc`。
- Create: `apps/edge/scripts/om-spike.ts` —— 真实 spike:建 subject/entitlement → grant → ingest → 读 balance,断言整数精确。
- Modify: `apps/edge/src/types.ts` —— `Env` 加 `OPENMETER_API_KEY`、`OPENMETER_BASE_URL`。
- Modify: `apps/edge/package.json` —— 加 `@openmeter/sdk` 依赖 + 两个脚本。

---

### Task 1: 依赖与 Env 接线

**Files:**
- Modify: `apps/edge/package.json`
- Modify: `apps/edge/src/types.ts`

- [ ] **Step 1: 装 SDK**

Run（在仓库根）:
```bash
bun add --cwd apps/edge @openmeter/sdk
```
Expected: `apps/edge/package.json` 的 dependencies 出现 `@openmeter/sdk`。

- [ ] **Step 2: Env 加两个字段**

在 `apps/edge/src/types.ts` 的 `Env` 接口里加(放在其它 secret 旁):
```ts
  OPENMETER_API_KEY: string
  OPENMETER_BASE_URL: string // e.g. https://openmeter.cloud
```

- [ ] **Step 3: 设 secret + 本地 .dev.vars**

Run:
```bash
cd apps/edge && echo "OPENMETER_BASE_URL=https://openmeter.cloud" >> .dev.vars
# 本地：把 OPENMETER_API_KEY=... 也写进 .dev.vars（.dev.vars 已 gitignore）
# 生产：bun --filter='@pendingbot/edge' run wrangler secret put OPENMETER_API_KEY
```
Expected: `.dev.vars` 含两行;`wrangler secret list` 之后能看到 `OPENMETER_API_KEY`(生产步骤可在部署前再做)。

- [ ] **Step 4: typecheck**

Run:
```bash
bun --filter='@pendingbot/edge' run typecheck
```
Expected: PASS（仅类型变更,无引用即不会报未用）。

- [ ] **Step 5: commit**

```bash
git add apps/edge/package.json apps/edge/src/types.ts bun.lock
git commit -m "chore(billing): add @openmeter/sdk dep + OPENMETER_* env"
```

---

### Task 2: PNC 单位换算(TDD,纯逻辑)

**核心不变量(来自 billing-v2-design.md §2)**：`27 PNC = 1 USD`;内部用整数 `pnc_micros`,`1 PNC = 1_000_000 micros`;`pnc_micros = round(vendor_cost_usd * 27 * 1_000_000)`。**只在最终换算这一步取整,且用 `Math.round`**(spec 禁止每事件粗暴截断;round 比 floor 更不偏)。

**Files:**
- Create: `apps/edge/src/billing/pnc.ts`
- Test: `apps/edge/src/billing/pnc.test.ts`

- [ ] **Step 1: 写失败测试**

```ts
// apps/edge/src/billing/pnc.test.ts
import { describe, expect, it } from 'vitest'
import { PNC_PER_USD, MICROS_PER_PNC, usdToPncMicros, pncMicrosToPnc } from './pnc'

describe('pnc', () => {
  it('exposes the product-fixed ratio', () => {
    expect(PNC_PER_USD).toBe(27)
    expect(MICROS_PER_PNC).toBe(1_000_000)
  })

  it('converts vendor USD cost to integer pnc_micros', () => {
    // $1 -> 27 PNC -> 27_000_000 micros
    expect(usdToPncMicros(1)).toBe(27_000_000)
    // cheap call $0.0001 -> 0.0027 PNC -> 2700 micros
    expect(usdToPncMicros(0.0001)).toBe(2700)
  })

  it('always returns an integer (no fractional micros)', () => {
    const v = usdToPncMicros(0.000033333)
    expect(Number.isInteger(v)).toBe(true)
  })

  it('formats micros back to PNC for display', () => {
    expect(pncMicrosToPnc(94_500_000)).toBeCloseTo(94.5, 6)
  })
})
```

- [ ] **Step 2: 跑测试确认失败**

Run:
```bash
cd apps/edge && ./node_modules/.bin/vitest run src/billing/pnc.test.ts
```
Expected: FAIL（`./pnc` 模块不存在）。

- [ ] **Step 3: 写最小实现**

```ts
// apps/edge/src/billing/pnc.ts
// Pending Name Credits 单位换算。见 docs/billing-v2-design.md §2。
// 产品不变量：27 PNC = 1 USD（故意不整除，防心算）。内部整数 micros。
export const PNC_PER_USD = 27
export const MICROS_PER_PNC = 1_000_000

/** 供应商真实成本(USD) → 整数 pnc_micros。只在此处取整。 */
export function usdToPncMicros(vendorCostUsd: number): number {
  return Math.round(vendorCostUsd * PNC_PER_USD * MICROS_PER_PNC)
}

/** pnc_micros → PNC(仅供 UI/日志展示,不参与账本运算)。 */
export function pncMicrosToPnc(micros: number): number {
  return micros / MICROS_PER_PNC
}
```

- [ ] **Step 4: 跑测试确认通过**

Run:
```bash
cd apps/edge && ./node_modules/.bin/vitest run src/billing/pnc.test.ts
```
Expected: PASS（4 个用例）。

- [ ] **Step 5: commit**

```bash
git add apps/edge/src/billing/pnc.ts apps/edge/src/billing/pnc.test.ts
git commit -m "feat(billing): PNC<->micros 换算 + 不变量测试"
```

---

### Task 3: OpenMeter 薄封装 + 幂等键(TDD 本地逻辑 + mock)

封装只暴露我们要的领域操作,统一固定 `pnc` feature/meter key,并保证 grant 的**幂等**(同一 provider 交易 id 不重复加额度——grant 用确定性 id)。SDK 真实方法(已核实):`subjects.upsert`、`entitlementsV1.create`、`entitlementsV1.value`、`entitlementsV1.grants.create`、`entitlementsV1.grants.void`、`events.ingest`。

**Files:**
- Create: `apps/edge/src/billing/om-client.ts`
- Test: `apps/edge/src/billing/om-client.test.ts`

- [ ] **Step 1: 写失败测试(mock SDK,验我们自己的逻辑)**

```ts
// apps/edge/src/billing/om-client.test.ts
import { describe, expect, it, vi } from 'vitest'
import { createOmClient, PNC_FEATURE_KEY, grantIdFor } from './om-client'

function fakeSdk() {
  return {
    subjects: { upsert: vi.fn().mockResolvedValue([{ key: 's1' }]) },
    entitlementsV1: {
      create: vi.fn().mockResolvedValue({ id: 'ent_1' }),
      value: vi.fn().mockResolvedValue({ hasAccess: true, balance: 94_497_300, usage: 2700, overage: 0 }),
      grants: {
        create: vi.fn().mockResolvedValue({ id: 'grant_1' }),
        void: vi.fn().mockResolvedValue(undefined),
      },
    },
    events: { ingest: vi.fn().mockResolvedValue(undefined) },
  }
}

describe('om-client', () => {
  it('uses the fixed pnc feature key', () => {
    expect(PNC_FEATURE_KEY).toBe('pnc')
  })

  it('builds a deterministic grant id from external purchase id (idempotency)', () => {
    expect(grantIdFor('iap_ios', 'txn_abc')).toBe(grantIdFor('iap_ios', 'txn_abc'))
    expect(grantIdFor('iap_ios', 'txn_abc')).not.toBe(grantIdFor('lemon_squeezy', 'txn_abc'))
  })

  it('getBalance returns integer micros from entitlement value', async () => {
    const om = createOmClient(fakeSdk() as any)
    const bal = await om.getBalance('s1')
    expect(bal).toBe(94_497_300)
    expect(Number.isInteger(bal)).toBe(true)
  })

  it('grantCredits passes integer micros amount + deterministic id', async () => {
    const sdk = fakeSdk()
    const om = createOmClient(sdk as any)
    await om.grantCredits('s1', 94_500_000, { externalId: 'txn_abc', channel: 'iap_ios', expiresInDays: 365 })
    const [subj, feat, body] = sdk.entitlementsV1.grants.create.mock.calls[0]
    expect(subj).toBe('s1')
    expect(feat).toBe('pnc')
    expect(body.amount).toBe(94_500_000)
    expect(Number.isInteger(body.amount)).toBe(true)
  })

  it('reportUsage ingests a cloudevent with integer micros in data', async () => {
    const sdk = fakeSdk()
    const om = createOmClient(sdk as any)
    await om.reportUsage('s1', 2700, { category: 'llm_tokens', dedupeId: 'evt_1' })
    const ev = sdk.events.ingest.mock.calls[0][0]
    expect(ev.subject).toBe('s1')
    expect(ev.type).toBe('pnc.usage')
    expect(ev.data.pnc_micros).toBe(2700)
    expect(ev.id).toBe('evt_1')
  })
})
```

- [ ] **Step 2: 跑测试确认失败**

Run:
```bash
cd apps/edge && ./node_modules/.bin/vitest run src/billing/om-client.test.ts
```
Expected: FAIL（`./om-client` 不存在）。

- [ ] **Step 3: 写实现**

```ts
// apps/edge/src/billing/om-client.ts
// OpenMeter 薄封装。只暴露 PendingBot 计费需要的领域操作。
// 真实 SDK：@openmeter/sdk 的 entitlementsV1(subject 维度)。
import { OpenMeter } from '@openmeter/sdk'

export const PNC_FEATURE_KEY = 'pnc'
export const PNC_METER_SLUG = 'pnc'
/** 上报扣费用的事件 type；meter 以此 eventType 聚合。 */
export const PNC_USAGE_EVENT_TYPE = 'pnc.usage'

/** grant 幂等：用 渠道+外部交易id 拼确定性 grant id，重投不重复加额度。 */
export function grantIdFor(channel: string, externalPurchaseId: string): string {
  return `pnc_${channel}_${externalPurchaseId}`
}

type Sdk = Pick<OpenMeter, 'subjects' | 'entitlementsV1' | 'events'>

export interface GrantOpts {
  externalId: string
  channel: string
  expiresInDays?: number // 标准充值包 365；不传=永不过期(长期包)
  priority?: number // 1..255，默认让最快过期先燃(靠 expiration 排序)
}

export interface UsageOpts {
  category: string // llm_tokens / voice_tokens / ...（spec §5 八类）
  dedupeId: string // CloudEvents id，去重
  metadata?: Record<string, unknown>
}

export function createOmClient(sdk: Sdk) {
  return {
    /** 确保 subject 存在(用户/群账号)。key = 我们的 subject_id。 */
    async ensureSubject(subjectKey: string) {
      await sdk.subjects.upsert([{ key: subjectKey }])
    },

    /** 为 subject 建 metered PNC entitlement(软上限,grant 驱动余额,无周期 reset)。 */
    async ensureEntitlement(subjectKey: string) {
      return sdk.entitlementsV1.create(subjectKey, {
        type: 'metered',
        featureKey: PNC_FEATURE_KEY,
        isSoftLimit: true,
        issueAfterReset: 0,
      } as any)
    },

    /** 充值/赠送：发一笔 credit grant(整数 micros)。 */
    async grantCredits(subjectKey: string, amountMicros: number, opts: GrantOpts) {
      const body: Record<string, unknown> = {
        amount: amountMicros,
        priority: opts.priority ?? 100,
        effectiveAt: new Date().toISOString(),
        metadata: { channel: opts.channel, externalId: opts.externalId },
      }
      if (opts.expiresInDays != null) {
        body.expiration = { duration: 'DAY', count: opts.expiresInDays }
      }
      return sdk.entitlementsV1.grants.create(subjectKey, PNC_FEATURE_KEY, body as any)
    },

    /** 扣费：上报一条 usage event(整数 micros)。 */
    async reportUsage(subjectKey: string, amountMicros: number, opts: UsageOpts) {
      await sdk.events.ingest({
        id: opts.dedupeId,
        type: PNC_USAGE_EVENT_TYPE,
        subject: subjectKey,
        time: new Date().toISOString(),
        data: { pnc_micros: amountMicros, category: opts.category, ...(opts.metadata ?? {}) },
      } as any)
    },

    /** 门禁读余额：返回整数 micros。 */
    async getBalance(subjectKey: string): Promise<number> {
      const v: any = await sdk.entitlementsV1.value(subjectKey, PNC_FEATURE_KEY)
      return Math.trunc(v.balance ?? 0)
    },

    /** 退款冲销：void 指定 grant 的剩余额度。 */
    async voidGrant(entitlementId: string, grantId: string) {
      await sdk.entitlementsV1.grants.void(entitlementId, grantId)
    },
  }
}

/** 用 Env 构造真实 SDK 的 client。 */
export function omFromEnv(env: { OPENMETER_API_KEY: string; OPENMETER_BASE_URL: string }) {
  const sdk = new OpenMeter({ baseUrl: env.OPENMETER_BASE_URL, apiKey: env.OPENMETER_API_KEY })
  return createOmClient(sdk as unknown as Sdk)
}
```

- [ ] **Step 4: 跑测试确认通过**

Run:
```bash
cd apps/edge && ./node_modules/.bin/vitest run src/billing/om-client.test.ts
```
Expected: PASS（5 个用例）。

- [ ] **Step 5: typecheck + commit**

```bash
bun --filter='@pendingbot/edge' run typecheck
git add apps/edge/src/billing/om-client.ts apps/edge/src/billing/om-client.test.ts
git commit -m "feat(billing): OpenMeter 薄封装(grant/usage/balance/void)+ 幂等 grant id"
```

---

### Task 4: 一次性 bootstrap —— 创建 meter + feature

`pnc` meter 以 `pnc.usage` 事件按 `data.pnc_micros` 求和;`pnc` feature 关联此 meter（使其 metered）。这是租户级一次性配置,不是运行时逻辑。

**Files:**
- Create: `apps/edge/scripts/om-bootstrap.ts`
- Modify: `apps/edge/package.json`（scripts）

- [ ] **Step 1: 写脚本**

```ts
// apps/edge/scripts/om-bootstrap.ts
// 一次性：创建 pnc meter + pnc feature。重复跑应幂等(已存在则忽略 409)。
import { OpenMeter } from '@openmeter/sdk'
import { PNC_FEATURE_KEY, PNC_METER_SLUG, PNC_USAGE_EVENT_TYPE } from '../src/billing/om-client'

const sdk = new OpenMeter({
  baseUrl: process.env.OPENMETER_BASE_URL ?? 'https://openmeter.cloud',
  apiKey: process.env.OPENMETER_API_KEY!,
})

async function main() {
  try {
    await sdk.meters.create({
      slug: PNC_METER_SLUG,
      aggregation: 'SUM',
      eventType: PNC_USAGE_EVENT_TYPE,
      valueProperty: '$.pnc_micros',
    } as any)
    console.log('meter created:', PNC_METER_SLUG)
  } catch (e: any) {
    console.log('meter create skipped (maybe exists):', e?.message)
  }
  try {
    await sdk.features.create({ key: PNC_FEATURE_KEY, name: 'PNC', meterSlug: PNC_METER_SLUG } as any)
    console.log('feature created:', PNC_FEATURE_KEY)
  } catch (e: any) {
    console.log('feature create skipped (maybe exists):', e?.message)
  }
}
main()
```

- [ ] **Step 2: package.json 加脚本**

在 `apps/edge/package.json` 的 `scripts` 加:
```json
    "om:bootstrap": "OPENMETER_BASE_URL=${OPENMETER_BASE_URL:-https://openmeter.cloud} bun run scripts/om-bootstrap.ts",
    "om:spike": "OPENMETER_BASE_URL=${OPENMETER_BASE_URL:-https://openmeter.cloud} bun run scripts/om-spike.ts"
```

- [ ] **Step 3: 跑 bootstrap(真实)**

Run:
```bash
cd apps/edge && OPENMETER_API_KEY=<key> bun run om:bootstrap
```
Expected: 打印 `meter created: pnc` 与 `feature created: pnc`(或 skipped）。**若 `meters.create`/`features.create` 的字段被 API 拒绝,按报错调整字段名,并回填到 `om-client.ts` 注释** —— 这是 spike 阶段锁 payload 的一部分。

- [ ] **Step 4: commit**

```bash
git add apps/edge/scripts/om-bootstrap.ts apps/edge/package.json
git commit -m "chore(billing): om-bootstrap 脚本(创建 pnc meter+feature)"
```

---

### Task 5: Spike —— 验证整数精确的收/扣/查余额

这是**对真实 OpenMeter 的端到端验证**(不是 mock 单测)。目的:坐实 spec §核心建模的「float64 但整数 micros 精确」断言,并锁定 grant/entitlement/value 的真实 payload。

**Files:**
- Create: `apps/edge/scripts/om-spike.ts`

- [ ] **Step 1: 写 spike 脚本**

```ts
// apps/edge/scripts/om-spike.ts
// 真实 OpenMeter spike：建 subject+entitlement → grant 94_500_000 → ingest 2700 → 读 balance。
// 期望 balance == 94_497_300（整数精确）。
import { OpenMeter } from '@openmeter/sdk'
import { createOmClient, grantIdFor } from '../src/billing/om-client'

const sdk = new OpenMeter({
  baseUrl: process.env.OPENMETER_BASE_URL ?? 'https://openmeter.cloud',
  apiKey: process.env.OPENMETER_API_KEY!,
})
const om = createOmClient(sdk as any)

async function main() {
  const subj = `spike-${Date.now()}`
  await om.ensureSubject(subj)
  await om.ensureEntitlement(subj)

  await om.grantCredits(subj, 94_500_000, {
    externalId: grantIdFor('spike', subj),
    channel: 'spike',
    expiresInDays: 365,
  })

  await om.reportUsage(subj, 2700, { category: 'llm_tokens', dedupeId: `evt-${subj}-1` })

  // 事件聚合可能有秒级延迟，轮询几次
  let balance = -1
  for (let i = 0; i < 10; i++) {
    await new Promise((r) => setTimeout(r, 2000))
    balance = await om.getBalance(subj)
    console.log(`poll ${i}: balance=${balance}`)
    if (balance === 94_497_300) break
  }

  const ok = balance === 94_497_300
  console.log(ok ? '✅ 精确：94_497_300' : `❌ 漂移：得到 ${balance}，期望 94_497_300`)
  process.exit(ok ? 0 : 1)
}
main()
```

- [ ] **Step 2: 跑 spike(真实)**

Run:
```bash
cd apps/edge && OPENMETER_API_KEY=<key> bun run om:spike
```
Expected: 最终打印 `✅ 精确：94_497_300`,退出码 0。

- [ ] **Step 3: 处理结果**
  - **若 ✅**：精度断言坐实,OpenMeter 选型最终敲定。把结论(实测整数精确 + 锁定的真实 payload 字段名)回填到 spec §核心建模 与 §开放问题。
  - **若 ❌（出现非整数/漂移）**：说明 OpenMeter 在我们用法下引入了取整/浮点误差 → **触发 spec §核心建模的降级分支**(edge 留 pnc_micros 事实源、OpenMeter 仅做粗粒度 entitlement,或换引擎)。**停下,把现象记进 spec,回到设计评审**,不要硬推 P1。

- [ ] **Step 4: commit**

```bash
git add apps/edge/scripts/om-spike.ts
git commit -m "chore(billing): om-spike 验证整数 micros 精确(P0 验收)"
```

---

## Self-Review

**Spec 覆盖**：本计划只认领 spec 的 **P0**(地基 + 精度验收 + payload 锁定)。spec 的 P1–P7 显式留作后续独立计划(见顶部范围说明)。P0 内的子项(OpenMeter 账号/区域/上限核实=前置 P-1;client 封装=Task 3;pnc 单位=Task 2;bootstrap=Task 4;spike 精度验收=Task 5)均有对应任务。

**占位符扫描**：无 TBD/TODO。两处"按报错调整字段"是 spike 的本职(锁真实 payload),不是偷懒——已明确这是 P0 的验收动作,且给了确定性的期望值(94_497_300)。

**类型一致**：`PNC_FEATURE_KEY`/`PNC_METER_SLUG`/`PNC_USAGE_EVENT_TYPE`/`grantIdFor`/`createOmClient`/`getBalance`/`grantCredits`/`reportUsage`/`voidGrant`/`ensureSubject`/`ensureEntitlement` 在 Task 3 定义,Task 4/5 与测试中引用一致。`usdToPncMicros`/`pncMicrosToPnc`/`PNC_PER_USD`/`MICROS_PER_PNC` 在 Task 2 定义。

**已知风险(写进 P0 验收)**：grant/entitlement/meter 的精确 body 字段(`expiration` 形状、`isSoftLimit`、`meterSlug` vs `meter`、`valueProperty` 语法)以核实的 SDK 方法名为准,**确切字段由 Task 4/5 的真实调用锁定**;若与代码假设不符,按报错修正 `om-client.ts` 并回填 spec。
