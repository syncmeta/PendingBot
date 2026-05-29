import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { sweepExpiredPacks } from '../lib/billing-v2-expiry';
import { sweepPendingRefunds } from '../lib/billing-v2-refund';

// Hourly billing v2 maintenance — see docs/billing-v2-design.md §4, §10.
//
// Two tasks per pass:
//   1. Expire any pack whose expires_at has passed (flip status, zero
//      remaining, write a ledger 'expired' entry).
//   2. Retry any refund_events row whose eager-path processing failed
//      (processed_at IS NULL). Bounded per-pass so a poison row can't
//      dominate the cron budget.

export async function runBillingV2Hourly(env: Env): Promise<void> {
  const supa = serviceClient(env);

  const expiry = await sweepExpiredPacks(supa);
  console.log('[cron:billing-v2] pack expiry sweep', expiry);

  const refund = await sweepPendingRefunds(supa);
  console.log('[cron:billing-v2] pending refund sweep', refund);
}
