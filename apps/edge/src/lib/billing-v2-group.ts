import type { SupabaseClient } from './supabase';
import {
  PACK_DEFAULT_EXPIRY_DAYS,
  defaultPackExpiresAt,
  getOwnerBalanceMicros,
} from './billing-v2';

// Group wallet helpers — see docs/billing-v2-design.md §9.
//
// The share-index model: every contribution snapshots share_index at the
// time of joining. As the group spends, share_index decays proportionally
// (handled in billing-v2.ts:applyGroupPoolSpend after settleUsage).
// Refund: share_now = contributed * (pool.share_index / share_index_at_join).
//
// Early contributors have higher share_index_at_join → smaller current
// ratio → more of their basis was eaten by spending. That's the fairness
// property: time-in-pool drives proportional consumption.

// ============================================================
// Pure share-index math
// ============================================================

/**
 * Compute a contribution's current basis: how many PNC micros Alice
 * would get back if she refunded RIGHT NOW.
 *
 * Floor (not round/ceil) so we never over-refund relative to group_pools.
 * The lost fraction stays in the group (negligible at any realistic scale).
 */
export function computeShareNow(
  contributedPncMicros: number,
  shareIndexAtJoin: number,
  currentShareIndex: number,
): number {
  if (!Number.isFinite(shareIndexAtJoin) || shareIndexAtJoin <= 0) return 0;
  if (!Number.isFinite(currentShareIndex) || currentShareIndex < 0) return 0;
  if (contributedPncMicros <= 0) return 0;
  const result = Math.floor(
    contributedPncMicros * (currentShareIndex / shareIndexAtJoin),
  );
  return Math.max(0, result);
}

/**
 * New share_index after a spend event. Returns 1.0 (reset) when the pool
 * empties — keeps refund math from dividing by ~0 for future contributions.
 */
export function decayShareIndex(
  oldTotal: number,
  newTotal: number,
  oldShareIndex: number,
): number {
  if (newTotal <= 0) return 1;
  if (oldTotal <= 0) return oldShareIndex;
  return (oldShareIndex * newTotal) / oldTotal;
}

// ============================================================
// Contribute (user → group)
// ============================================================

export interface ContributeParams {
  supa: SupabaseClient;
  subjectId: string;
  contributorUserId: string;
  pncMicros: number;
  metadata?: Record<string, unknown>;
}

export type ContributeResult =
  | { ok: true; contributionId: string; groupPackId: string; debited: number }
  | { ok: false; reason: 'insufficient_balance' | 'invalid_amount' | 'db_error'; message?: string };

/**
 * Transfer PNC from a user's wallet into a group subject's wallet.
 *
 * 1. Check user has >= pncMicros across active packs (no overdraft for transfers).
 * 2. FIFO-debit user packs (write 'group_topup' ledger per pack).
 * 3. UPSERT group_pools (total += amount; share_index unchanged).
 * 4. Create a group-side pack (sales_channel='group_topup', expires NULL —
 *    contributions don't expire while in the group). The pack exists for
 *    ledger consistency; the actual refund math reads group_pools / contributions.
 * 5. Insert a group_contributions row snapshotting share_index_at_join.
 * 6. Write group-side 'group_topup' credit ledger.
 *
 * Returns {ok:false, reason:'insufficient_balance'} without partial debit
 * — the precheck is best-effort but races could let a tiny over-spend
 * sneak through; we accept that gracefully (group ends up with a bit more,
 * user might briefly overdraft on next call — both are fine).
 */
