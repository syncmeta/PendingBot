import { serviceClient } from '../lib/supabase';
import type { Env } from '../types';

// Billing v2 maintenance cron (#187).
//
// Two passes, both safe to run as often as we like (idempotent on a
// per-row basis):
//
// 1. expirePacks — find active packs whose expires_at < now(), wipe
//    their remaining_pnc_micros, mark status='expired', and write a
//    matching 'expired' ledger entry. The ledger entry's
//    balance_after_pnc_micros is the per-owner running balance after
//    this expiry, computed by re-summing the owner's other active
//    packs. We process in small batches so a backlog can't time out
//    the cron invocation.
//
// 2. reconcileGroupPools — for each group_pools row, compare
//    total_remaining_pnc_micros against SUM(packs.remaining_pnc_micros
//    where owner_subject_id = subject AND status = 'active'). Any drift
//    > a tiny tolerance is logged; we DO NOT silently rewrite the pool
//    total — drift is usually a symptom of a concurrent settle race
//    (the design doc §9 calls this out), and the ops fix is to read
//    the audit_log + ledger trail rather than patching balances under
//    the cron. The audit cron is the alarm, not the fixer.
//
// Wired by src/cron/index.ts on the existing '0 4 * * *' daily trigger
// — neither sweep is hot enough to need a dedicated schedule.

const EXPIRY_BATCH = 200;
const RECON_TOLERANCE_MICROS = 1; // 1 micro = 0.000001 PNC. Should be 0 normally.

interface PackExpiryRow {
  id: string;
  owner_user_id: string | null;
  owner_subject_id: string | null;
  remaining_pnc_micros: number | string;
}

/**
 * Sweep packs that have expired. One pass = one DB read of up to
 * EXPIRY_BATCH rows. If the cron has more than EXPIRY_BATCH expired
 * packs to clear, the next invocation picks up the rest — the
 * partial-index `packs_expires_at_active_idx` keeps the query cheap
 * even with a backlog.
 */
export async function expirePacks(env: Env): Promise<{
  expired: number;
  scanned: number;
}> {
  const supa = serviceClient(env);
  const nowIso = new Date().toISOString();

  // Read a bounded batch. We could loop until empty, but that risks
  // tying the cron up indefinitely on a runaway backlog; better to clear
  // EXPIRY_BATCH per invocation and let the daily schedule catch up.
  const { data: rows, error } = await supa
    .from('packs')
    .select('id, owner_user_id, owner_subject_id, remaining_pnc_micros')
    .eq('status', 'active')
    .not('expires_at', 'is', null)
    .lt('expires_at', nowIso)
    .limit(EXPIRY_BATCH);
  if (error) {
    console.warn('[billing-v2-sweep.expirePacks] read', error.message);
    return { expired: 0, scanned: 0 };
  }
  const expiredRows = (rows ?? []) as PackExpiryRow[];
  if (expiredRows.length === 0) return { expired: 0, scanned: 0 };

  let expired = 0;
  for (const pack of expiredRows) {
    const remainingMicros = Number(pack.remaining_pnc_micros);
    // CAS UPDATE: only flip the row if it's still active + still has
    // the same remaining we read. Protects against the rare case where
    // a settleUsage racing the cron drained the pack between read and
    // write — we'd otherwise overwrite a debit's status change.
    const { data: updated, error: updErr } = await supa
      .from('packs')
      .update({
        status: 'expired',
        remaining_pnc_micros: 0,
      })
      .eq('id', pack.id)
      .eq('status', 'active')
      .eq('remaining_pnc_micros', remainingMicros)
      .select('id')
      .maybeSingle();
    if (updErr) {
      console.warn('[billing-v2-sweep.expirePacks] update', pack.id, updErr.message);
      continue;
    }
    if (!updated) continue; // CAS lost — settleUsage drained it first.

    expired++;

    // Re-sum the owner's remaining active packs so balance_after is the
    // running total post-expiry. Cheap (indexed) compared to the
    // expiry itself; we accept the extra round-trip per row because
    // expiry batches are small and the cron isn't hot-path.
    const ownerCol = pack.owner_user_id ? 'owner_user_id' : 'owner_subject_id';
    const ownerVal = pack.owner_user_id ?? pack.owner_subject_id;
    const { data: remaining } = await supa
      .from('packs')
      .select('remaining_pnc_micros')
      .eq('status', 'active')
      .eq(ownerCol, ownerVal!);
    const balanceAfter = (remaining ?? []).reduce(
      (acc, r) => acc + Number(r.remaining_pnc_micros ?? 0),
      0,
    );

    if (remainingMicros > 0) {
      const { error: ledErr } = await supa.from('ledger_entries').insert({
        owner_user_id: pack.owner_user_id,
        owner_subject_id: pack.owner_subject_id,
        pack_id: pack.id,
        usage_event_id: null,
        entry_type: 'expired',
        delta_pnc_micros: -remainingMicros,
        balance_after_pnc_micros: balanceAfter,
        metadata: { source: 'cron' } as never,
      });
      if (ledErr) {
        console.warn(
          '[billing-v2-sweep.expirePacks] ledger',
          pack.id,
          ledErr.message,
        );
      }
    }
  }

  return { expired, scanned: expiredRows.length };
}

