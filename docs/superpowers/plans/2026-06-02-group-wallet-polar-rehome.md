# 群钱包 share-index 重挂到 Polar/WalletDO Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 billing-v2 设计文档 §9 的"群钱包 share-index 池"模型，从旧的本地 packs/ledger + subject_wallets 余额实现，重挂到 P2 的 Polar(余额事实源)+ WalletDO(边缘缓存) 之上，并退役重叠的旧群余额系统。

**Architecture:** 群 subject = 一个 Polar customer(external_id = subjectId)，余额 SoR 在 Polar，WalletDO 缓存。`group_pools.total_remaining_pnc_micros` 从"余额事实源"降级为 **公平性镜像 + share-index 衰减基数**；`group_contributions` 仍记每笔注资的 `share_index_at_join`。注资/退款 = Polar 内部转账(reportUsage 扣出方 + grantCredits 入账方) + 两侧 WalletDO 同步 + pnc_ledger 审计；群消费在已有 WalletDO debit 之上额外触发一次原子 share-index 衰减。退款仍走 `share_now = contributed × 当前 share_index / join 时 share_index`(纯数学不变)。

**Tech Stack:** Cloudflare Workers + Hono + TS;Supabase(Postgres schema `pendingbot`);Polar `@polar-sh/sdk`;现有 `apps/edge/src/billing/{polar-client,wallet-client,pnc,billing-polar}.ts` + `durable-objects/wallet.ts`;vitest。

**关键单位约定(已核实):** 本仓库 `reportUsage/grantCredits/reduceCredits` 的 `pnc` 形参实际传 **micros**(Polar meter 按 `metadata.pnc` 求和，全链路 micros，G 阶段已核 `CustomerStateMeter.balance` = micros)。本计划所有金额一律 micros。

**官方文档铁律:** 接 Polar/SDK 一律查 `@polar-sh/sdk` 生成类型，不凭印象。

---

## 背景：当前三套并存余额系统(必须收敛到一套)

| 系统 | 表/RPC | 现状 |
|---|---|---|
| subject_wallets(subject 基础) | `subject_wallets.balance_credits` + `grp_topup_wallet` RPC | `/v1/group-subjects/:id/topup` 在用;credits 单位非 PNC micros |
| billing-v2 packs | `packs`(owner_subject_id) + `group_pools` + `group_contributions` + `ledger_entries` | `contributeToGroup/refund/dissolve`(billing-v2-group.ts)**全是孤儿无调用方** |
| **Polar + WalletDO(P2 目标)** | Polar meter + `WalletDO` + `pnc_ledger` | 群消费已扣群 subject WalletDO;**但无成员摊派/share-index** |

**收敛目标:** 群余额唯一 SoR = Polar(WalletDO 缓存)。`group_pools`/`group_contributions` 保留作公平性账。`subject_wallets.balance_credits` 与 billing-v2 `packs` 在群路径上退役。

---

## File Structure