export async function contributeToGroup(
  params: ContributeParams,
): Promise<ContributeResult> {
  const { supa, subjectId, contributorUserId, pncMicros } = params;
  if (!Number.isFinite(pncMicros) || pncMicros <= 0) {
    return { ok: false, reason: 'invalid_amount' };
  }

  const userBalance = await getOwnerBalanceMicros(supa, {
    kind: 'user',
    userId: contributorUserId,
  });
  if (userBalance < pncMicros) {
    return { ok: false, reason: 'insufficient_balance' };
  }

  // 1. FIFO-debit user packs.
  let stillOwed = pncMicros;
  let totalDebited = 0;
  let runningUserBalance = userBalance;
  let firstSourcePackId: string | null = null;

  for (let attempt = 0; attempt < 2 && stillOwed > 0; attempt++) {
    const { data: packs, error: packsErr } = await supa
      .from('packs')
      .select('id, remaining_pnc_micros')
      .eq('status', 'active')
      .eq('owner_user_id', contributorUserId)
      .order('expires_at', { ascending: true, nullsFirst: false })
      .order('created_at', { ascending: true })
      .limit(50);
    if (packsErr || !packs || packs.length === 0) break;

    let progressed = false;
    for (const pack of packs) {
      if (stillOwed <= 0) break;
      const debit = Math.min(Number(pack.remaining_pnc_micros), stillOwed);
      if (debit <= 0) continue;
      const newRemaining = Number(pack.remaining_pnc_micros) - debit;
      const { data: updated, error: updErr } = await supa
        .from('packs')
        .update({
          remaining_pnc_micros: newRemaining,
          status: newRemaining === 0 ? 'exhausted' : 'active',
        })
        .eq('id', pack.id)
        .gte('remaining_pnc_micros', debit)
        .select('id')
        .maybeSingle();
      if (updErr || !updated) continue;

      stillOwed -= debit;
      totalDebited += debit;
      runningUserBalance -= debit;
      progressed = true;
      if (firstSourcePackId === null) firstSourcePackId = pack.id;

      await supa.from('ledger_entries').insert({
        owner_user_id: contributorUserId,
        owner_subject_id: null,
        pack_id: pack.id,
        usage_event_id: null,
        entry_type: 'group_topup',
        delta_pnc_micros: -debit,
        balance_after_pnc_micros: runningUserBalance,
        metadata: {
          subject_id: subjectId,
          ...(params.metadata ?? {}),
        } as never,
      });
    }
    if (!progressed) break;
  }

  if (totalDebited === 0) {
    return { ok: false, reason: 'insufficient_balance' };
  }

  // 2. UPSERT group_pools.
  const { data: existingPool, error: poolReadErr } = await supa
    .from('group_pools')
    .select('total_remaining_pnc_micros, share_index')
    .eq('subject_id', subjectId)
    .maybeSingle();
  if (poolReadErr) {
    console.warn('[billing-v2.contributeToGroup] pool read', poolReadErr.message);
  }
  let shareIndexAtJoin = 1;
  if (existingPool) {
    shareIndexAtJoin = Number(existingPool.share_index);
    const newTotal = Number(existingPool.total_remaining_pnc_micros) + totalDebited;
    await supa
      .from('group_pools')
      .update({
        total_remaining_pnc_micros: newTotal,
        updated_at: new Date().toISOString(),
      })
      .eq('subject_id', subjectId);
  } else {
    await supa.from('group_pools').insert({
      subject_id: subjectId,
      total_remaining_pnc_micros: totalDebited,
      share_index: 1,
    });
  }

  // 3. Create group-side pack (ledger consistency).
  const { data: groupPack, error: packInsErr } = await supa
    .from('packs')
    .insert({
      owner_user_id: null,
      owner_subject_id: subjectId,
      initial_pnc_micros: totalDebited,
      remaining_pnc_micros: totalDebited,
      expires_at: null, // group contributions don't expire while in the group
      status: 'active',
      sales_channel: 'group_topup',
      external_purchase_id: null,
      gross_paid_usd_cents: null,
      net_revenue_usd_cents: null,
      sales_markup_snapshot: null,
      metadata: {
        contributor_user_id: contributorUserId,
        source_pack_id: firstSourcePackId,
        ...(params.metadata ?? {}),
      } as never,
    })
    .select('id')
    .single();
  if (packInsErr || !groupPack) {
    console.warn(
      '[billing-v2.contributeToGroup] group pack insert',
      packInsErr?.message,
    );
    return { ok: false, reason: 'db_error', message: packInsErr?.message };
  }

  // 4. Insert contribution row.
  const { data: contribution, error: contribErr } = await supa
    .from('group_contributions')
    .insert({
      subject_id: subjectId,
      contributor_user_id: contributorUserId,
      contributed_pnc_micros: totalDebited,
      share_index_at_join: shareIndexAtJoin,
      source_pack_id: firstSourcePackId,
      status: 'active',
    })
    .select('id')
    .single();
  if (contribErr || !contribution) {
    console.warn(
      '[billing-v2.contributeToGroup] contribution insert',
      contribErr?.message,
    );
    return { ok: false, reason: 'db_error', message: contribErr?.message };
  }

  // 5. Group-side credit ledger.
  const newGroupBalance = await getOwnerBalanceMicros(supa, {
    kind: 'subject',
    subjectId,
  });
  await supa.from('ledger_entries').insert({
    owner_user_id: null,
    owner_subject_id: subjectId,
    pack_id: groupPack.id,
    usage_event_id: null,
    entry_type: 'group_topup',
    delta_pnc_micros: totalDebited,
    balance_after_pnc_micros: newGroupBalance,
    metadata: {
      contributor_user_id: contributorUserId,
      contribution_id: contribution.id,
      ...(params.metadata ?? {}),
    } as never,
  });

  return {
    ok: true,
    contributionId: contribution.id,
    groupPackId: groupPack.id,
    debited: totalDebited,
  };
}

