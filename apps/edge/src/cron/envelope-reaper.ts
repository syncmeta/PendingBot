import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';

// Reap stuck envelope runs (envelope_runs table).
//
// Background: an envelope's wall budget is 4 minutes (MAX_WALL_MS in
// envelope-loop.ts) plus a writer phase + audit. If the Worker is
// killed mid-run (CF wall-time exceeded, isolate evicted), runEnvelope's
// try/catch never executes — the row is orphaned at status='running'
// forever. The loop's own wall_cap check also only fires between
// turns, so an in-flight tool call hang is not self-correcting.
//
// This watchdog catches both. Anything still 'running' past STUCK_AGE_MS
// is force-flipped to 'error' so the iOS feed can render a "写信失败"
// state and the user can retrigger.
//
// Threshold: an envelope caps at ~4min wall + ~1min slack for
// writer/audit. 6 minutes is therefore the earliest a healthy run
// could still be ticking; older than that = dead.

const STUCK_AGE_MS = 6 * 60 * 1000;

export async function reapStuckEnvelopes(env: Env): Promise<void> {
  const supa = serviceClient(env);
  const cutoff = new Date(Date.now() - STUCK_AGE_MS).toISOString();

  const { data, error } = await supa
    .from('envelope_runs')
    .update({
      status: 'error',
      finished_at: new Date().toISOString(),
      progress: { phase: 'error', notes: [], visited_urls: [], plan_rounds: 0 },
      updated_at: new Date().toISOString(),
    })
    .eq('status', 'running')
    .lt('started_at', cutoff)
    .select('id');

  if (error) {
    console.error('[envelope-reaper] update failed', error.message);
    return;
  }
  const reaped = data?.length ?? 0;
  if (reaped > 0) {
    console.log(`[envelope-reaper] flipped ${reaped} stuck envelope runs to error`);
  }
}
