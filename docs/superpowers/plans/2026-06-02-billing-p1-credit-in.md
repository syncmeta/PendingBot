# 计费 P1：入账(credit-in)双路 webhook + 整数影子账 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 或 superpowers:executing-plans。步骤用 `- [ ]` 跟踪。

**Goal:** web/Mac(Polar checkout)与 iOS(RevenueCat IAP)两条充值/退款路径,统一经 webhook → 写 **edge 整数影子账(幂等)** → 调 Polar `grantCredits`/`reduceCredits`,落到同一个 Polar Customer 的钱包。

**Architecture:** 沿用现有 `routes/billing-webhooks.ts` 模式(Hono + `validateEvent`/共享密钥验签 + `serviceClient` + `jsonError`),handler 逻辑放 `lib/billing-polar.ts`。**影子账 `pnc_ledger` 表是 edge 侧整数事实源**(兜 Polar 锁定/冻结 + reconciliation 基准);Polar 是钱包余额事实源。**幂等键 = (source, external_ref)** 唯一约束 + Polar `events.ingest` 的 `external_id` 双层兜底。

**Tech Stack:** Cloudflare Workers + Hono + TS,Supabase(serviceClient),`@polar-sh/sdk`(+ `validateEvent`),vitest。前置:**P0 已完成**(`pnc.ts`/`polar-client.ts` 已就绪、spike 实测通过)。

> **范围**:P1 只做**入账(topup + refund)**。用量计量/settle/门禁 = P2;群池 = P4。

---

## 前置(人工)
- [ ] **P1-0**:Polar dashboard 建 webhook endpoint(指向 `/v1/billing/polar/webhook`)→ 拿 signing secret;RevenueCat dashboard 建 webhook(指向 `/v1/billing/revenuecat/webhook`)+ 设 Authorization 共享密钥。两个 secret 进 `wrangler secret`(本地 `.dev.vars`)。
- [ ] **P1-0b**:Polar 建正式 `pnc` meter(SUM `metadata.pnc`,filter event name `pnc.usage`)+ PNC 充值包产品(**不挂 Credits Benefit**,见 spec 统一符号模型)。记 `meterId`、各 product_id。

## 文件结构
- Create: `supabase/migrations/<ts>_pnc_ledger.sql` —— 影子账表。
- Modify: `apps/edge/src/types.ts` —— Env 加 `POLAR_WEBHOOK_SECRET`、`REVENUECAT_WEBHOOK_AUTH`、`POLAR_PNC_METER_ID`。
- Create: `apps/edge/src/lib/billing-packs.ts` —— product_id → PNC 映射(+ markup 快照),纯函数。
- Create: `apps/edge/src/lib/billing-packs.test.ts`
- Create: `apps/edge/src/lib/billing-polar.ts` —— 影子账写入 + 幂等 + 调 polar-client(handler 逻辑)。
- Create: `apps/edge/src/lib/billing-polar.test.ts`
- Modify: `apps/edge/src/routes/billing-webhooks.ts` —— 加 `/polar/webhook` + `/revenuecat/webhook` 两路由。

---

### Task 1：迁移 —— pnc_ledger 影子账表

**Files:** Create `supabase/migrations/<ts>_pnc_ledger.sql`

- [ ] **Step 1**:生成迁移文件

Run（主 worktree）:
```bash
supabase migration new pnc_ledger
```

- [ ] **Step 2**:写 SQL