// ============================================================
// Refund a contributor (leave group)
// ============================================================

export interface RefundContributorParams {
  supa: SupabaseClient;
  subjectId: string;
  contributorUserId: string;
  metadata?: Record<string, unknown>;
}

export type RefundContributorResult =
  | {
      ok: true;
      refundedPncMicros: number;
      refundPackId: string | null; // null if share_now rounded to 0
      contributionsRefunded: number;
    }
  | { ok: false; reason: 'no_contributions' | 'pool_missing' | 'db_error'; message?: string };

/**
 * Refund a contributor's current share of the group pool back to their
 * personal wallet as a new pack (1-year expiry).
 *
 * 1. Read group_pools (share_index, total_remaining).
 * 2. Find all active contributions for this user in this subject.
 * 3. share_now per contribution = computeShareNow(contributed, idx_at_join, current_idx)
 *    Sum to alice_total.
 * 4. Debit group packs FIFO until alice_total is covered (defensive cap if
 *    pool is short due to race / drift).
 * 5. group_pools.total_remaining -= debited. share_index UNCHANGED.
 * 6. Issue a 'group_refund' pack to the user with expires_at = now + 1y.
 * 7. Mark contributions refunded.
 * 8. Write user 'credit' ledger + group 'group_refund' ledger.
 *
 * If alice_total rounds to 0 (e.g. group was fully spent before refund),
 * still mark the contributions as refunded and return refundedPncMicros=0.
 * The user sees "退款 0 PNC" — better than a stuck active contribution.
 */
export async function refundContributorFromGroup(
  params: RefundContributorParams,
): Promise<RefundContributorResult> {
  const { supa, subjectId, contributorUserId } = params;

  // 1. Pool state.
  const { data: pool, error: poolErr } = await supa
    .from('group_pools')
    .select('total_remaining_pnc_micros, share_index')
    .eq('subject_id', subjectId)
    .maybeSingle();
  if (poolErr) {
    return { ok: false, reason: 'db_error', message: poolErr.message };
  }
  if (!pool) {
    return { ok: false, reason: 'pool_missing' };
  }
  const currentShareIndex = Number(pool.share_index);
  const poolTotal = Number(pool.total_remaining_pnc_micros);

  // 2. Active contributions.
  const { data: contributions, error: contribErr } = await supa
    .from('group_contributions')
    .select('id, contributed_pnc_micros, share_index_at_join')
    .eq('subject_id', subjectId)
    .eq('contributor_user_id', contributorUserId)
    .eq('status', 'active');
  if (contribErr) {
    return { ok: false, reason: 'db_error', message: contribErr.message };
  }
  if (!contributions || contributions.length === 0) {
    return { ok: false, reason: 'no_contributions' };
  }

  // 3. Share-now total.
  let shareNowTotal = 0;
  for (const c of contributions) {
    shareNowTotal += computeShareNow(
      Number(c.contributed_pnc_micros),
      Number(c.share_index_at_join),
      currentShareIndex,
    );
  }
  // Defensive cap: never withdraw more than the pool actually has.
  const refundMicros = Math.min(shareNowTotal, poolTotal);

  // 4. Debit group packs FIFO (only if there's something to refund).
  let groupDebited = 0;
  if (refundMicros > 0) {
    let stillOwed = refundMicros;
    let runningGroupBalance = poolTotal;
    for (let attempt = 0; attempt < 2 && stillOwed > 0; attempt++) {
      const { data: packs } = await supa
        .from('packs')
        .select('id, remaining_pnc_micros')
        .eq('status', 'active')
        .eq('owner_subject_id', subjectId)
        .order('expires_at', { ascending: true, nullsFirst: false })
        .order('created_at', { ascending: true })
        .limit(50);
      if (!packs || packs.length === 0) break;

      let progressed = false;
      for (const pack of packs) {
        if (stillOwed <= 0) break;
        const debit = Math.min(Number(pack.remaining_pnc_micros), stillOwed);
        if (debit <= 0) continue;
        const newRemaining = Number(pack.remaining_pnc_micros) - debit;
        const { data: updated } = await supa
          .from('packs')
          .update({
            remaining_pnc_micros: newRemaining,
            status: newRemaining === 0 ? 'exhausted' : 'active',
          })
          .eq('id', pack.id)
          .gte('remaining_pnc_micros', debit)
          .select('id')
          .maybeSingle();
        if (!updated) continue;

        stillOwed -= debit;
        groupDebited += debit;
        runningGroupBalance -= debit;
        progressed = true;

        await supa.from('ledger_entries').insert({
          owner_user_id: null,
          owner_subject_id: subjectId,
          pack_id: pack.id,
          usage_event_id: null,
          entry_type: 'group_refund',
          delta_pnc_micros: -debit,
          balance_after_pnc_micros: runningGroupBalance,
          metadata: {
            contributor_user_id: contributorUserId,
            ...(params.metadata ?? {}),
          } as never,
        });
      }
      if (!progressed) break;
    }
  }

  // 5. Decrement pool total (share_index unchanged).
  if (groupDebited > 0) {
    await supa
      .from('group_pools')
      .update({
        total_remaining_pnc_micros: Math.max(0, poolTotal - groupDebited),
        updated_at: new Date().toISOString(),
      })
      .eq('subject_id', subjectId);
  }

  // 6. Issue user refund pack.
  let refundPackId: string | null = null;
  if (groupDebited > 0) {
    const { data: refundPack, error: refundPackErr } = await supa
      .from('packs')
      .insert({
        owner_user_id: contributorUserId,
        owner_subject_id: null,
        initial_pnc_micros: groupDebited,
        remaining_pnc_micros: groupDebited,
        expires_at: defaultPackExpiresAt(),
        status: 'active',
        sales_channel: 'group_refund',
        external_purchase_id: null,
        gross_paid_usd_cents: null,
        net_revenue_usd_cents: null,
        sales_markup_snapshot: null,
        metadata: {
          refunded_from_subject_id: subjectId,
          expiry_days: PACK_DEFAULT_EXPIRY_DAYS,
          ...(params.metadata ?? {}),
        } as never,
      })
      .select('id')
      .single();
    if (refundPackErr || !refundPack) {
      console.warn(
        '[billing-v2.refundContributorFromGroup] refund pack insert',
        refundPackErr?.message,
      );
    } else {
      refundPackId = refundPack.id;
      const newUserBalance = await getOwnerBalanceMicros(supa, {
        kind: 'user',
        userId: contributorUserId,
      });
      await supa.from('ledger_entries').insert({
        owner_user_id: contributorUserId,
        owner_subject_id: null,
        pack_id: refundPack.id,
        usage_event_id: null,
        entry_type: 'credit',
        delta_pnc_micros: groupDebited,
        balance_after_pnc_micros: newUserBalance,
        metadata: {
          source: 'group_refund',
          refunded_from_subject_id: subjectId,
          ...(params.metadata ?? {}),
        } as never,
      });
    }
  }

  // 7. Mark contributions refunded.
  const contributionIds = contributions.map((c) => c.id);
  await supa
    .from('group_contributions')
    .update({
      status: 'refunded',
      refunded_at: new Date().toISOString(),
    })
    .in('id', contributionIds);

  return {
    ok: true,
    refundedPncMicros: groupDebited,
    refundPackId,
    contributionsRefunded: contributionIds.length,
  };
}

