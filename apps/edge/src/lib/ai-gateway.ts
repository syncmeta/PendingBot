// AI Gateway Logs API — read the gateway's computed per-request cost.
//
// All LLM traffic flows through the Cloudflare AI Gateway, which logs
// every request with a computed `cost`. Some providers (OpenRouter)
// report their own exact cost in the response; others (providers that
// don't self-report cost, e.g. OpenAI Realtime) don't. For the latter,
// billing reads the gateway's figure here instead of computing anything
// locally.
//
// Each LLM request of a chat turn is stamped with the same `turn_id` in
// the cf-aig-metadata header (see router.ts aigMetadataFrom). This
// module finds that turn's gateway log entries by turn_id and sums
// their cost — one turn can be several provider calls (tool loops,
// fallback), so the sum is the turn's total.

import type { Env } from '../types';

// Returned when the gateway is configured but this turn's logs aren't
// queryable yet (ingestion lag) — distinct from "configured, no cost".
// The audit queue consumer re-tries the message with a delay on this.
export const GATEWAY_COST_PENDING = 'pending' as const;
export type GatewayCostPending = typeof GATEWAY_COST_PENDING;

interface GatewayLog {
  cost?: number | string | null;
  metadata?: unknown;
}

function parseMetadata(m: unknown): Record<string, unknown> | null {
  if (m == null) return null;
  if (typeof m === 'object' && !Array.isArray(m)) {
    return m as Record<string, unknown>;
  }
  // AI Gateway may store the cf-aig-metadata payload as a JSON string.
  if (typeof m === 'string') {
    try {
      const p = JSON.parse(m) as unknown;
      return p && typeof p === 'object' && !Array.isArray(p)
        ? (p as Record<string, unknown>)
        : null;
    } catch {
      return null;
    }
  }
  return null;
}

/**
 * Sum the AI Gateway's computed cost (USD) for one chat turn, found by
 * the `turn_id` stamped into cf-aig-metadata on every LLM request of
 * that turn. Returns:
 *   - number               — matching gateway logs found; summed cost
 *   - null                 — not configured (no token/account/gateway),
 *                             or matching logs report no cost
 *   - GATEWAY_COST_PENDING  — configured, but no matching logs yet
 *                             (ingestion lag) — caller should retry
 */
export async function fetchGatewayCost(
  env: Env,
  turnId: string,
): Promise<number | null | GatewayCostPending> {
  const token = env.CF_AIG_TOKEN;
  const account = env.CF_ACCOUNT_ID;
  const gateway = env.CF_AIG_GATEWAY;
  if (!token || !account || !gateway) return null;

  const url =
    `https://api.cloudflare.com/client/v4/accounts/${account}` +
    `/ai-gateway/gateways/${gateway}/logs?per_page=100`;

  let body: { result?: GatewayLog[] };
  try {
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (res.status === 401 || res.status === 403) {
      // Bad/insufficient token — retrying won't help. Give up so the
      // turn settles instead of churning the queue into the DLQ.
      console.warn('[ai-gateway] logs API auth failed', res.status);
      return null;
    }
    if (!res.ok) {
      console.warn('[ai-gateway] logs API', res.status);
      return GATEWAY_COST_PENDING;
    }
    body = (await res.json()) as { result?: GatewayLog[] };
  } catch (err) {
    console.warn('[ai-gateway] logs API fetch failed', err);
    return GATEWAY_COST_PENDING;
  }

  const logs = Array.isArray(body.result) ? body.result : [];
  let matched = 0;
  let sum = 0;
  for (const log of logs) {
    if (parseMetadata(log.metadata)?.turn_id !== turnId) continue;
    matched++;
    const c =
      typeof log.cost === 'number'
        ? log.cost
        : typeof log.cost === 'string'
          ? Number(log.cost)
          : 0;
    if (Number.isFinite(c) && c > 0) sum += c;
  }
  // A successful turn always made at least one gateway request, so zero
  // matches means the logs haven't landed yet.
  if (matched === 0) return GATEWAY_COST_PENDING;
  return sum;
}