```sql
-- edge 侧整数影子账：记录每笔 credit 进出(topup/refund/admin)。
-- Polar 是余额事实源;本表是 reconciliation 基准 + 供应商锁定/冻结的迁移底稿。
create table if not exists pendingbot.pnc_ledger (
  id            uuid primary key default gen_random_uuid(),
  subject_id    uuid not null references pendingbot.subjects(id) on delete cascade,
  kind          text not null check (kind in ('topup','refund','admin','redemption')),
  source        text not null,                 -- polar_checkout / iap_ios / lemon_squeezy(弃) / admin ...
  external_ref  text not null,                 -- 上游交易 id(order.id / RC transaction_id),幂等键
  delta_pnc_micros bigint not null,            -- 正=加额度;负=减额度(退款)
  markup_snapshot numeric,                     -- 卖包当时 markup(仅 topup)
  gross_paid_usd_cents int,
  net_revenue_usd_cents int,
  polar_synced  boolean not null default false,-- 是否已成功推给 Polar
  raw           jsonb,
  created_at    timestamptz not null default now(),
  unique (source, external_ref)               -- 幂等:同一交易只入账一次
);
create index if not exists pnc_ledger_subject_idx on pendingbot.pnc_ledger (subject_id, created_at desc);
```

- [ ] **Step 3**:应用 + regen + typecheck（主 worktree）
```bash
supabase db push --linked
bun --filter='@pendingbot/edge' run types:db
bun --filter='@pendingbot/edge' run typecheck
```
Expected: schema.ts 出现 `pnc_ledger`;typecheck PASS。

- [ ] **Step 4**:commit（schema.ts 必须同 commit,lefthook 卡）
```bash
git add supabase/migrations/*_pnc_ledger.sql apps/edge/src/db/schema.ts
git commit -m "db(billing): pnc_ledger 影子账表 + regen"
```

---

### Task 2：Env 接线

**Files:** Modify `apps/edge/src/types.ts`

- [ ] **Step 1**:Env 加字段(放 Polar 那段旁)
```ts
  POLAR_WEBHOOK_SECRET?: string;   // Polar webhook signing secret(Standard Webhooks)
  REVENUECAT_WEBHOOK_AUTH?: string;// RevenueCat webhook Authorization 头共享密钥
  POLAR_PNC_METER_ID?: string;     // bootstrap 建的 pnc meter id
```
- [ ] **Step 2**:typecheck + commit
```bash
bun --filter='@pendingbot/edge' run typecheck
git add apps/edge/src/types.ts && git commit -m "chore(billing): Env 加 Polar webhook/meter + RC auth"
```

---

### Task 3：PNC 充值包映射(TDD,纯函数)

**Files:** Create `apps/edge/src/lib/billing-packs.ts` + `.test.ts`

- [ ] **Step 1**:写失败测试
```ts
// apps/edge/src/lib/billing-packs.test.ts
import { describe, expect, it } from 'vitest'
import { resolvePack } from './billing-packs'

describe('billing-packs', () => {
  it('maps an iOS product id to a PNC pack', () => {
    const p = resolvePack('iap_ios', 'com.pendingbot.pnc.pack1')
    expect(p?.pnc).toBe(270) // 例:¥/$ 档 → 270 PNC
  })
  it('maps a polar product id to a PNC pack', () => {
    const p = resolvePack('polar_checkout', 'polar_prod_pack1')
    expect(p?.pnc).toBe(270)
  })
  it('returns null for unknown product', () => {
    expect(resolvePack('iap_ios', 'nope')).toBeNull()
  })
})
```
- [ ] **Step 2**:跑(FAIL)
```bash
cd apps/edge && ./node_modules/.bin/vitest run src/lib/billing-packs.test.ts
```
- [ ] **Step 3**:实现(占位映射,上架前补真实 product_id)
```ts
// apps/edge/src/lib/billing-packs.ts
// product_id → PNC 充值包。上线前把 product_id / markup 换成真实值(见 spec 商品形态)。
export interface PncPack {
  pnc: number
  markupSnapshot: number // 卖包当时 markup(利润只在卖包体现)
}

const PACKS: Record<string, Record<string, PncPack>> = {
  iap_ios: {
    'com.pendingbot.pnc.pack1': { pnc: 270, markupSnapshot: 2.0 },
  },
  polar_checkout: {
    polar_prod_pack1: { pnc: 270, markupSnapshot: 2.0 },
  },
}

export function resolvePack(source: string, productId: string): PncPack | null {
  return PACKS[source]?.[productId] ?? null
}
```
- [ ] **Step 4**:跑(PASS)+ commit
```bash
cd apps/edge && ./node_modules/.bin/vitest run src/lib/billing-packs.test.ts
git add apps/edge/src/lib/billing-packs.ts apps/edge/src/lib/billing-packs.test.ts
git commit -m "feat(billing): PNC 充值包映射(占位)+ 测试"
```

