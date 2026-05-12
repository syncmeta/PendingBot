// KV-backed cache for the per-user credit balance so the pre-call
// gate in POST /v1/messages can run without hitting Supabase.
//
// Cache invariants:
//   - Written by billingDebit after every LLM debit lands (router.ts).
//   - Written by redeem after a successful code redemption (me.ts).
//   - Read by requireBalance (billing.ts) — falls back to Supabase on
//     miss and warms KV with the result.
//
// Threshold is global config; cached at module-level inside billing.ts
// because it's the same value for every user and an isolate-local
// memo + 60s TTL is cheaper than a KV round-trip per request.

import type { Env } from '../types';

const BAL_PREFIX = 'bal:';

export interface CachedBalance {
  balance_credits: number;
  /// Epoch ms at the time KV was written. The caller can use this to
  /// decide if the cached value is stale enough to re-check (we don't
  /// enforce a hard TTL on the cache key itself — KV writes happen at
  /// every debit so the value is naturally kept fresh).
  updated_at: number;
}

export async function getCachedBalance(env: Env, userId: string): Promise<CachedBalance | null> {
  return env.MEMORY.get<CachedBalance>(BAL_PREFIX + userId, 'json');
}

export async function putCachedBalance(
  env: Env,
  userId: string,
  balanceCredits: number,
): Promise<void> {
  await env.MEMORY.put(
    BAL_PREFIX + userId,
    JSON.stringify({ balance_credits: balanceCredits, updated_at: Date.now() }),
  );
}

export async function deleteCachedBalance(env: Env, userId: string): Promise<void> {
  await env.MEMORY.delete(BAL_PREFIX + userId);
}