interface PoolReconRow {
  subject_id: string;
  total_remaining_pnc_micros: number | string;
}

/**
 * Read every group_pools row and verify it agrees with the sum of
 * active subject-owned packs. Logs drift; does NOT auto-correct.
 *
 * Pre-launch this is a low-volume table (one row per group with
 * contributions), so the read-all-then-loop pattern is fine. If group
 * counts blow up post-launch, batch + paginate the same way expirePacks
 * does.
 */
export async function reconcileGroupPools(env: Env): Promise<{
  checked: number;
  drifted: number;
}> {
  const supa = serviceClient(env);
  const { data: pools, error } = await supa
    .from('group_pools')
    .select('subject_id, total_remaining_pnc_micros');
  if (error) {
    console.warn('[billing-v2-sweep.reconcileGroupPools] read', error.message);
    return { checked: 0, drifted: 0 };
  }

  let drifted = 0;
  for (const pool of (pools ?? []) as PoolReconRow[]) {
    const { data: packs, error: packErr } = await supa
      .from('packs')
      .select('remaining_pnc_micros')
      .eq('status', 'active')
      .eq('owner_subject_id', pool.subject_id);
    if (packErr) {
      console.warn(
        '[billing-v2-sweep.reconcileGroupPools] packs',
        pool.subject_id,
        packErr.message,
      );
      continue;
    }
    const summed = (packs ?? []).reduce(
      (acc, r) => acc + Number(r.remaining_pnc_micros ?? 0),
      0,
    );
    const tracked = Number(pool.total_remaining_pnc_micros);
    const delta = summed - tracked;
    if (Math.abs(delta) > RECON_TOLERANCE_MICROS) {
      drifted++;
      // ALARM, not auto-fix. The ops fix is to read the ledger trail.
      // We log subject + both numbers so a CF log query can surface the
      // drifted groups.
      console.warn(
        '[billing-v2-sweep.reconcileGroupPools] DRIFT',
        JSON.stringify({
          subject_id: pool.subject_id,
          pool_total_pnc_micros: tracked,
          summed_pack_remaining_pnc_micros: summed,
          delta_pnc_micros: delta,
        }),
      );
    }
  }

  return { checked: (pools ?? []).length, drifted };
}

/** Combined entrypoint for the cron dispatcher. */
export async function runBillingV2Sweep(env: Env): Promise<void> {
  const expiry = await expirePacks(env);
  console.log('[billing-v2-sweep] expirePacks', JSON.stringify(expiry));
  const recon = await reconcileGroupPools(env);
  console.log('[billing-v2-sweep] reconcileGroupPools', JSON.stringify(recon));
}
