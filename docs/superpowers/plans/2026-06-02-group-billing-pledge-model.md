# 群计费 实缴池 + 认缴(pledge)统一模型 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在已落地的"群钱包(实缴池 + share-index)"之上,新增**部分取出**与**认缴(pledge)**机制——认缴成员的份额 = min(pledge, 个人余额),群消费时按占比当场从其个人钱包直扣;并收尾链式退款/漂移报警/leave 删行。

**Architecture:** 群消费成本 X 按总份额 `S = 实缴池 + Σ认缴 min(pledge,余额)` 分账:实缴部分由群 WalletDO + share_index 衰减承担,认缴部分实时直扣各成员**个人 WalletDO**(个人 WalletDO 是其余额的串行权威)。门禁聚合实缴池 + 认缴可用。取出/退款仍只对实缴(认缴的"退"= 调 pledge)。

**Tech Stack:** Cloudflare Workers + Hono + TS;Supabase(schema `pendingbot`);Polar `@polar-sh/sdk`;`apps/edge/src/billing/{group-wallet,share-index,wallet-client,polar-client,pnc,billing-polar}.ts`、`durable-objects/wallet.ts`;vitest。金额一律 micros。

**铁律:** 接 Polar/SDK 一律查生成类型,不凭印象。沿用 spec `specs/2026-06-02-group-billing-pledge-model-design.md`。

---

## 现状(已建,本计划在其上增量)

- `billing/group-wallet.ts`:`contributeToGroup` / `refundContributorFromGroup`(全额=leave)/ `dissolveGroup` / `applyGroupSpendDecay`。
- `billing/share-index.ts`:`computeShareNow` / `decayShareIndex`。
- 迁移 `apply_group_pool_spend` / `apply_group_contribution` / `apply_group_refund` RPC(已应用)。
- 热路径(router.ts persistAuditMessage / room-voice.ts / sandbox.ts):群消费 `wallet.debit(env, groupSubjectId, X)` 后 `applyGroupSpendDecay`。
- 端点 `/topup`(contribute)`/leave`(全退)`/dissolve`;`me.ts /wallet/v2` 读 WalletDO。

## File Structure

- **Migration** `supabase/migrations/<ts>_group_pledges.sql` — `group_pledges` 表 + `apply_partial_withdraw` RPC。
- **`billing/group-wallet.ts`** — 增:`getActivePledges` / `setPledge` / `resolveGroupStakes` / `settleGroupSpend` / `withdrawFromGroup`。
- **`billing/usage-gate.ts`** — 增:`availableForSubject`(群聚合认缴),gateUsage 群分支改用它。
- **`lib/billing.ts`** — `requireBalance` 群分支改用 `availableForSubject`。
- **`llm/router.ts` / `durable-objects/room-voice.ts` / `lib/sandbox.ts`** — 群消费由 `wallet.debit(group)+decay` 改调 `settleGroupSpend`。
- **`routes/group-subjects.ts`** — 增 `POST /:id/pledge`(设/清)、`POST /:id/withdraw`(部分取出)。
- **`routes/billing-webhooks.ts`** — 链式退款(尾巴)。
- **`durable-objects/wallet.ts`** — 群池漂移报警(尾巴)。

---

## Task 1: group_pledges 表 + apply_partial_withdraw RPC

**Files:** Create `supabase/migrations/<ts>_group_pledges.sql`(用 `date -u +%Y%m%d%H%M%S` 前缀)

- [ ] **Step 1: 写迁移**

