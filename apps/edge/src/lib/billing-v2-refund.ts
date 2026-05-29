import type { SupabaseClient } from './supabase';
import { getOwnerBalanceMicros } from './billing-v2';
import type { OwnerRef } from './billing-v2';

// Refund processor — see docs/billing-v2-design.md §10.
//
// The webhooks (lib/billing-v2-lemon.ts, lib/billing-v2-iap.ts) write a
// refund_events row when an order_refunded / REFUND notification arrives.
// This module's processRefundEvent() is what actually:
//
//   1. Finds the original pack
//   2. Computes how much was already spent (consumed_pnc_micros_at_refund)
//   3. Wipes the pack's remaining + flips status to 'refunded'
//   4. Writes a ledger 'refund' entry on the owner
//   5. Records the chargeback_loss (platform absorbs spent portion)
//   6. Marks refund_events.processed_at
//
// Called both eagerly (webhook → ctx.waitUntil(processRefundEvent(...))
// and from cron/billing-v2-tasks.ts as a retry sweep for any rows where
// the eager attempt failed.

export interface ProcessRefundParams {
  supa: SupabaseClient;
  refundEventId: string;
}

export type ProcessRefundResult =
  | {
      ok: true;
      packId: string | null;
      consumedPncMicros: number;
      chargebackLossPncMicros: number;
      kind: 'untouched' | 'partial' | 'fully_consumed' | 'orphaned';
    }
  | { ok: false; reason: 'not_found' | 'already_processed' | 'db_error'; message?: string };

/**
 * Apply one refund_events row. Idempotent — calling on an already-
 * processed row returns {ok:false, reason:'already_processed'} cleanly.
 */
export async function processRefundEvent(
  params: ProcessRefundParams,
): Promise<ProcessRefundResult> {
  const { supa, refundEventId } = params;

  const { data: event, error: evErr } = await supa
    .from('refund_events')
    .select(
      'id, pack_id, refund_amount_usd_cents, processed_at, source, external_refund_id',
    )
    .eq('id', refundEventId)
    .maybeSingle();
  if (evErr) return { ok: false, reason: 'db_error', message: evErr.message };
  if (!event) return { ok: false, reason: 'not_found' };
  if (event.processed_at) return { ok: false, reason: 'already_processed' };

  // Find the pack.
  if (!event.pack_id) {
    // Webhook couldn't link to a pack (e.g. refund for an unknown order).
    // Mark processed with the loss = full refund amount for finance audit.
    await supa
      .from('refund_events')
      .update({
        processed_at: new Date().toISOString(),
        chargeback_loss_pnc_micros: 0,
        consumed_pnc_micros_at_refund: 0,
        processing_error: 'pack_not_linked',
      })
      .eq('id', refundEventId);
    return {
      ok: true,
      packId: null,
      consumedPncMicros: 0,
      chargebackLossPncMicros: 0,
      kind: 'orphaned',
    };
  }

  const { data: pack, error: packErr } = await supa
    .from('packs')
    .select(
      'id, owner_user_id, owner_subject_id, initial_pnc_micros, remaining_pnc_micros, status',
    )
    .eq('id', event.pack_id)
    .maybeSingle();
  if (packErr) return { ok: false, reason: 'db_error', message: packErr.message };
  if (!pack) {
    await markProcessed(supa, refundEventId, 0, 0, 'pack_disappeared');
    return {
      ok: true,
      packId: event.pack_id,
      consumedPncMicros: 0,
      chargebackLossPncMicros: 0,
      kind: 'orphaned',
    };
  }

  const initial = Number(pack.initial_pnc_micros);
  const remaining = Number(pack.remaining_pnc_micros);
  const consumed = Math.max(0, initial - remaining);

  // Three cases (doc §10 退款流程):
  //   A: consumed = 0       → unspent; remaining → 0, no loss
  //   B: 0 < consumed < initial → spent portion is platform loss
  //   C: consumed >= initial → fully spent; pack already empty
  let kind: 'untouched' | 'partial' | 'fully_consumed';
  if (consumed === 0) kind = 'untouched';
  else if (consumed >= initial) kind = 'fully_consumed';
  else kind = 'partial';

  const chargebackLoss = consumed;

  // Wipe pack.
  if (remaining > 0 || pack.status === 'active') {
    const { error: updErr } = await supa
      .from('packs')
      .update({
        remaining_pnc_micros: 0,
        status: 'refunded',
      })
      .eq('id', pack.id);
    if (updErr) {
      await markProcessed(supa, refundEventId, consumed, chargebackLoss, updErr.message);
      return { ok: false, reason: 'db_error', message: updErr.message };
    }
  }

  // Compute owner ref + new balance for the ledger row.
  const owner: OwnerRef = pack.owner_user_id
    ? { kind: 'user', userId: pack.owner_user_id }
    : { kind: 'subject', subjectId: pack.owner_subject_id as string };

  // Ledger refund entry. delta = -remaining (what got wiped from the pack);
  // for fully_consumed packs this is 0 (only status changes, no balance impact).
  const refundDelta = -remaining;
  const newBalance = await getOwnerBalanceMicros(supa, owner);
  await supa.from('ledger_entries').insert({
    owner_user_id: pack.owner_user_id,
    owner_subject_id: pack.owner_subject_id,
    pack_id: pack.id,
    usage_event_id: null,
    entry_type: 'refund',
    delta_pnc_micros: refundDelta,
    balance_after_pnc_micros: newBalance,
    metadata: {
      refund_event_id: refundEventId,
      refund_source: event.source,
      external_refund_id: event.external_refund_id,
      chargeback_loss_pnc_micros: chargebackLoss,
      kind,
    } as never,
  });

  await markProcessed(supa, refundEventId, consumed, chargebackLoss, null);

  return {
    ok: true,
    packId: pack.id,
    consumedPncMicros: consumed,
    chargebackLossPncMicros: chargebackLoss,
    kind,
  };
}

async function markProcessed(
  supa: SupabaseClient,
  refundEventId: string,
  consumed: number,
  loss: number,
  err: string | null,
): Promise<void> {
  await supa
    .from('refund_events')
    .update({
      processed_at: new Date().toISOString(),
      consumed_pnc_micros_at_refund: consumed,
      chargeback_loss_pnc_micros: loss,
      processing_error: err,
    })
    .eq('id', refundEventId);
}

// ============================================================
// Sweep helper for cron
// ============================================================

export interface SweepRefundsResult {
  scanned: number;
  processed: number;
  failed: number;
}

/**
 * Sweep recent unprocessed refund_events. Bounded so a cron run can't
 * thrash the DB if a poison row keeps failing — we'll process at most
 * `limit` events per pass and rely on the next cron tick for the rest.
 */
export async function sweepPendingRefunds(
  supa: SupabaseClient,
  limit = 50,
): Promise<SweepRefundsResult> {
  const { data: rows } = await supa
    .from('refund_events')
    .select('id')
    .is('processed_at', null)
    .order('created_at', { ascending: true })
    .limit(limit);
  let processed = 0;
  let failed = 0;
  for (const row of rows ?? []) {
    const result = await processRefundEvent({ supa, refundEventId: row.id });
    if (result.ok) processed += 1;
    else failed += 1;
  }
  return { scanned: rows?.length ?? 0, processed, failed };
}