---

### Task 4：影子账写入 + 幂等 + Polar 同步(TDD,mock)

`recordCreditIn` 先写影子账(`unique(source,external_ref)` 冲突 = 已处理过,跳过),仅当新插入才推 Polar。`recordRefund` 先按影子账可用余额夹金额(不扣成负),再写负向行 + 推 Polar `reduceCredits`。

**Files:** Create `apps/edge/src/lib/billing-polar.ts` + `.test.ts`

- [ ] **Step 1**:写失败测试
```ts
// apps/edge/src/lib/billing-polar.test.ts
import { describe, expect, it, vi } from 'vitest'
import { recordCreditIn, availableMicros } from './billing-polar'

function fakeSupa(opts: { insertErr?: { code: string } | null; rows?: any[] } = {}) {
  return {
    from: vi.fn().mockReturnValue({
      insert: vi.fn().mockReturnValue({
        select: vi.fn().mockReturnValue({
          maybeSingle: vi
            .fn()
            .mockResolvedValue({ data: opts.insertErr ? null : { id: 'led_1' }, error: opts.insertErr ?? null }),
        }),
      }),
      select: vi.fn().mockReturnValue({
        eq: vi.fn().mockResolvedValue({ data: opts.rows ?? [], error: null }),
      }),
    }),
  }
}

describe('billing-polar', () => {
  it('availableMicros sums ledger deltas', () => {
    expect(availableMicros([{ delta_pnc_micros: 270_000_000 }, { delta_pnc_micros: -700 }])).toBe(269_999_300)
  })

  it('recordCreditIn writes ledger + grants on first delivery', async () => {
    const supa = fakeSupa()
    const om = { grantCredits: vi.fn().mockResolvedValue(undefined) }
    const r = await recordCreditIn(supa as any, om as any, {
      subjectId: 's1', kind: 'topup', source: 'iap_ios', externalRef: 'txn_1', pncMicros: 270_000_000,
    })
    expect(r.applied).toBe(true)
    expect(om.grantCredits).toHaveBeenCalledTimes(1)
    const [subj, micros, g] = om.grantCredits.mock.calls[0]
    expect(subj).toBe('s1'); expect(micros).toBe(270_000_000); expect(g.dedupeId).toBe('iap_ios:txn_1')
  })

  it('recordCreditIn is idempotent on unique violation (no double grant)', async () => {
    const supa = fakeSupa({ insertErr: { code: '23505' } }) // unique_violation
    const om = { grantCredits: vi.fn() }
    const r = await recordCreditIn(supa as any, om as any, {
      subjectId: 's1', kind: 'topup', source: 'iap_ios', externalRef: 'txn_1', pncMicros: 270_000_000,
    })
    expect(r.applied).toBe(false)
    expect(om.grantCredits).not.toHaveBeenCalled()
  })
})
```
- [ ] **Step 2**:跑(FAIL) → **Step 3**:实现
```ts
// apps/edge/src/lib/billing-polar.ts
import type { SupabaseClient } from '@supabase/supabase-js'
import type { PolarClient } from '../billing/polar-client'

export interface CreditInInput {
  subjectId: string
  kind: 'topup' | 'admin' | 'redemption'
  source: string
  externalRef: string
  pncMicros: number // 正数:发放额度
  markupSnapshot?: number
  raw?: unknown
}

export function availableMicros(rows: Array<{ delta_pnc_micros: number }>): number {
  return rows.reduce((s, r) => s + r.delta_pnc_micros, 0)
}

/** 入账:影子账幂等(unique 冲突=已处理),仅新插入才推 Polar 发 credit。 */
export async function recordCreditIn(
  supa: SupabaseClient,
  om: PolarClient,
  i: CreditInInput,
): Promise<{ applied: boolean }> {
  const { data, error } = await supa
    .from('pnc_ledger')
    .insert({
      subject_id: i.subjectId,
      kind: i.kind,
      source: i.source,
      external_ref: i.externalRef,
      delta_pnc_micros: Math.abs(i.pncMicros), // 入账=正
      markup_snapshot: i.markupSnapshot ?? null,
      raw: i.raw ?? null,
    })
    .select('id')
    .maybeSingle()

  if (error) {
    if ((error as { code?: string }).code === '23505') return { applied: false } // 幂等:已入账
    throw error
  }
  await om.grantCredits(i.subjectId, Math.abs(i.pncMicros), {
    source: i.source,
    dedupeId: `${i.source}:${i.externalRef}`,
  })
  await supa.from('pnc_ledger').update({ polar_synced: true }).eq('id', data!.id)
  return { applied: true }
}

/** 退款:按影子账可用余额夹金额(不扣成负),写负向行 + Polar reduceCredits。 */
export async function recordRefund(
  supa: SupabaseClient,
  om: PolarClient,
  i: { subjectId: string; source: string; externalRef: string; pncMicros: number; raw?: unknown },
): Promise<{ applied: boolean; clampedMicros: number }> {
  const { data: rows } = await supa
    .from('pnc_ledger')
    .select('delta_pnc_micros')
    .eq('subject_id', i.subjectId)
  const available = availableMicros((rows ?? []) as Array<{ delta_pnc_micros: number }>)
  const clamped = Math.max(0, Math.min(Math.abs(i.pncMicros), available)) // 不扣成负

  const { error } = await supa
    .from('pnc_ledger')
    .insert({
      subject_id: i.subjectId,
      kind: 'refund',
      source: i.source,
      external_ref: i.externalRef,
      delta_pnc_micros: -clamped,
      raw: i.raw ?? null,
    })
    .select('id')
    .maybeSingle()
  if (error) {
    if ((error as { code?: string }).code === '23505') return { applied: false, clampedMicros: 0 }
    throw error
  }
  if (clamped > 0) {
    await om.reduceCredits(i.subjectId, clamped, { source: i.source, dedupeId: `refund:${i.source}:${i.externalRef}` })
  }
  return { applied: true, clampedMicros: clamped }
}
```
- [ ] **Step 4**:跑(PASS)+ typecheck + commit
```bash
cd apps/edge && ./node_modules/.bin/vitest run src/lib/billing-polar.test.ts
bun --filter='@pendingbot/edge' run typecheck
git add apps/edge/src/lib/billing-polar.ts apps/edge/src/lib/billing-polar.test.ts
git commit -m "feat(billing): 影子账幂等入账/退款 + Polar 同步"
```