```sql
set search_path = pendingbot, public;

-- 认缴:成员给群授权的扣款上限(钱不动,留个人钱包)。有效份额 = min(pledge, 个人余额)。
create table if not exists pendingbot.group_pledges (
  subject_id        uuid not null references pendingbot.subjects(id) on delete cascade,
  user_id           uuid not null references pendingbot.users(id) on delete cascade,
  pledge_pnc_micros bigint not null check (pledge_pnc_micros >= 0),
  status            text not null default 'active' check (status in ('active','revoked')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  primary key (subject_id, user_id)
);
alter table pendingbot.group_pledges enable row level security;
-- 本人读写自己的认缴
create policy group_pledges_self on pendingbot.group_pledges
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
-- 群 owner/admin 读全群(复用既有 helper 判定)
create policy group_pledges_admin_read on pendingbot.group_pledges
  for select using (pendingbot._grp_caller_role(subject_id) in ('owner','admin'));

-- 部分取出:从实缴池退回 amount 给成员,按比例缩其 active contributions,share_index 不变。
-- 返回实际退出额(夹到池子)。
create or replace function pendingbot.apply_partial_withdraw(
  p_subject_id uuid, p_user_id uuid, p_amount_micros bigint
) returns bigint language plpgsql security definer as $$
declare v_total bigint; v_idx numeric(40,20); v_sharenow bigint; v_factor numeric; v_refund bigint;
begin
  if p_amount_micros is null or p_amount_micros <= 0 then return 0; end if;
  select total_remaining_pnc_micros, share_index into v_total, v_idx
    from pendingbot.group_pools where subject_id = p_subject_id for update;
  if not found then return 0; end if;
  -- 该成员当前 share_now 合计
  select coalesce(sum(floor(contributed_pnc_micros * (v_idx / share_index_at_join))),0)
    into v_sharenow
    from pendingbot.group_contributions
    where subject_id = p_subject_id and contributor_user_id = p_user_id and status = 'active';
  v_refund := least(p_amount_micros, v_sharenow, v_total);
  if v_refund <= 0 then return 0; end if;
  -- 按比例缩 contributions(share_index 不变;缩 contributed 等效缩份额)
  v_factor := (v_sharenow - v_refund)::numeric / v_sharenow;
  update pendingbot.group_contributions
    set contributed_pnc_micros = floor(contributed_pnc_micros * v_factor)
    where subject_id = p_subject_id and contributor_user_id = p_user_id and status = 'active';
  update pendingbot.group_pools
    set total_remaining_pnc_micros = greatest(0, v_total - v_refund), updated_at = now()
    where subject_id = p_subject_id;
  return v_refund;
end $$;

revoke all on function pendingbot.apply_partial_withdraw(uuid,uuid,bigint) from public, anon, authenticated;
```

- [ ] **Step 2: 应用** — `cd <repo> && supabase db push --linked < /dev/null`(本 worktree 有 linked-project.json)
- [ ] **Step 3: regen + typecheck** — `bun --filter='@pendingbot/edge' run types:db && bun --filter='@pendingbot/edge' run typecheck`
- [ ] **Step 4: 确认** — `grep -c "group_pledges\|apply_partial_withdraw" apps/edge/src/db/schema.ts` 应 ≥2
- [ ] **Step 5: Commit** — `git add supabase/migrations/*group_pledges.sql apps/edge/src/db/schema.ts && git commit -m "feat(db): group_pledges 表 + apply_partial_withdraw RPC"`

> 注:`_grp_caller_role(uuid)` 是既有 helper(schema 里 `_grp_caller_role`),若签名不符,改用现有群角色判定函数(在 `20260528083639_group_account_permission_rpcs.sql` 查实际名)。

---

## Task 2: 认缴读写 + 部分取出(group-wallet.ts)

**Files:** Modify `apps/edge/src/billing/group-wallet.ts`;Test `apps/edge/src/billing/group-wallet.test.ts`

- [ ] **Step 1: 写失败测试**(追加)

