// Edge KV read-through for admin-curated config tables.
//
// The routing / tools / mcp_servers / billing_config tables are edited
// from the board roughly never and read on the LLM dispatch path. Each
// reader already keeps an isolate-local Map cache (L1) — but that's
// per-isolate, so every cold isolate paid one cross-region Supabase
// round-trip to warm it.
//
// kvConfig adds a shared L2: the first cold isolate (per key, per TTL
// window, globally) reads Supabase and writes KV; every other cold
// isolate reads the value from edge KV (~single-digit ms) instead.
// Staleness is unchanged from the existing Map TTLs — the KV entry is
// given the same TTL — so a board edit still propagates within the
// same window it does today.
//
// Negative results are cached too: the stored shape is `{ v: T }`, so a
// legitimately-null config value (no task rule, unknown provider) is
// distinguishable from a KV miss and doesn't re-hit Supabase every
// cold isolate.

import type { Env } from '../types';

interface Boxed<T> {
  v: T;
}

/**
 * Read `key` from KV; on miss, run `loader` (the Supabase query) and
 * write the result back to KV under `ttlSec`. KV read/write failures
 * degrade silently to a direct loader call — a flaky KV must never
 * break config resolution.
 */
export async function kvConfig<T>(
  env: Env,
  key: string,
  ttlSec: number,
  loader: () => Promise<T>,
): Promise<T> {
  try {
    const cached = await env.MEMORY.get<Boxed<T>>(key, 'json');
    if (cached) return cached.v;
  } catch {
    /* KV read failed — fall through to the loader */
  }
  const fresh = await loader();
  try {
    await env.MEMORY.put(key, JSON.stringify({ v: fresh } satisfies Boxed<T>), {
      expirationTtl: ttlSec,
    });
  } catch {
    /* best-effort warm — a write failure just means the next cold
       isolate re-loads from Supabase */
  }
  return fresh;
}