// ============================================================
// Dissolve group
// ============================================================

export interface DissolveGroupParams {
  supa: SupabaseClient;
  subjectId: string;
  metadata?: Record<string, unknown>;
}

export interface DissolveGroupResult {
  ok: true;
  refundedContributors: number;
  totalRefundedPncMicros: number;
}

/**
 * Refund every active contributor in this group. Iterates: pick a
 * contributor with active contributions, call refundContributorFromGroup,
 * repeat until none remain.
 *
 * The pool may have a tiny dust balance left over after all refunds due
 * to floor() rounding in computeShareNow. Pre-launch we leave it as-is
 * (negligible) — board admin can zero it via an adjustment.
 */
export async function dissolveGroup(
  params: DissolveGroupParams,
): Promise<DissolveGroupResult> {
  const { supa, subjectId } = params;
  let refundedContributors = 0;
  let totalRefunded = 0;

  // Bounded loop to prevent infinite spin on data anomalies.
  for (let i = 0; i < 1000; i++) {
    const { data: nextContrib } = await supa
      .from('group_contributions')
      .select('contributor_user_id')
      .eq('subject_id', subjectId)
      .eq('status', 'active')
      .limit(1)
      .maybeSingle();
    if (!nextContrib) break;

    const result = await refundContributorFromGroup({
      supa,
      subjectId,
      contributorUserId: nextContrib.contributor_user_id,
      metadata: {
        dissolution: true,
        ...(params.metadata ?? {}),
      },
    });
    if (!result.ok) break;
    refundedContributors += 1;
    totalRefunded += result.refundedPncMicros;
  }

  return {
    ok: true,
    refundedContributors,
    totalRefundedPncMicros: totalRefunded,
  };
}