```ts
import { getActivePledges, setPledge, withdrawFromGroup } from './group-wallet';

describe('setPledge / getActivePledges', () => {
  it('upsert 认缴额度;0 = 撤销', async () => {
    const db = makeFakeDb({ group_pledges: [] });
    const supa = makeFakeClient(db);
    await setPledge(supa, GROUP, ALICE, 27_000_000);
    expect(db.inserts.find((i) => i.table === 'group_pledges')?.row).toMatchObject({
      subject_id: GROUP, user_id: ALICE, pledge_pnc_micros: 27_000_000, status: 'active',
    });
  });
});

describe('withdrawFromGroup (部分取出)', () => {
  it('退≤share_now,池减、个人入账、缩 contributions', async () => {
    const db = makeFakeDb({
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 100_000_000, share_index: 1 }],
      group_contributions: [{ id: 'c1', subject_id: GROUP, contributor_user_id: ALICE, contributed_pnc_micros: 100_000_000, share_index_at_join: 1, status: 'active' }],
      pnc_ledger: [],
    });
    db.rpcs = { apply_partial_withdraw: () => ({ data: 30_000_000 }) };
    const { env, supa, wallet } = ctx(db, { [GROUP]: 100_000_000, [ALICE]: 0 });
    const om = fakeOm();
    const r = await withdrawFromGroup({ env, supa, om, subjectId: GROUP, userId: ALICE, amountMicros: 30_000_000 });
    expect(r.withdrawnMicros).toBe(30_000_000);
    expect((om as any).reduceCredits).toHaveBeenCalledWith(GROUP, 30_000_000, expect.any(Object));
    expect((om as any).grantCredits).toHaveBeenCalledWith(ALICE, 30_000_000, expect.any(Object));
    expect(wallet.calls.some((c) => c.subjectId === ALICE && c.path === '/credit')).toBe(true);
  });
});
```

- [ ] **Step 2: 跑确认失败** — `cd apps/edge && ./node_modules/.bin/vitest run src/billing/group-wallet.test.ts`

- [ ] **Step 3: 实现**(追加到 group-wallet.ts)

```ts
export interface Pledge { userId: string; pledgeMicros: number; }

export async function getActivePledges(supa: Supa, subjectId: string): Promise<Pledge[]> {
  const { data } = await supa
    .from('group_pledges')
    .select('user_id, pledge_pnc_micros')
    .eq('subject_id', subjectId)
    .eq('status', 'active');
  return (data ?? []).map((r) => ({ userId: r.user_id as string, pledgeMicros: Number(r.pledge_pnc_micros) }));
}

/** 设/改认缴额度;amountMicros<=0 视为撤销(status=revoked, 额度 0)。 */
export async function setPledge(supa: Supa, subjectId: string, userId: string, amountMicros: number): Promise<void> {
  const micros = Math.max(0, Math.trunc(amountMicros));
  await supa.from('group_pledges').upsert(
    {
      subject_id: subjectId, user_id: userId,
      pledge_pnc_micros: micros, status: micros > 0 ? 'active' : 'revoked',
      updated_at: new Date().toISOString(),
    },
    { onConflict: 'subject_id,user_id' },
  );
}

export interface WithdrawParams {
  env: Env; supa: Supa; om: PolarClient;
  subjectId: string; userId: string; amountMicros: number;
}
export async function withdrawFromGroup(p: WithdrawParams): Promise<{ withdrawnMicros: number }> {
  const { env, supa, om, subjectId, userId } = p;
  const amount = Math.trunc(p.amountMicros);
  if (!Number.isFinite(amount) || amount <= 0) return { withdrawnMicros: 0 };
  // 原子缩 contributions + 减池,返回实际退出额(夹到 share_now & 池)
  const { data } = await supa.rpc('apply_partial_withdraw', {
    p_subject_id: subjectId, p_user_id: userId, p_amount_micros: amount,
  });
  const withdrawn = Number(data ?? 0);
  if (withdrawn <= 0) return { withdrawnMicros: 0 };
  const rid = crypto.randomUUID();
  // 群侧出账(Polar 群减 + DO 缓存 + 审计)
  await supa.from('pnc_ledger').insert({
    subject_id: subjectId, kind: 'refund', source: 'group_withdraw',
    external_ref: rid, delta_pnc_micros: -withdrawn, raw: { contributor_user_id: userId },
  });
  await om.reduceCredits(subjectId, withdrawn, { source: 'group_withdraw', dedupeId: `gwd-out:${rid}` });
  await wallet.debit(env, subjectId, withdrawn, { category: 'group_withdraw', dedupeId: `gwd-out:${rid}` });
  // 用户侧入账(credit-in 幂等 + DO 缓存)
  await recordCreditIn(supa, om, {
    subjectId: userId, kind: 'topup', source: 'group_withdraw', externalRef: rid,
    pncMicros: withdrawn, raw: { withdrawn_from_subject_id: subjectId },
  });
  await wallet.credit(env, userId, withdrawn);
  return { withdrawnMicros: withdrawn };
}
```