- **Create** `apps/edge/src/billing/share-index.ts` — 纯 share-index 数学(从 billing-v2-group.ts 抽出 `computeShareNow`/`decayShareIndex`，无 DB 依赖)。
- **Create** `apps/edge/src/billing/group-wallet.ts` — 新群钱包模块:`contributeToGroup`/`refundContributorFromGroup`/`dissolveGroup`/`applyGroupSpendDecay`，全部走 Polar + WalletDO + share-index + pnc_ledger。
- **Create** `supabase/migrations/<ts>_group_pool_polar_rehome.sql` — `apply_group_pool_spend(subject_id,x)` 原子衰减 RPC + `apply_group_contribution` + `apply_group_refund` 原子池更新 RPC。
- **Modify** `apps/edge/src/llm/router.ts` + `durable-objects/realtime-meter.ts` + `durable-objects/room-voice.ts` + `lib/sandbox.ts` — 群 debit 后触发 `applyGroupSpendDecay`(仅当 target 是群 subject)。
- **Modify** `apps/edge/src/routes/group-subjects.ts` — `/topup` 改调新 `contributeToGroup`;新增 `/leave`(退款)+`/dissolve`。
- **Modify** `apps/edge/src/routes/billing-webhooks.ts` — G 退款路径补"链式退款"(注资已进群时按 share_now 冲减群)。
- **Modify** `apps/edge/src/routes/me.ts` — `/wallet/v2` 余额改读 WalletDO/Polar。
- **Delete** `apps/edge/src/lib/billing-v2-group.ts`(逻辑迁入 group-wallet.ts + share-index.ts)。
- **Retire(后置任务)** billing-v2 packs/settleUsage 死代码 + 旧 pack cron + 旧入账 lemon/iap 路由(见 Task 9，与 #209 合并)。

---

## Task 1: 抽出纯 share-index 数学

**Files:**
- Create: `apps/edge/src/billing/share-index.ts`
- Test: `apps/edge/src/billing/share-index.test.ts`

- [ ] **Step 1: 写失败测试**

```ts
import { describe, expect, it } from 'vitest';
import { computeShareNow, decayShareIndex } from './share-index';

describe('share-index math', () => {
  it('computeShareNow floors to avoid over-refund', () => {
    // 注资 100 micros，join 时 index=1.0，当前 index=0.5 → 还剩 50
    expect(computeShareNow(100, 1.0, 0.5)).toBe(50);
    // 晚注资者 join index 已是 0.5，当前还是 0.5 → 不沾历史消耗，全额
    expect(computeShareNow(100, 0.5, 0.5)).toBe(100);
  });
  it('computeShareNow guards bad input', () => {
    expect(computeShareNow(100, 0, 0.5)).toBe(0);
    expect(computeShareNow(-5, 1, 1)).toBe(0);
    expect(computeShareNow(100, 1, -1)).toBe(0);
  });
  it('decayShareIndex shrinks proportionally', () => {
    // 池 1000 花 200 → 新 index = 1.0 * 800/1000 = 0.8
    expect(decayShareIndex(1000, 800, 1.0)).toBeCloseTo(0.8, 10);
  });
  it('decayShareIndex resets to 1 when pool empties', () => {
    expect(decayShareIndex(1000, 0, 0.8)).toBe(1);
    expect(decayShareIndex(1000, -5, 0.8)).toBe(1);
  });
});
```

- [ ] **Step 2: 跑测试确认失败** — `cd apps/edge && ./node_modules/.bin/vitest run src/billing/share-index.test.ts` → FAIL(模块不存在)。

- [ ] **Step 3: 实现** — 把 billing-v2-group.ts 的 `computeShareNow` + `decayShareIndex` 原样搬入新文件(它们已无 DB 依赖，逻辑正确)：

```ts
// 纯 share-index 数学(DeFi 质押池模型)。见 docs/billing-v2-design.md §9。
export function computeShareNow(
  contributedPncMicros: number,
  shareIndexAtJoin: number,
  currentShareIndex: number,
): number {
  if (!Number.isFinite(shareIndexAtJoin) || shareIndexAtJoin <= 0) return 0;
  if (!Number.isFinite(currentShareIndex) || currentShareIndex < 0) return 0;
  if (contributedPncMicros <= 0) return 0;
  return Math.max(0, Math.floor(contributedPncMicros * (currentShareIndex / shareIndexAtJoin)));
}

export function decayShareIndex(oldTotal: number, newTotal: number, oldShareIndex: number): number {
  if (newTotal <= 0) return 1;
  if (oldTotal <= 0) return oldShareIndex;
  return (oldShareIndex * newTotal) / oldTotal;
}
```

- [ ] **Step 4: 跑测试确认通过** — 同 Step 2 命令 → PASS。

- [ ] **Step 5: Commit** — `git add apps/edge/src/billing/share-index.ts apps/edge/src/billing/share-index.test.ts && git commit -m "feat(billing): 抽出纯 share-index 数学到 billing/share-index.ts"`

---

## Task 2: 原子池更新迁移(RPC)

**Files:**
- Create: `supabase/migrations/<ts>_group_pool_polar_rehome.sql`(用 `supabase migration new group_pool_polar_rehome` 生成时间戳前缀)

**为什么要 RPC:** 群消费衰减是 read-then-write(读 total → 算 ratio → 写 total+index)，并发群消费会丢更新。放进单条 SQL/PL 函数里原子化。注资/退款同理。

- [ ] **Step 1: 写迁移**

```sql
-- 群池原子操作(Polar/WalletDO 重挂)。group_pools.total_remaining_pnc_micros
-- 是公平性镜像(余额 SoR 在 Polar);这些函数只维护镜像 + share_index。
set search_path = pendingbot, public;

-- 群消费:total -= x; share_index *= (new/old)，池空则 index 重置 1.0。
create or replace function pendingbot.apply_group_pool_spend(
  p_subject_id uuid, p_spend_micros bigint
) returns void language plpgsql security definer as $$
declare v_old bigint; v_idx numeric(40,20); v_new bigint;
begin
  if p_spend_micros <= 0 then return; end if;
  select total_remaining_pnc_micros, share_index into v_old, v_idx
    from pendingbot.group_pools where subject_id = p_subject_id for update;
  if not found then
    -- 群池尚未 bootstrap(成员还没注资就发生了消费):建一个 0 池，消费记为透支基。
    insert into pendingbot.group_pools(subject_id, total_remaining_pnc_micros, share_index)
      values (p_subject_id, 0, 1) on conflict (subject_id) do nothing;
    return;
  end if;
  v_new := v_old - p_spend_micros;
  update pendingbot.group_pools set
    total_remaining_pnc_micros = v_new,
    share_index = case when v_new <= 0 then 1
                       when v_old <= 0 then v_idx
                       else v_idx * v_new / v_old end,
    updated_at = now()
  where subject_id = p_subject_id;
end $$;

-- 注资:total += amount。返回 join 时 share_index(供 contribution 快照)。
create or replace function pendingbot.apply_group_contribution(
  p_subject_id uuid, p_amount_micros bigint
) returns numeric language plpgsql security definer as $$
declare v_idx numeric(40,20);
begin
  insert into pendingbot.group_pools(subject_id, total_remaining_pnc_micros, share_index)
    values (p_subject_id, p_amount_micros, 1)
    on conflict (subject_id) do update set
      total_remaining_pnc_micros = pendingbot.group_pools.total_remaining_pnc_micros + excluded.total_remaining_pnc_micros,
      updated_at = now()
    returning share_index into v_idx;
  return coalesce(v_idx, 1);
end $$;

-- 退款:total -= refunded(share_index 不变)。夹到 >=0。
create or replace function pendingbot.apply_group_refund(
  p_subject_id uuid, p_refund_micros bigint
) returns void language plpgsql security definer as $$
begin
  update pendingbot.group_pools set
    total_remaining_pnc_micros = greatest(0, total_remaining_pnc_micros - p_refund_micros),
    updated_at = now()
  where subject_id = p_subject_id;
end $$;

revoke all on function pendingbot.apply_group_pool_spend(uuid,bigint) from public, anon, authenticated;
revoke all on function pendingbot.apply_group_contribution(uuid,bigint) from public, anon, authenticated;
revoke all on function pendingbot.apply_group_refund(uuid,bigint) from public, anon, authenticated;
```

- [ ] **Step 2: 应用迁移**(主 worktree)— `supabase db push --linked < /dev/null`

- [ ] **Step 3: regen schema** — `bun --filter='@pendingbot/edge' run types:db`

- [ ] **Step 4: typecheck** — `bun --filter='@pendingbot/edge' run typecheck` → 0

- [ ] **Step 5: Commit** — `git add supabase/migrations/*group_pool_polar_rehome.sql apps/edge/src/db/schema.ts && git commit -m "feat(db): 群池原子 RPC(spend 衰减 / contribute / refund)用于 Polar 重挂"`

---

## Task 3: group-wallet.ts 模块(Polar/WalletDO 版)

**Files:**
- Create: `apps/edge/src/billing/group-wallet.ts`
- Test: `apps/edge/src/billing/group-wallet.test.ts`

**接口(全部 micros):**

```ts
import type { Env } from '../types';
import type { SupabaseClient } from '../lib/supabase';
import type { PolarClient } from './polar-client';
import { wallet } from './wallet-client';
import { computeShareNow } from './share-index';

export interface ContributeParams {
  env: Env; supa: SupabaseClient; om: PolarClient;
  subjectId: string;            // 群 subject(= Polar customer external_id)
  contributorUserId: string;    // 出资人(= 其个人 Polar external_id)
  pncMicros: number;
}
export type ContributeResult =
  | { ok: true; contributionId: string; debitedMicros: number }
  | { ok: false; reason: 'insufficient_balance' | 'invalid_amount' | 'db_error'; message?: string };

export async function contributeToGroup(p: ContributeParams): Promise<ContributeResult>;

export interface RefundParams {
  env: Env; supa: SupabaseClient; om: PolarClient;
  subjectId: string; contributorUserId: string;
}
export type RefundResult =
  | { ok: true; refundedMicros: number; contributionsRefunded: number }
  | { ok: false; reason: 'no_contributions' | 'pool_missing' | 'db_error'; message?: string };

export async function refundContributorFromGroup(p: RefundParams): Promise<RefundResult>;
export async function dissolveGroup(p: { env: Env; supa: SupabaseClient; om: PolarClient; subjectId: string }):
  Promise<{ ok: true; refundedContributors: number; totalRefundedMicros: number }>;

/** 群消费后衰减 share_index(仅群 subject 调用)。best-effort，失败只 log。 */
export async function applyGroupSpendDecay(supa: SupabaseClient, subjectId: string, spendMicros: number): Promise<void>;
```

**contributeToGroup 逻辑(替换 billing-v2-group.ts 的 packs 实现):**
1. 校验 `pncMicros>0`，否则 `invalid_amount`。
2. 余额预检:`const g = await wallet.gate(env, contributorUserId)`;若 `g.balanceMicros < pncMicros` → `insufficient_balance`(转账不允许透支)。
3. **扣出资人 Polar**:`await om.reportUsage(contributorUserId, pncMicros, { category: 'group_topup', dedupeId: \`gtopup:${subjectId}:${contributorUserId}:${nonce}\` })`(nonce 见下"幂等"note)。同步缓存:`await wallet.debit(env, contributorUserId, pncMicros, { category: 'group_topup', dedupeId: <同上> })`。
4. **入账群 Polar**:`await om.grantCredits(subjectId, pncMicros, { source: 'group_topup', dedupeId: \`gtopup-in:...\` })`。同步缓存:`await wallet.credit(env, subjectId, pncMicros)`。
5. `const joinIdx = await supa.rpc('apply_group_contribution', { p_subject_id: subjectId, p_amount_micros: pncMicros })`(返回 join 时 share_index)。
6. `INSERT group_contributions { subject_id, contributor_user_id, contributed_pnc_micros: pncMicros, share_index_at_join: joinIdx, status:'active' }` → contributionId。
7. pnc_ledger 审计两行(出/入)。返回 `{ ok:true, contributionId, debitedMicros: pncMicros }`。

**refundContributorFromGroup 逻辑:**
1. 读 `group_pools`(share_index, total)。无 → `pool_missing`。
2. 读该 user 在该群 active `group_contributions`。空 → `no_contributions`。
3. `refundMicros = min( Σ computeShareNow(contributed, idx_at_join, currentIdx), poolTotal )`(防超提)。
4. 若 `refundMicros>0`:**扣群 Polar** `om.reduceCredits(subjectId, refundMicros, {source:'group_refund', dedupeId})` + `wallet.debit(env, subjectId, refundMicros, {category:'group_refund', dedupeId})`;**入账 user Polar** `om.grantCredits(contributorUserId, refundMicros, {source:'group_refund', dedupeId})` + `wallet.credit(env, contributorUserId, refundMicros)`;`supa.rpc('apply_group_refund', { p_subject_id, p_refund_micros: refundMicros })`。
5. 标记这些 contributions `status='refunded', refunded_at=now()`。
6. pnc_ledger 审计。返回 `{ ok:true, refundedMicros, contributionsRefunded }`。

**dissolveGroup:** bounded-loop(≤1000)取一个有 active contribution 的 user → refundContributorFromGroup，直到没有。累加返回。

**applyGroupSpendDecay:** `await supa.rpc('apply_group_pool_spend', { p_subject_id: subjectId, p_spend_micros: spendMicros })`;catch→`console.warn`。

**幂等 note(必须写进代码注释):** contribute 的 dedupeId 不能用纯 `subjectId:userId`(同一人多次注资会被 Polar 当重投吞掉)。用调用方传入的唯一 nonce(端点用 `crypto.randomUUID()`，webhook 用上游交易 id)。`group_contributions.id` 也可作为天然唯一键 —— 先 INSERT 拿 id 再用作 Polar dedupeId 亦可(更稳，推荐:先 insert contribution(pending)、用其 id 当 dedupeId、再 Polar、再置 active)。实现时择一并注释清楚。

- [ ] **Step 1: 写测试**(fake supa + fake om + fake wallet;覆盖:正常注资扣出资人入群池 + 余额不足拒 + 退款按 share_now 夹池 + 池空退 0 + dissolve 清空)。用 `tests/_helpers/fake-supabase.ts` 的 `makeFakeEnv` + 桩 WALLET(已有捕获式桩)。
- [ ] **Step 2: 跑测试确认失败**。
- [ ] **Step 3: 实现 group-wallet.ts**(按上方逻辑;reportUsage/grantCredits/reduceCredits 签名见 billing/polar-client.ts)。
- [ ] **Step 4: 跑测试确认通过**。
- [ ] **Step 5: Commit** — `git add apps/edge/src/billing/group-wallet.ts apps/edge/src/billing/group-wallet.test.ts && git commit -m "feat(billing): 群钱包 contribute/refund/dissolve/decay 走 Polar+WalletDO+share-index"`

---

## Task 4: 群消费衰减接入热路径

**Files:**
- Modify: `apps/edge/src/llm/router.ts`(persistAuditMessage debit 后)
- Modify: `apps/edge/src/durable-objects/realtime-meter.ts` + `room-voice.ts`(语音 debit 后)
- Modify: `apps/edge/src/lib/sandbox.ts`(sandbox debit 后)
- Test: 扩展各自 billing 测试

**判定"是群 subject":** P2 的 subject 解析器(router `resolveBillingSubjectId` / sandbox `resolveSandboxBillingSubjectId`)在 group/temporary_group/crew 时返回 `responsible_subject_id`(subject UUID)，个人返回 userId。需要一个明确的 `isGroup` 标志而非猜 UUID 形态 —— 解析器已知道走了哪个分支，让它额外返回 `{ subjectId, isGroup }`。

- [ ] **Step 1: 让 subject 解析器返回 `isGroup`**(router + sandbox 的 resolver 签名加 `isGroup: boolean`;群/临时群/crew 分支 = true，个人 = false)。改对应测试断言。
- [ ] **Step 2: debit 后衰减** — 每处 `wallet.debit(env, subjectId, micros, …)` 成功后，若 `isGroup`，`await applyGroupSpendDecay(supa, subjectId, micros)`(语音 DO 内若无 supa client 则用 `serviceClient(env)`)。web tools 多笔则逐笔衰减(或合计一次)。
- [ ] **Step 3: 测试** — 群会话一次 LLM debit 后断言 `apply_group_pool_spend` 被以正确 micros 调用;个人会话不调用。
- [ ] **Step 4: 跑全套 vitest** → 全绿。
- [ ] **Step 5: Commit** — `git commit -m "feat(billing): 群消费在 WalletDO 扣费后触发 share-index 衰减"`

---

## Task 5: 群钱包端点(contribute / leave / dissolve)

**Files:**
- Modify: `apps/edge/src/routes/group-subjects.ts`
- Test: 路由测试(若有 group-subjects 测试文件，否则新建最小测试)

- [ ] **Step 1: `/topup` 改调 contributeToGroup** — 把现有调 `grp_topup_wallet` 的 body(`{credits}`)换成 `{ pncMicros }` 或保留 credits 但内部换算;调 `contributeToGroup({ env, supa: serviceClient(env), om: polarFromEnv(...), subjectId: id, contributorUserId: c.var.userId, pncMicros })`;映射 `insufficient_balance→402 quota_exceeded`、`invalid_amount→400`。
- [ ] **Step 2: 新增 `POST /:id/leave`** — 调 `refundContributorFromGroup`(把 caller 移出群成员 + 退其份额);`no_contributions` 仍 200(直接退群)。
- [ ] **Step 3: 新增 `POST /:id/dissolve`**(仅 owner)— 调 `dissolveGroup` 后归档群。
- [ ] **Step 4: 测试** — contribute 余额不足 402;leave 退款额 = share_now。
- [ ] **Step 5: typecheck + commit** — `git commit -m "feat(edge): 群钱包 topup/leave/dissolve 端点接新 group-wallet"`

---

## Task 6: 链式退款(Apple/LS 退款命中已进群的注资)

**Files:**
- Modify: `apps/edge/src/routes/billing-webhooks.ts`(G 已建的退款分支)

**逻辑(billing-v2-design §9 链式退款):** Polar/RC 退款 webhook 命中的原始入账若曾 `contributeToGroup` 进过群:按 Apple 退款额反查该 user 的相关 contribution → 算 `share_now` → 群账户冲减 `share_now`(reduceCredits 群 + apply_group_refund)→ 该 contribution 置 refunded;**超出 share_now(已被群花掉)部分平台自担，不向其他成员追讨**，记 `chargeback_loss` 审计 + 标 `refund_risk=true`。

- [ ] **Step 1: 测试** — 一笔进过群的注资被退款 → 群池按 share_now 冲减、user 不重复退、超出部分记 chargeback_loss。
- [ ] **Step 2: 实现** — 退款路径检测 `pnc_ledger`/`group_contributions` 是否有该 externalRef 对应的群注资;有则走链式冲减,无则走普通 `recordRefund`。
- [ ] **Step 3: 跑测试 + typecheck**。
- [ ] **Step 4: Commit** — `git commit -m "feat(billing): Apple/LS 链式退款命中群注资按 share_now 冲减群池"`

> 若本任务超时，可拆为独立后续 task 并在 tech-debt 记"链式退款未覆盖群注资"——但**必须显式记录**，不能静默跳过(否则群退款会与平台退款双重退)。

---

## Task 7: me.ts 余额改读 WalletDO/Polar

**Files:**
- Modify: `apps/edge/src/routes/me.ts`(`/wallet/v2` + `/balance`)

- [ ] **Step 1: 测试** — `/wallet/v2` 返回的 balance 来自 WalletDO 桩而非 packs 求和。
- [ ] **Step 2: 实现** — `const g = await wallet.gate(c.env, subjectId)`;`balance_pnc_micros = g.balanceMicros`;`threshold_state = g.thresholdState`(去掉 `getThresholdState(packsSum)`)。账本明细仍可读 `pnc_ledger`(审计)。
- [ ] **Step 3: typecheck + commit** — `git commit -m "fix(edge): me.ts 钱包余额改读 WalletDO(替 packs 求和)"`

---

## Task 8: 漂移对账(group_pools 镜像 vs Polar)

**Files:**
- Modify: `apps/edge/src/durable-objects/wallet.ts`(alarm 稀疏对账段)

- [ ] **Step 1: 测试** — 群 subject 的 WalletDO 对账时，若 `group_pools.total_remaining` 与 Polar 余额偏差 > 1 PNC，`console.warn` 报警(不自动改写 group_pools，避免与 share_index 失配)。
- [ ] **Step 2: 实现** — alarm 既有 reconcile 段后加:若该 subject 有 group_pools 行，比对 `polarBalance` 与 `total_remaining_pnc_micros`，超阈值 log(留人工/后续 job 处理)。需要 DO 内 `serviceClient(env)`。
- [ ] **Step 3: 跑测试 + typecheck + commit** — `git commit -m "feat(billing): 群池镜像与 Polar 余额漂移报警"`

---

## Task 9: 退役旧群余额系统 + billing-v2 死代码(并 #209)

**Files:**
- Delete: `apps/edge/src/lib/billing-v2-group.ts` + 其测试(逻辑已迁 Task 1/3)
- Modify/Delete: `lib/billing-v2.ts`(settleUsage/settleManyUsage/packs/applyGroupPoolSpend dead)、`lib/billing-v2-pack.ts`、`cron/billing-v2-sweep.ts`/`billing-v2-expiry.ts`/`billing-v2-tasks.ts`(pack 过期 cron)、`lib/billing-v2-lemon.ts`(Lemon 已弃)、`lib/billing-v2-iap.ts`(RevenueCat 取代)及 `billing-webhooks.ts` 的 `/lemonsqueezy/webhook`+`/iap/*` 路由、`routes/group-subjects.ts` 的 `grp_topup_wallet` 调用。
- **保留:** `pnc_ledger`(审计)、`group_pools`/`group_contributions`(公平性账)、Polar/RC 入账。

- [ ] **Step 1: grep 确认无 live 调用** — `grep -rn "settleUsage\|settleManyUsage\|contributeToGroup.*billing-v2\|grp_topup_wallet\|billing-v2-lemon\|billing-v2-iap" apps/edge/src | grep -v ".test.ts"` 应只剩将删文件内部引用。
- [ ] **Step 2: 删/改** 上述文件,移除路由挂载。
- [ ] **Step 3: typecheck + 全套 vitest** → 全绿(删掉的测试一并清)。
- [ ] **Step 4: Commit** — `git commit -m "chore(billing): 退役 billing-v2 用量/packs/旧入账 + subject_wallets 群 topup,收敛到 Polar+WalletDO"`
- [ ] **Step 5: 更新 tech-debt/progress/tasks** — 关 #208/#209;tech-debt 标记群分摊重挂完成、删除"被旁路"🔴 条目。

---

## Self-Review 检查

- **Spec 覆盖(§9):** 注资✓(Task3/5) 查余额✓(Task7) 群消费自动扣✓(已 P2)+衰减✓(Task4) 余额不足节流✓(已 P2 gate) 退群按比例退✓(Task3/5) 解散按比例退✓(Task3/5) 链式退款✓(Task6) 不变量对账✓(Task8)。
- **单位:** 全程 micros;Polar `pnc` 形参传 micros(已核)。
- **幂等:** contribute/refund 的 Polar dedupeId 用 contribution.id / 唯一 nonce(Task3 note),不可用纯 subject:user。
- **并发:** 衰减/池更新走 Postgres `for update` RPC(Task2),不在应用层 read-then-write。
- **类型一致:** `applyGroupSpendDecay(supa,subjectId,micros)`、`computeShareNow(contrib,joinIdx,curIdx)`、`decayShareIndex(old,new,oldIdx)` 全计划一致。

---

## 待用户 / 外部依赖

- Polar 是否支持同 customer 既 grant 又 usage(转账双记)—— polar-client 已用 events.ingest 双向验证过(spike)。若实测群转账有异常，回退方案:用 Polar 的 customer balance adjustment API(需查 SDK)。
- 真实 product_id(billing-packs.ts)、Polar `customer.state_changed` webhook、token 轮换 —— 既有待办。
