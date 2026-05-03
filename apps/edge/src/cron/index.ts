import type { Env } from '../types';
import { syncModelPricing } from './model-pricing';
import { cleanupOrphanUploads } from './uploads-cleanup';

// Workers cron entrypoint. wrangler.jsonc declares `triggers.crons` with
// each schedule pattern; the same handler routes by `controller.cron`.
//
// Wired schedules (must agree with wrangler.jsonc):
//   "0 4 * * *"   daily 04:00 UTC — orphan upload sweep
//   "0 3 * * 1"   weekly Monday 03:00 UTC — model_pricing sync from OpenRouter
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
  if (cron === '0 3 * * 1') {
    ctx.waitUntil(safe('model-pricing', () => syncModelPricing(env)));
  } else if (cron === '0 4 * * *') {
    ctx.waitUntil(safe('uploads-cleanup', () => cleanupOrphanUploads(env)));
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