- [ ] **Step 4: 跑确认通过** — 同 Step 2 命令 → PASS
- [ ] **Step 5: Commit** — `git add apps/edge/src/billing/group-wallet.ts apps/edge/src/billing/group-wallet.test.ts && git commit -m "feat(billing): 认缴读写 setPledge/getActivePledges + 部分取出 withdrawFromGroup"`

---

## Task 3: resolveGroupStakes + settleGroupSpend(认缴分账核心)

**Files:** Modify `apps/edge/src/billing/group-wallet.ts`;Test 同文件

- [ ] **Step 1: 写失败测试**

```ts
import { resolveGroupStakes, settleGroupSpend } from './group-wallet';

describe('resolveGroupStakes', () => {
  it('S = 实缴池 + Σ认缴 min(pledge,余额)', async () => {
    const db = makeFakeDb({ group_pledges: [{ subject_id: GROUP, user_id: 'u_bob', pledge_pnc_micros: 40_000_000, status: 'active' }] });
    // 群池 60M(group WalletDO 余额),Bob 认缴 40M、余额 100M → 认缴份额 40M
    const { env, supa } = ctx(db, { [GROUP]: 60_000_000, u_bob: 100_000_000 });
    const s = await resolveGroupStakes(env, supa, GROUP);
    expect(s.poolStake).toBe(60_000_000);
    expect(s.pledgeStakes).toEqual([{ userId: 'u_bob', stakeMicros: 40_000_000 }]);
    expect(s.total).toBe(100_000_000);
  });
  it('认缴成员余额低于 pledge → 份额缩到余额', async () => {
    const db = makeFakeDb({ group_pledges: [{ subject_id: GROUP, user_id: 'u_bob', pledge_pnc_micros: 40_000_000, status: 'active' }] });
    const { env, supa } = ctx(db, { [GROUP]: 60_000_000, u_bob: 10_000_000 });
    const s = await resolveGroupStakes(env, supa, GROUP);
    expect(s.pledgeStakes[0].stakeMicros).toBe(10_000_000);
    expect(s.total).toBe(70_000_000);
  });
});

describe('settleGroupSpend', () => {
  it('按占比拆:实缴池衰减 + 认缴成员个人钱包直扣', async () => {
    const db = makeFakeDb({
      group_pledges: [{ subject_id: GROUP, user_id: 'u_bob', pledge_pnc_micros: 40_000_000, status: 'active' }],
      group_pools: [{ subject_id: GROUP, total_remaining_pnc_micros: 60_000_000, share_index: 1 }],
    });
    const decay = vi.fn(() => ({ data: null }));
    db.rpcs = { apply_group_pool_spend: decay };
    // 池 60M + Bob 40M = S 100M;花 X=10M → 池摊 6M、Bob 摊 4M
    const { env, supa, wallet } = ctx(db, { [GROUP]: 60_000_000, u_bob: 40_000_000 });
    await settleGroupSpend({ env, supa, om: fakeOm(), subjectId: GROUP, spendMicros: 10_000_000, category: 'llm_tokens', dedupeId: 'audit1' });
    // 池扣 6M
    expect(wallet.calls.find((c) => c.subjectId === GROUP && c.path === '/debit')?.body.pncMicros).toBe(6_000_000);
    expect(decay).toHaveBeenCalledWith({ p_subject_id: GROUP, p_spend_micros: 6_000_000 });
    // Bob 个人钱包扣 4M
    expect(wallet.calls.find((c) => c.subjectId === 'u_bob' && c.path === '/debit')?.body.pncMicros).toBe(4_000_000);
  });
});
```

