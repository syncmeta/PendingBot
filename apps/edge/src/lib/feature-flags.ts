// Runtime kill-switches for billing + observability.
//
// Two sources, composed as: override ?? env default.
//   - env vars (wrangler.jsonc vars): deploy-time, synchronous, can't fail —
//     so they are always the ultimate floor / fallback.
//   - KV override (env.MEMORY's `cfg:feature-flags`): board writes at runtime,
//     toggleable; if the KV read fails we silently fall back to env (never throw).
//
// Both default OFF: any value other than the exact string 'true' (including
// unset / undefined) means disabled. The env vars are plain Worker `vars`
// (deploy-time config in wrangler.jsonc), NOT secrets and NOT DB-backed.
//
// Sentry is the EXCEPTION — it stays pure synchronous env-only. Reasons:
//   1. withSentry's options callback is synchronous ((env)=>CloudflareOptions
//      |undefined) and can't accept an async KV read;
//   2. an error-reporter's kill-switch MUST have zero runtime dependency —
//      it can't depend on KV/DB, or one edge-storage hiccup would silence the
//      very reporter that's supposed to capture the outage.
// Toggle Sentry by editing wrangler.jsonc vars and redeploying (~10s). The
// board page shows it read-only.
//
// See docs/superpowers/specs/2026-06-01-dashboard-stack-design.md for the
// observability seams, and the billing design docs for the gate/debit seams.
import type { Env } from '../types';

/** KV key holding the override blob (shared with the board endpoint). */
export const FLAGS_KV_KEY = 'cfg:feature-flags';
const FLAGS_TTL_MS = 60_000;

// Board-toggleable flags (Sentry is NOT one — see the file header).
export type ToggleableFlag = 'billing' | 'posthog' | 'langfuse';
export type FlagOverrides = Partial<Record<ToggleableFlag, boolean>>;

// isolate-local cache: avoid reading KV on every hot-path flag check
// (billing gate / per-event / per-generation). Caches the override blob;
// refreshed once per TTL window or on cold start. On KV failure we keep the
// previous cache (or empty → fall back to env).
let cache: { at: number; v: FlagOverrides } | null = null;

async function loadOverrides(env: Env, now: number): Promise<FlagOverrides> {
  if (cache && now - cache.at < FLAGS_TTL_MS) return cache.v;
  try {
    const v = (await env.MEMORY.get<FlagOverrides>(FLAGS_KV_KEY, 'json')) ?? {};
    cache = { at: now, v };
    return v;
  } catch {
    // KV read failed: reuse last cache, else empty (→ everything falls back to
    // env default). Never throws.
    return cache?.v ?? {};
  }
}

/** Test-only: reset the isolate cache. */
export function __resetFlagCacheForTest(): void {
  cache = null;
}

async function flagValue(
  env: Env,
  name: ToggleableFlag,
  envVal: string | undefined,
  now: number,
): Promise<boolean> {
  const ov = await loadOverrides(env, now);
  if (typeof ov[name] === 'boolean') return ov[name] as boolean;
  return envVal === 'true';
}

/**
 * Billing gate + debit are LIVE. When false (default), the pre-call gate never
 * blocks and no debit / usage report is emitted — so pre-launch testers aren't
 * locked out by an empty Polar wallet, and no phantom usage burns the meter.
 *
 * override ?? env (BILLING_ENABLED === 'true'). Default false.
 */
export function billingEnabled(env: Env, now: number = nowMs()): Promise<boolean> {
  return flagValue(env, 'billing', env.BILLING_ENABLED, now);
}

// Observability kill-switches are PER-SERVICE (independent) so each vendor's
// quota can be controlled on its own. Default OFF. Each still ALSO requires its
// own key/DSN to be set before it actually emits.

/** PostHog product analytics. Volume scales with user actions (medium). */
export function posthogEnabled(env: Env, now: number = nowMs()): Promise<boolean> {
  return flagValue(env, 'posthog', env.POSTHOG_ENABLED, now);
}

/**
 * Langfuse LLM tracing. HIGH volume: one trace per LLM generation, including
 * system cascades (title / lookback / memo / group routing) — burns the
 * observations quota fastest. Keep off until you actually want traces.
 */
export function langfuseEnabled(env: Env, now: number = nowMs()): Promise<boolean> {
  return flagValue(env, 'langfuse', env.LANGFUSE_ENABLED, now);
}

/**
 * Sentry error tracking. High flood risk: an error burst = an event burst.
 * Stays synchronous env-only — see the file header for why it's NOT board-toggleable.
 */
export function sentryEnabled(env: Env): boolean {
  return env.SENTRY_ENABLED === 'true';
}

// Thin injectable wrapper around Date.now() so tests can pass a fixed `now`.
// Date.now() is available in the Worker runtime (used throughout, e.g.
// prompt-loader.ts for the same isolate-TTL pattern); the cache only needs
// coarse (~60s) precision.
function nowMs(): number {
  return Date.now();
}
