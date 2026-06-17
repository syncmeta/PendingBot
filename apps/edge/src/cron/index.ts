import * as Sentry from '@sentry/cloudflare';
import type { Env } from '../types';
import { cleanupOrphanUploads } from './uploads-cleanup';
import { reapStuckEnvelopes } from './envelope-reaper';
import { finalizeExpiredAccountDeletions } from './account-deletion-sweep';
import { warmModelPresets } from './preset-warm';

// Workers cron entrypoint. wrangler.jsonc declares `triggers.crons` with
// each schedule pattern; the same handler routes by `controller.cron`.
//
// Wired schedules (must agree with wrangler.jsonc):
//   "0 4 * * *"    daily 04:00 UTC — orphan upload sweep + finalize
//                  expired account-deletion tombstones (28d cooldown)
//   "*/5 * * * *"  every 5 min — envelope-run watchdog (force-fail
//                  envelope_runs rows stuck in 'running' past the loop's
//                  4-min wall budget)
//   "*/30 * * * *" every 30 min — warm model-presets KV (catalog + per-preset
//                  + list cache) so the bot-builder picker never pays cold cost
//
// The hourly "5 * * * *" idle-sandbox sweep was retired when the
// code-exec tool moved off Daytona — the Cloudflare Sandbox SDK
// container auto-sleeps on its own (see lib/sandbox.ts).
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
  } else if (cron === '*/30 * * * *') {
    ctx.waitUntil(safe('preset-warm', () => warmModelPresets(env)));
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
    // Scheduled tasks (billing reconciliation, deletion sweep, envelope
    // reaper) run unattended with no caller to notice a failure — surface
    // them to Sentry instead of only logging. No-op when DSN unset.
    Sentry.captureException(err, { tags: { source: 'cron', cron_task: label } });
  }
}