- [ ] **Step 2: 跑确认失败**

- [ ] **Step 3: 实现**

```ts
export interface GroupStakes {
  poolStake: number;                                   // 实缴池余额(群 WalletDO)
  pledgeStakes: { userId: string; stakeMicros: number }[]; // 认缴 min(pledge,余额)
  total: number;                                       // S
}

/** 读群当前分账份额:实缴池(群 WalletDO 余额) + 各认缴成员 min(pledge, 个人余额)。 */
export async function resolveGroupStakes(env: Env, supa: Supa, subjectId: string): Promise<GroupStakes> {
  const poolGate = await wallet.gate(env, subjectId);
  const poolStake = Math.max(0, poolGate.balanceMicros);
  const pledges = await getActivePledges(supa, subjectId);
  const pledgeStakes: { userId: string; stakeMicros: number }[] = [];
  for (const pl of pledges) {
    const g = await wallet.gate(env, pl.userId);
    const stake = Math.max(0, Math.min(pl.pledgeMicros, g.balanceMicros));
    if (stake > 0) pledgeStakes.push({ userId: pl.userId, stakeMicros: stake });
  }
  const total = poolStake + pledgeStakes.reduce((s, x) => s + x.stakeMicros, 0);
  return { poolStake, pledgeStakes, total };
}

export interface SettleGroupParams {
  env: Env; supa: Supa; om: PolarClient;
  subjectId: string; spendMicros: number;
  category: string; dedupeId: string; meta?: Record<string, unknown>;
}
/** 群消费分账:实缴池摊 X·池/S(衰减 share_index),认缴成员各摊 X·份额/S(直扣个人钱包)。 */
export async function settleGroupSpend(p: SettleGroupParams): Promise<void> {
  const { env, supa, subjectId } = p;
  const spend = Math.trunc(p.spendMicros);
  if (!Number.isFinite(spend) || spend <= 0) return;
  const { poolStake, pledgeStakes, total } = await resolveGroupStakes(env, supa, subjectId);
  if (total <= 0) {
    // 没有任何可摊份额:整笔记在群池(透支),保持与无认缴时一致的兜底
    await wallet.debit(env, subjectId, spend, { category: p.category, dedupeId: p.dedupeId, meta: p.meta });
    await applyGroupSpendDecay(supa, subjectId, spend);
    return;
  }
  // 实缴池部分
  const poolPortion = Math.round((spend * poolStake) / total);
  if (poolPortion > 0) {
    await wallet.debit(env, subjectId, poolPortion, { category: p.category, dedupeId: p.dedupeId, meta: p.meta });
    await applyGroupSpendDecay(supa, subjectId, poolPortion);
  }
  // 认缴成员部分:各自个人钱包直扣(个人 WalletDO 串行权威)
  for (const m of pledgeStakes) {
    const portion = Math.round((spend * m.stakeMicros) / total);
    if (portion <= 0) continue;
    try {
      await wallet.debit(env, m.userId, portion, {
        category: p.category,
        dedupeId: `${p.dedupeId}:pledge:${m.userId}`,
        meta: { ...(p.meta ?? {}), group_subject_id: subjectId, via: 'pledge' },
      });
    } catch (e) {
      console.warn('[group-wallet] pledge debit failed', subjectId, m.userId, (e as Error)?.message);
    }
  }
}
```

- [ ] **Step 4: 跑确认通过**(rounding:测试用整除值避免 ±1)
- [ ] **Step 5: Commit** — `git commit -m "feat(billing): settleGroupSpend 按份额拆实缴池衰减 + 认缴个人钱包直扣"`

---

## Task 4: 热路径改用 settleGroupSpend

**Files:** Modify `llm/router.ts`、`durable-objects/room-voice.ts`、`lib/sandbox.ts`;Test 各自 billing 测试

群消费当前是 `wallet.debit(env, groupSubjectId, X)` + `applyGroupSpendDecay`。改为:**群(kind=subject)走 `settleGroupSpend`;个人(kind=user)保持 `wallet.debit`**。

