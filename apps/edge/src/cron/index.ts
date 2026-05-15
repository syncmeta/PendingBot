import type { Env } from '../types';
import { syncModelPricing } from './model-pricing';
import { cleanupOrphanUploads } from './uploads-cleanup';
import { reapStuckEnvelopes } from './envelope-reaper';
import { finalizeExpiredAccountDeletions } from './account-deletion-sweep';

// Workers cron entrypoint. wrangler.jsonc declares `triggers.crons` with
// each schedule pattern; the same handler routes by `controller.cron`.
//
// Wired schedules (must agree with wrangler.jsonc):
//   "0 4 * * *"    daily 04:00 UTC — orphan upload sweep + finalize
//                  expired account-deletion tombstones (28d cooldown)
//   "*/5 * * * *"  every 5 min — envelope-run watchdog (force-fail
//                  scroll_runs rows stuck in 'running' past the loop's
//                  4-min wall budget)
//
// The hourly "5 * * * *" idle-sandbox sweep was retired when the
// code-exec tool moved off Daytona — the Cloudflare Sandbox SDK
// container auto-sleeps on its own (see lib/sandbox.ts).
//
// model_pricing sync ("0 3 * * 1") was dropped to stay under the account
// cron-trigger cap (5). syncModelPricing() stays exported as a callable
// so admin can fire it manually via the board / wrangler if needed.
//
// Each task swallows its own errors so one failure doesn't poison sibling
// jobs. Cron tasks log to CF Observability — check there if a job goes dark.

export async function handleScheduled(
  controller: ScheduledController,
  env: Env,
  ctx: ExecutionContext,
): Promise<void> {
  const cron = controller.cron;
  console.log('[cron]', cron, new Date().toISOString());

  // Route by cron expression. Order matters only insofar as we waitUntil
  // each task — they run concurrently from the runtime's perspective.
  if (cron === '0 4 * * *') {
    ctx.waitUntil(safe('uploads-cleanup', () => cleanupOrphanUploads(env)));
    ctx.waitUntil(
      safe('deletion-sweep', () => finalizeExpiredAccountDeletions(env)),
    );
  } else if (cron === '*/5 * * * *') {
    ctx.waitUntil(safe('envelope-reaper', () => reapStuckEnvelopes(env)));
  } else {
    console.warn('[cron] unmatched schedule', cron);
  }
}

async function safe(label: string, fn: () => Promise<unknown>): Promise<void> {
  try {
    await fn();
    console.log('[cron]', label, 'done');
  } catch (err) {
    console.error('[cron]', label, 'failed', err);
  }
}