---

### Task 5：Polar webhook 路由

**Files:** Modify `apps/edge/src/routes/billing-webhooks.ts`

- [ ] **Step 1**:加路由(放文件末尾,export 同一个 `billingWebhookRoutes`)
```ts
import { validateEvent, WebhookVerificationError } from '@polar-sh/sdk/webhooks';
import { polarFromEnv } from '../billing/polar-client';
import { recordCreditIn, recordRefund } from '../lib/billing-polar';
import { resolvePack } from '../lib/billing-packs';
import { usdToPncMicros } from '../billing/pnc';

billingWebhookRoutes.post('/polar/webhook', async (c) => {
  const secret = c.env.POLAR_WEBHOOK_SECRET;
  if (!secret) return jsonError(c, 501, 'webhook_not_configured');
  const raw = await c.req.text();
  let event: any;
  try {
    event = validateEvent(raw, Object.fromEntries(c.req.raw.headers), secret);
  } catch (e) {
    if (e instanceof WebhookVerificationError) return jsonError(c, 401, 'invalid_signature');
    throw e;
  }
  const supa = serviceClient(c.env);
  const om = polarFromEnv(c.env as any, c.env.POLAR_PNC_METER_ID ?? '');

  if (event.type === 'order.paid') {
    const order = event.data;
    const subjectId = order.customer?.externalId;
    if (!subjectId) return c.json({ ok: true, skipped: 'no_external_id' });
    const pack = resolvePack('polar_checkout', order.product?.id ?? order.productId);
    if (!pack) return c.json({ ok: true, skipped: 'unknown_product' });
    await recordCreditIn(supa, om, {
      subjectId, kind: 'topup', source: 'polar_checkout', externalRef: order.id,
      pncMicros: usdToPncMicros(pack.pnc / 27), markupSnapshot: pack.markupSnapshot, raw: order,
    });
    return c.json({ ok: true });
  }
  if (event.type === 'order.refunded') {
    const order = event.data;
    const subjectId = order.customer?.externalId;
    if (subjectId) {
      const pack = resolvePack('polar_checkout', order.product?.id ?? order.productId);
      if (pack) await recordRefund(supa, om, {
        subjectId, source: 'polar_checkout', externalRef: `${order.id}:refund`,
        pncMicros: usdToPncMicros(pack.pnc / 27), raw: order,
      });
    }
    return c.json({ ok: true });
  }
  return c.json({ ok: true, ignored: event.type });
});
```
> 注:`order.product.id` / `customer.externalId` 的确切路径以真实 webhook payload 为准(P1-0 配好 endpoint 后,用 Polar dashboard 的 "send test" 或一笔 sandbox 购买核对字段名,按需微调)。`pack.pnc` 已是 PNC,这里 `usdToPncMicros(pnc/27)` 把 PNC 转 micros —— 若 `pnc.ts` 后续加 `pncToMicros` 直接用更清晰(见 Step 3 备注)。