- [ ] **Step 1: router.ts** — 在 `persistAuditMessage` debit 块:把 `billingTarget.kind === 'subject'` 的 LLM/web-tools 扣费改走 `settleGroupSpend`(每笔传 category/dedupeId);删掉原先块末的 `applyGroupSpendDecay`(已并入 settleGroupSpend)。个人分支不变。

```ts
// 取代原 if (initialBilling==='billed' && billingTarget) {...} 内的扣费逻辑:
if (initialBilling === 'billed' && billingTarget) {
  const subjectId = billingTarget.subjectId;
  const isGroup = billingTarget.kind === 'subject';
  const modelCategory = opts.taskType === 'voice_call' ? 'voice_tokens' : 'llm_tokens';
  const llmMicros = usdToPncMicros(llmCost ?? 0);
  const charge = async (micros: number, category: string, dedupeId: string, meta: Record<string, unknown>) => {
    if (micros <= 0) return;
    if (isGroup) {
      await settleGroupSpend({ env, supa, om: polarFromEnv({ POLAR_ACCESS_TOKEN: env.POLAR_ACCESS_TOKEN!, POLAR_SERVER: env.POLAR_SERVER }, env.POLAR_PNC_METER_ID!), subjectId, spendMicros: micros, category, dedupeId, meta });
    } else {
      await wallet.debit(env, subjectId, micros, { category, dedupeId, meta });
    }
  };
  try { await charge(llmMicros, modelCategory, auditId, { model_id: route?.modelToCall ?? opts.tag ?? '<unrouted>', task_type: opts.taskType, conversation_id: opts.conversationId ?? null }); }
  catch (err) { console.warn('[charge llm]', auditId, err instanceof Error ? err.message : String(err)); }
  for (let i = 0; i < toolCalls.length; i++) {
    const micros = usdToPncMicros(toolCalls[i].costUsd ?? 0);
    try { await charge(micros, 'web_tools', `${auditId}:tool:${i}`, { provider: toolCalls[i].provider, conversation_id: opts.conversationId ?? null }); }
    catch (err) { console.warn('[charge web_tools]', auditId, err instanceof Error ? err.message : String(err)); }
  }
}
```
（`settleGroupSpend` 内部已对 om/polar 配置缺失友好——若 env 无 Polar 配置,polarFromEnv 会抛;故 charge 群分支先判 `env.POLAR_ACCESS_TOKEN && env.POLAR_PNC_METER_ID`,缺则退回 `wallet.debit(group)` + `applyGroupSpendDecay`。把这个判断写进 charge。）

- [ ] **Step 2: room-voice.ts** — `settleRealtimeKitMediaCost` 里群(owner.kind==='subject')改走 `settleGroupSpend`(category `realtimekit_media`, dedupeId `${roomId}:realtimekit_media`),删原 `wallet.debit(group)+applyGroupSpendDecay`;个人保持。om 由 `polarFromEnv` 构造(DO 内有 env)。
- [ ] **Step 3: sandbox.ts** — 群(subjectId !== meter.userId)改走 `settleGroupSpend`(category `sandbox_runtime`),删原 decay;个人保持。
- [ ] **Step 4: 改/加测试** — router-billing / sandbox / wallet-client 相关:群会话断言"池扣 X·池/S + 认缴成员个人扣";个人会话断言原样 `wallet.debit(user,X)`。
- [ ] **Step 5: 全量** — `bun --filter='@pendingbot/edge' run typecheck && cd apps/edge && ./node_modules/.bin/vitest run` 全绿
- [ ] **Step 6: Commit** — `git commit -m "feat(billing): 群消费热路径(LLM/语音/sandbox)改走 settleGroupSpend(实缴池+认缴分账)"`

---

## Task 5: 门禁聚合认缴可用额

**Files:** Modify `billing/usage-gate.ts`、`lib/billing.ts`;Test `lib/billing.test.ts` / `usage-gate.test.ts`

