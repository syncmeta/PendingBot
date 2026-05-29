import type { SupabaseClient } from './supabase';
import { getOwnerBalanceMicros } from './billing-v2';
import type { OwnerRef } from './billing-v2';

// Pack expiry sweep — see docs/billing-v2-design.md §4.
//
// Runs hourly from the cron handler. Any active pack whose expires_at
// has passed gets:
//   - status flipped to 'expired'
//   - remaining_pnc_micros zeroed out
//   - a ledger 'expired' entry recording the wiped amount
//
// Bounded to `limit` packs per pass so a misconfigured run can't
// dominate the cron budget.

export interface SweepExpiredPacksResult {
  scanned: number;
  expired: number;
  totalExpiredPncMicros: number;
}

export async function sweepExpiredPacks(
  supa: SupabaseClient,
  limit = 200,
): Promise<SweepExpiredPacksResult> {
  const nowIso = new Date().toISOString();

  const { data: packs, error: readErr } = await supa
    .from('packs')
    .select('id, owner_user_id, owner_subject_id, remaining_pnc_micros, expires_at')
    .eq('status', 'active')
    .gt('remaining_pnc_micros', 0)
    .lte('expires_at', nowIso)
    .limit(limit);
  if (readErr) {
    console.warn('[billing-v2.sweepExpiredPacks] read', readErr.message);
    return { scanned: 0, expired: 0, totalExpiredPncMicros: 0 };
  }
  if (!packs || packs.length === 0) {
    return { scanned: 0, expired: 0, totalExpiredPncMicros: 0 };
  }

  let expired = 0;
  let totalExpiredMicros = 0;
  for (const pack of packs) {
    const wiped = Number(pack.remaining_pnc_micros);
    // CAS: only flip if status is still 'active' (in case of race with settle).
    const { data: updated, error: updErr } = await supa
      .from('packs')
      .update({
        status: 'expired',
        remaining_pnc_micros: 0,
      })
      .eq('id', pack.id)
      .eq('status', 'active')
      .select('id')
      .maybeSingle();
    if (updErr) {
      console.warn('[billing-v2.sweepExpiredPacks] update', updErr.message);
      continue;
    }
    if (!updated) continue;

    expired += 1;
    totalExpiredMicros += wiped;

    const owner: OwnerRef = pack.owner_user_id
      ? { kind: 'user', userId: pack.owner_user_id }
      : { kind: 'subject', subjectId: pack.owner_subject_id as string };
    const newBalance = await getOwnerBalanceMicros(supa, owner);
    await supa.from('ledger_entries').insert({
      owner_user_id: pack.owner_user_id,
      owner_subject_id: pack.owner_subject_id,
      pack_id: pack.id,
      usage_event_id: null,
      entry_type: 'expired',
      delta_pnc_micros: -wiped,
      balance_after_pnc_micros: newBalance,
      metadata: {
        expired_at: pack.expires_at,
        swept_at: nowIso,
      } as never,
    });
  }

  return { scanned: packs.length, expired, totalExpiredPncMicros: totalExpiredMicros };
}
