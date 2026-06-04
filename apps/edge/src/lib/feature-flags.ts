// Runtime kill-switches for billing + observability.
//
// Both default OFF: any value other than the exact string 'true' (including
// unset / undefined) means disabled. They are plain Worker `vars` (deploy-time
// config in wrangler.jsonc), NOT secrets and NOT DB-backed:
//
//   - The observability switch MUST have zero runtime dependency. Error
//     reporting can't be allowed to depend on the database (or any service
//     that might be the very thing failing) — otherwise an outage would
//     silence the reporter that's supposed to capture it. A deploy-time env
//     var is the correct design for a kill-switch, not just the simple one.
//   - Toggle by editing wrangler.jsonc vars (or `wrangler deploy --var`) and
//     redeploying (~10s). Off → on at launch; on → off during an incident.
//
// See docs/superpowers/specs/2026-06-01-dashboard-stack-design.md for the
// observability seams, and the billing design docs for the gate/debit seams.
import type { Env } from '../types';

/**
 * Billing gate + debit are LIVE. When false (default), the pre-call gate never
 * blocks and no debit / usage report is emitted — so pre-launch testers aren't
 * locked out by an empty Polar wallet, and no phantom usage burns the meter.
 */
export function billingEnabled(env: Env): boolean {
  return env.BILLING_ENABLED === 'true';
}

// Observability kill-switches are PER-SERVICE (independent) so each vendor's
// quota can be controlled on its own. Default OFF. Each still ALSO requires its
// own key/DSN to be set before it actually emits.

/** Sentry error tracking. High flood risk: an error burst = an event burst. */
export function sentryEnabled(env: Env): boolean {
  return env.SENTRY_ENABLED === 'true';
}

/** PostHog product analytics. Volume scales with user actions (medium). */
export function posthogEnabled(env: Env): boolean {
  return env.POSTHOG_ENABLED === 'true';
}

/**
 * Langfuse LLM tracing. HIGH volume: one trace per LLM generation, including
 * system cascades (title / lookback / memo / group routing) — burns the
 * observations quota fastest. Keep off until you actually want traces.
 */
export function langfuseEnabled(env: Env): boolean {
  return env.LANGFUSE_ENABLED === 'true';
}