- [ ] **Step 1: 写测试** — 群门禁:`可用 = 实缴池 + Σ认缴 min(pledge,余额)`;聚合 ≤0 → exhausted/拒。
- [ ] **Step 2: 实现 `availableForSubject`(usage-gate.ts)**

```ts
import { resolveGroupStakes } from './group-wallet';
import { thresholdOf } from '../durable-objects/wallet';

/** 主体可用额:个人=其 WalletDO;群=实缴池 + Σ认缴 min(pledge,余额)。 */
export async function availableForSubject(
  env: Env, supa: SupabaseClient, target: BillingTarget,
): Promise<{ balanceMicros: number; thresholdState: ThresholdState }> {
  if (target.kind === 'user') {
    const g = await wallet.gate(env, target.subjectId);
    return { balanceMicros: g.balanceMicros, thresholdState: g.thresholdState };
  }
  const { total } = await resolveGroupStakes(env, supa, target.subjectId);
  return { balanceMicros: total, thresholdState: thresholdOf(total) };
}
```

- [ ] **Step 3: gateUsage 群分支改用 availableForSubject**(替换原 `wallet.gate(target.subjectId)`),`exhausted` 仍抛 `InsufficientBalanceError`。
- [ ] **Step 4: lib/billing.ts `requireBalance`/`getBalanceGateState` 群分支改用 availableForSubject**(个人不变;DO 读失败 fail-open 保留)。
- [ ] **Step 5: typecheck + 测试**(注意 group-wallet ↔ usage-gate 循环依赖:`resolveGroupStakes` 在 group-wallet,usage-gate 导入它;group-wallet 不导入 usage-gate,无环)
- [ ] **Step 6: Commit** — `git commit -m "feat(billing): 群门禁聚合实缴池+认缴可用额"`

---

## Task 6: 端点 /pledge + /withdraw

**Files:** Modify `routes/group-subjects.ts`;复用 Task 5 前的成员校验模式

- [ ] **Step 1: `POST /:id/pledge {pnc}`** — 成员校验(RLS 读自己 membership)→ `setPledge(serviceClient, id, userId, pncToMicros(pnc))`(pnc=0 撤销)→ `{ ok, pledge_pnc: pnc }`。无需 Polar(不动钱)。
- [ ] **Step 2: `POST /:id/withdraw {pnc}`** — 成员校验 → `om=polarOrNull(env)`(缺→501)→ `withdrawFromGroup({env, supa:serviceClient, om, subjectId:id, userId, amountMicros:pncToMicros(pnc)})` → `{ ok, withdrawn_pnc: pncMicrosToPnc(r.withdrawnMicros) }`。
- [ ] **Step 3: 注释更新**(文件头路由清单加 /pledge /withdraw)
- [ ] **Step 4: typecheck**
- [ ] **Step 5: Commit** — `git commit -m "feat(edge): 群钱包 /pledge(认缴设/清) + /withdraw(部分取出)端点"`

---

## Task 7: 尾巴 — 链式退款 + 漂移报警 + leave 删行

**Files:** `routes/billing-webhooks.ts`、`durable-objects/wallet.ts`、`routes/group-subjects.ts`

- [ ] **Step 1: 链式退款**(billing-webhooks 退款分支) — 退款 externalRef 命中的入账若有对应 `group_contributions`(该 user 实缴进群):按 `computeShareNow` 算当前 `share_now`,`reduceCredits(group, min(refund, share_now))` + `apply_group_refund` + 标记该 contribution refunded;超出 share_now 部分记 `chargeback_loss` 审计(pnc_ledger kind='refund' source='chargeback_loss')。测试:进群的注资被退 → 群池按 share_now 冲减、不双退。
- [ ] **Step 2: 漂移报警**(wallet.ts alarm 对账段) — 若该 subject 有 group_pools 行,比对 Polar 余额与 `total_remaining_pnc_micros`,差 > `MICROS_PER_PNC` 则 `console.warn`(不自动改写,避免与 share_index 失配)。需 DO 内 `serviceClient(env)`。
- [ ] **Step 3: /leave 联动删 membership** — `/leave` 退款成功后调既有 `grp_remove_member`(若允许自移除)或记 tech-debt 说明仍需手动 DELETE /members。测试退款仍 200。
- [ ] **Step 4: typecheck + 测试**
- [ ] **Step 5: Commit** — `git commit -m "feat(billing): 链式退款命中群注资 + 群池漂移报警 + leave 删成员行"`

