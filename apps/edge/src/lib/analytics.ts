// PostHog product-analytics helper (dashboard stack).
//
// Env-gated: when POSTHOG_KEY is unset, capture() returns immediately and
// nothing is imported/instantiated beyond this module — a true no-op, so
// dev / preview deploys without analytics configured behave exactly as
// before. See docs/superpowers/specs/2026-06-01-dashboard-stack-design.md.
//
// This file intentionally only exposes a thin `capture()` helper. Wiring it
// into individual routes / the LLM path is a separate, later step — this is
// just the seam.
//
// Workers note: posthog-node batches + flushes events on a background timer
// by default, which doesn't survive a Worker isolate that's torn down right
// after the response. We therefore use `captureImmediate()`, which sends the
// event over fetch and resolves when the request completes — no reliance on
// a background flush. The PostHog client is created per-call (cheap; it's
// just config + a fetch wrapper) and shut down after, so nothing lingers.

import { PostHog } from 'posthog-node';
import type { Env } from '../types';
import { posthogEnabled } from './feature-flags';

export interface CaptureArgs {
  /** Stable identifier for the acting user / entity (e.g. userId). */
  distinctId: string;
  /** Event name, e.g. 'message_sent', 'bot_created'. */
  event: string;
  /** Optional structured event properties. */
  properties?: Record<string, unknown>;
}

/**
 * Capture a product-analytics event in PostHog.
 *
 * No-op when `POSTHOG_KEY` is unset. When set, sends the event immediately
 * (fetch-based, awaited) so it survives a short-lived Worker isolate.
 *
 * Never throws: analytics is best-effort and must not break the request it's
 * observing. Failures are logged and swallowed.
 */
export async function capture(env: Env, args: CaptureArgs): Promise<void> {
  if (!(await posthogEnabled(env)) || !env.POSTHOG_KEY) return;

  const client = new PostHog(env.POSTHOG_KEY, {
    host: env.POSTHOG_HOST,
    // We flush per-event via captureImmediate; disable the background timer
    // so nothing is left pending when the isolate is recycled.
    flushAt: 1,
    flushInterval: 0,
  });

  try {
    // captureImmediate sends the event over fetch and resolves when the
    // request completes — no reliance on the background flush timer.
    await client.captureImmediate({
      distinctId: args.distinctId,
      event: args.event,
      properties: args.properties,
    });
  } catch (err) {
    console.error('[analytics] capture failed', err);
  } finally {
    // Drain any queued state so nothing is left pending on the isolate.
    try {
      await client.flush();
    } catch {
      // ignore — already logged the meaningful failure above.
    }
  }
}