- [ ] **Step 2**:补一个 `pncToMicros` 到 `billing/pnc.ts`(避免 `/27` 绕)
```ts
// 追加到 apps/edge/src/billing/pnc.ts
export function pncToMicros(pnc: number): number {
  return Math.round(pnc * MICROS_PER_PNC)
}
```
改上面两处为 `pncToMicros(pack.pnc)`。补一条 pnc.test.ts 用例:`expect(pncToMicros(270)).toBe(270_000_000)`。

- [ ] **Step 3**:typecheck + commit
```bash
bun --filter='@pendingbot/edge' run typecheck
git add apps/edge/src/routes/billing-webhooks.ts apps/edge/src/billing/pnc.ts apps/edge/src/billing/pnc.test.ts
git commit -m "feat(billing): Polar webhook(order.paid/refunded)→影子账入账/退款"
```

---

### Task 6：RevenueCat webhook 路由(iOS)

**Files:** Modify `apps/edge/src/routes/billing-webhooks.ts`

- [ ] **Step 1**:加路由
```ts
billingWebhookRoutes.post('/revenuecat/webhook', async (c) => {
  const expected = c.env.REVENUECAT_WEBHOOK_AUTH;
  if (!expected) return jsonError(c, 501, 'webhook_not_configured');
  // 常量时间比对 Authorization 头(RevenueCat 无签名,只有共享密钥头)
  const got = c.req.header('authorization') ?? '';
  if (got.length !== expected.length || !timingSafeEqual(got, expected)) {
    return jsonError(c, 401, 'invalid_auth');
  }
  const body = await c.req.json<{ event?: any }>();
  const ev = body.event;
  if (!ev) return jsonError(c, 400, 'invalid_json');

  const supa = serviceClient(c.env);
  const om = polarFromEnv(c.env as any, c.env.POLAR_PNC_METER_ID ?? '');
  const subjectId = ev.app_user_id; // = 我们的 subject_id(iOS 端 logIn(subject_id))

  if (ev.type === 'NON_RENEWING_PURCHASE') {
    const pack = resolvePack('iap_ios', ev.product_id);
    if (pack && subjectId) await recordCreditIn(supa, om, {
      subjectId, kind: 'topup', source: 'iap_ios', externalRef: ev.transaction_id,
      pncMicros: pncToMicros(pack.pnc), markupSnapshot: pack.markupSnapshot, raw: ev,
    });
    return c.json({ ok: true });
  }
  if (ev.type === 'CANCELLATION') { // 退款
    const pack = resolvePack('iap_ios', ev.product_id);
    if (pack && subjectId) await recordRefund(supa, om, {
      subjectId, source: 'iap_ios', externalRef: `${ev.transaction_id}:refund`,
      pncMicros: pncToMicros(pack.pnc), raw: ev,
    });
    return c.json({ ok: true });
  }
  if (ev.type === 'REFUND_REVERSED') { // 退款被撤销 → 重新发
    const pack = resolvePack('iap_ios', ev.product_id);
    if (pack && subjectId) await recordCreditIn(supa, om, {
      subjectId, kind: 'topup', source: 'iap_ios', externalRef: `${ev.transaction_id}:rev`,
      pncMicros: pncToMicros(pack.pnc), raw: ev,
    });
    return c.json({ ok: true });
  }
  return c.json({ ok: true, ignored: ev.type });
});

// 常量时间字符串比较(避免计时攻击)
function timingSafeEqual(a: string, b: string): boolean {
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
```
> 注:RC `CANCELLATION`/退款用 `transaction_id` 反查原 grant 的 pack(payload 不一定带 price);幂等用 `transaction_id`(已在 external_ref)。RC webhook 非 exactly-once + consumable 退款可能延迟 → P6 配 reconciliation 兜底。