---

## Task 8: 退役 billing-v2 死代码(#209)

**Files:** 删 `lib/billing-v2-group.ts`(逻辑已迁)、`lib/billing-v2.ts` 的 settleUsage/settleManyUsage/packs/applyGroupPoolSpend、`lib/billing-v2-pack.ts`、pack 过期 cron(`cron/billing-v2-sweep.ts`/`billing-v2-expiry.ts`/`billing-v2-tasks.ts`)、旧入账 `billing-v2-lemon.ts`/`billing-v2-iap.ts` + `billing-webhooks.ts` 的 `/lemonsqueezy/webhook`·`/iap/*` 路由、`group-subjects.ts` 残留 `grp_topup_wallet` 调用。**保留** pnc_ledger、group_pools/contributions/pledges、Polar/RC 入账、subject_wallets 若别处仍用(先 grep 确认)。

- [ ] **Step 1: grep 确认无 live 调用** — `grep -rn "settleUsage\|settleManyUsage\|grp_topup_wallet\|billing-v2-lemon\|billing-v2-iap\|billing-v2-group" apps/edge/src | grep -v ".test.ts"` 只剩将删文件内部。
- [ ] **Step 2: 删/改 + 移除路由挂载 + 清对应测试**
- [ ] **Step 3: typecheck + 全量 vitest 全绿**
- [ ] **Step 4: Commit** — `git commit -m "chore(billing): 退役 billing-v2 用量/packs/旧入账,收敛到 Polar+WalletDO"`
- [ ] **Step 5: 账本** — 关 #209/#210;tech-debt/progress 更新

---

## Task 9: 验证

- [ ] **Step 1: 全量** — `bun --filter='@pendingbot/edge' run typecheck` + `vitest run` 全绿
- [ ] **Step 2: 真 Polar sandbox spike**(扩 `scripts/polar-verify.ts`):建 2 个个人 customer + 1 群 customer;实缴 contribute + 认缴 settleGroupSpend(验证群 customer 减 + 认缴 customer 减,和 = X)+ 部分取出 + 退款。核对 `getStateExternal` 余额。
- [ ] **Step 3: 记录 spike 结论 + 更新 spec 状态为已验证**

---

## Self-Review

**Spec 覆盖:** 实缴池+share-index(已建)✓;部分取出(T2/T6)✓;认缴 group_pledges+动态份额(T1/T2/T3)✓;消费直扣(T3/T4)✓;余额降自动缩(resolveGroupStakes min(pledge,余额))✓;欠费隔离(stake=0 退出 S)✓;多群复用(各群独立读个人余额,先到先得)✓;门禁聚合(T5)✓;个人 WalletDO 串行(沿用现有 per-subject DO,认缴扣经个人 DO)✓;链式退款/漂移/leave(T7)✓;退役(T8)✓。

**Placeholder:** 无 TBD;竞态残余缺口(spec §12)在 settleGroupSpend 用 try/catch 吞 + 后续可加 chargeback——本计划不展开,留 tech-debt。

**类型一致:** `settleGroupSpend`/`resolveGroupStakes`/`withdrawFromGroup`/`setPledge`/`getActivePledges`/`availableForSubject` 各处签名一致;micros 全程整数。

**留意:** Task 4 个人 WalletDO 即"认缴成员的 WalletDO"——本仓库已是 per-subject(含 user)一个 DO,认缴扣 `wallet.debit(env, userId, …)` 天然落到该用户 DO、单线程串行,spec §7 的"个人 WalletDO 串行权威"已被现有架构满足,无需额外建 DO。
