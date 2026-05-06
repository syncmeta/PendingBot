import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { deleteSandbox } from '../lib/sandbox';

// Idle Daytona sandbox sweep — anything in bot_sandbox_sessions whose
// last_used_at is older than IDLE_TTL_MS gets deleted on Daytona's side
// and the bookkeeping row dropped. Re-creating a sandbox on the next
// execute_code is cheap (Daytona claims sub-90ms) so an aggressive TTL
// is fine; the only cost is re-running pip install at next bootstrap.
//
// Idempotent w.r.t. partial failure: we delete Daytona-side first and
// the DB row only after success, so a network blip leaves the row alive
// for the next sweep to retry. If Daytona has already forgotten the
// sandbox (404), the wrapper logs and resolves; we still delete the row.
//
// Bot-private; no client surface. Runs hourly per wrangler.jsonc.

const IDLE_TTL_MS = 60 * 60 * 1000;

export async function cleanupIdleSandboxes(env: Env): Promise<void> {
  if (!env.DAYTONA_API_KEY) {
    // Free-tier setup not provisioned yet; nothing to do.
    return;
  }
  const supa = serviceClient(env);
  const cutoff = new Date(Date.now() - IDLE_TTL_MS).toISOString();

  // Localized escape hatch — bot_sandbox_sessions is added in 0027 and
  // isn't in schema.ts until the post-migration regen runs.
  const sandboxes = (supa as unknown as {
    from(table: string): {
      select: (cols: string) => {
        lt: (col: string, val: string) => Promise<{
          data: Array<{ id: string; daytona_sandbox_id: string }> | null;
        }>;
      };
      delete: () => { eq: (col: string, val: string) => Promise<unknown> };
    };
  }).from('bot_sandbox_sessions');

  const stale = await sandboxes
    .select('id, daytona_sandbox_id')
    .lt('last_used_at', cutoff);
  const rows = stale.data ?? [];
  if (rows.length === 0) return;

  let deleted = 0;
  for (const row of rows) {
    try {
      await deleteSandbox(env, row.daytona_sandbox_id);
      await sandboxes.delete().eq('id', row.id);
      deleted++;
    } catch (err) {
      console.warn('[sandbox-cleanup] row failed', row.id, err);
    }
  }
  console.log(`[sandbox-cleanup] swept ${deleted}/${rows.length} idle sandboxes`);
}