- [ ] **Step 2**:typecheck + commit
```bash
bun --filter='@pendingbot/edge' run typecheck
git add apps/edge/src/routes/billing-webhooks.ts
git commit -m "feat(billing): RevenueCat webhook(购买/退款/退款撤销)→影子账"
```

---

### Task 7：清理 + 验证
- [ ] 旧 LS/IAP(billing-v2)路由:本期保留(返回 501/未配),P6 退役时再删,避免本 PR 过大。
- [ ] 全量 edge 测试 + typecheck:
```bash
cd apps/edge && ./node_modules/.bin/vitest run && bun --filter='@pendingbot/edge' run typecheck
```
- [ ] (有 Polar/RC dashboard 后)发测试 webhook,核对 payload 字段路径(`order.customer.externalId`、`order.product.id`、RC `app_user_id`/`transaction_id`),按真实字段微调 + commit。

## Self-Review
- **覆盖**:入账双路(Polar order.paid / RC NON_RENEWING_PURCHASE)+ 退款(order.refunded / CANCELLATION)+ 退款撤销(REFUND_REVERSED)+ 影子账幂等 + Polar 同步 + 退款不扣成负夹值。用量/settle/群池/admin = 后续 P2/P4/P6。
- **占位符**:`billing-packs` 的 product_id/markup 是**显式占位**(上架前补真实值,已注明);webhook payload 字段路径标注"真实 payload 核对"——这是 webhook 集成的本职,非偷懒。
- **类型一致**:`recordCreditIn`/`recordRefund`/`availableMicros`(Task4)、`resolvePack`(Task3)、`pncToMicros`(Task5)、`grantCredits`/`reduceCredits`(P0 polar-client)签名跨任务一致。
- **幂等**:DB `unique(source,external_ref)` 为主、Polar `external_id` 为辅,双层防重投。
