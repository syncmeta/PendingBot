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

/**
 * Sentry + PostHog + Langfuse are LIVE. When false (default), all three are a
 * true no-op — so dev / pre-launch traffic doesn't burn each vendor's free
 * quota (Langfuse especially: one trace per LLM call) or flood Sentry.
 */
export function observabilityEnabled(env: Env): boolean {
  return env.OBSERVABILITY_ENABLED === 'true';
}
