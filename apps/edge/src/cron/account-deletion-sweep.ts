import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';

// Finalize accounts whose 28-day cooldown has elapsed.
//
// Companion to the SQL side (0050_account_deletion_cooldown):
//   • request_account_deletion stamps pending_deletion_at + sentiment
//   • cancel_account_deletion clears them on re-login
//   • this sweep loops over every still-stamped row past +28 days and
//     calls finalize_account_deletion(p_uid) which logs sentiment then
//     runs _delete_account_internal.
//
// We finalize one row per RPC so a single broken account (e.g. an FK
// the cascading delete didn't predict) doesn't poison the whole batch.
// Errors are logged + swallowed; the row stays stamped and the next
// day's sweep will retry.
//
// Wired into handleScheduled at the daily 04:00 UTC slot (alongside
// uploads-cleanup) so we don't burn a CF cron-trigger.

const COOLDOWN_DAYS = 28;

export async function finalizeExpiredAccountDeletions(env: Env): Promise<void> {
  const supa = serviceClient(env);
  const cutoff = new Date(
    Date.now() - COOLDOWN_DAYS * 24 * 3600 * 1000,
  ).toISOString();

  const { data: rows, error } = await supa
    .from('users')
    .select('id')
    .not('pending_deletion_at', 'is', null)
    .lt('pending_deletion_at', cutoff)
    .limit(200);

  if (error) {
    console.error('[deletion-sweep] select failed', error.message);
    return;
  }
  if (!rows || rows.length === 0) {
    console.log('[deletion-sweep] nothing expired');
    return;
  }

  let ok = 0;
  let failed = 0;
  for (const row of rows) {
    const { error: rpcErr } = await supa.rpc('finalize_account_deletion', {
      p_uid: row.id,
    });
    if (rpcErr) {
      failed += 1;
      console.error('[deletion-sweep] finalize failed', row.id, rpcErr.message);
    } else {
      ok += 1;
    }
  }
  console.log(`[deletion-sweep] finalized ${ok} (failed ${failed})`);
}
