import type { SupabaseClient } from './supabase';

// Web-tool metering — the single chokepoint that records every external
// search / scrape call so it lands in audit_web_tool_calls and folds
// into the parent audit_log row's billable credits.
//
// Shape:
//   - WebToolMeter is owned by the caller that runs an LLM turn
//     (bot-reply for chat replies, envelope-runner for letters). One meter
//     per turn; the same instance is threaded into every tool call made
//     during that turn.
//   - Web tools are MCP tools (see mcp/client.ts). mcpClient.callTool
//     ALWAYS calls meter.record — on both success and error — for any
//     tool in its TOOL_BILLING map, so a billable web call can't bypass
//     metering.
//   - At the end of the turn, the caller hands meter.snapshot() to
//     enqueueAudit (router.ts) as `webTools`. persistAuditMessage writes
//     the rollup onto audit_log.tool_cost_usd, sums it into cost_credits
//     for the single billing_debit, and inserts a child row per call
//     into audit_web_tool_calls.
//
// Pricing is loaded lazily from web_tool_prices on first use; recently
// resolved prices are cached in module scope so repeated calls within
// the same isolate share the same price map. We treat the cache as
// best-effort — a stale price for a few minutes after an admin edit is
// acceptable because the cache TTL is short and the rare drift only
// affects margin, not correctness.

export type WebToolProvider = 'brave' | 'tavily' | 'exa' | 'serper' | 'firecrawl';
export type WebToolKind = 'search' | 'scrape';

export interface WebToolUsage {
  provider: WebToolProvider;
  kind: WebToolKind;
  /** Truncated to TARGET_MAX_CHARS before insert. */
  target: string;
  status: 'success' | 'error';
  errorClass?: string | null;
  latencyMs: number;
  /** Only meaningful for kind='search'; undefined for scrapes. */
  resultCount?: number;
  /** Wholesale USD per spec sheet; 0 on error or when no price row exists. */
  costUsd: number;
}

const TARGET_MAX_CHARS = 500;

// Module-scope price cache. The worker isolate is short-lived (one
// request) most of the time on Cloudflare, so this is effectively a
// per-request cache; if the isolate sticks around longer the TTL keeps
// drift bounded.
const PRICE_TTL_MS = 60_000;
let priceCache: { at: number; map: Record<string, number> } | null = null;

function priceKey(provider: WebToolProvider, kind: WebToolKind): string {
  return `${provider}:${kind}`;
}

async function loadPrices(supa: SupabaseClient): Promise<Record<string, number>> {
  const now = Date.now();
  if (priceCache && now - priceCache.at < PRICE_TTL_MS) return priceCache.map;
  const { data, error } = await supa
    .from('web_tool_prices')
    .select('provider, kind, unit_cost_usd');
  if (error || !data) {
    // Soft-fail: empty map means every call records cost 0 but still
    // lands in audit_web_tool_calls for diagnostics. Better than
    // throwing and breaking the LLM turn.
    console.warn('[web-meter] price load failed', error?.message ?? 'no data');
    priceCache = { at: now, map: {} };
    return priceCache.map;
  }
  const map: Record<string, number> = {};
  for (const r of data as Array<{ provider: string; kind: string; unit_cost_usd: number | string }>) {
    const v = typeof r.unit_cost_usd === 'number' ? r.unit_cost_usd : Number(r.unit_cost_usd);
    if (Number.isFinite(v) && v >= 0) {
      map[`${r.provider}:${r.kind}`] = v;
    }
  }
  priceCache = { at: now, map };
  return map;
}

/**
 * Per-turn accumulator. Owned by the LLM-turn driver
 * (bot-reply.runChatTurn, envelope-runner.runEnvelope). All web-tool calls
 * made during that turn route through `record`; the final snapshot is
 * passed to recordAudit.
 *
 * Construction is async because the price map comes from DB; callers
 * use the `create` static.
 */
export class WebToolMeter {
  private readonly prices: Record<string, number>;
  private readonly calls: WebToolUsage[] = [];

  private constructor(prices: Record<string, number>) {
    this.prices = prices;
  }

  static async create(supa: SupabaseClient): Promise<WebToolMeter> {
    const prices = await loadPrices(supa);
    return new WebToolMeter(prices);
  }

  /** For tests or paths that already have a price map in hand. */
  static withPrices(prices: Record<string, number>): WebToolMeter {
    return new WebToolMeter({ ...prices });
  }

  /**
   * Record one call. Cost lookup runs against the price map captured at
   * meter construction; an unknown (provider, kind) records cost 0 and
   * a warning. Success-only billing matches the LLM rule (don't charge
   * for failures).
   */
  record(call: {
    provider: WebToolProvider;
    kind: WebToolKind;
    target: string;
    status: 'success' | 'error';
    errorClass?: string | null;
    latencyMs: number;
    resultCount?: number;
  }): void {
    const unit = this.prices[priceKey(call.provider, call.kind)];
    if (unit == null) {
      console.warn(
        `[web-meter] no price row for ${call.provider}:${call.kind} — recording cost 0`,
      );
    }
    const cost = call.status === 'success' ? (unit ?? 0) : 0;
    this.calls.push({
      provider: call.provider,
      kind: call.kind,
      target: call.target.length > TARGET_MAX_CHARS
        ? call.target.slice(0, TARGET_MAX_CHARS)
        : call.target,
      status: call.status,
      errorClass: call.errorClass ?? null,
      latencyMs: call.latencyMs,
      resultCount: call.resultCount,
      costUsd: cost,
    });
  }

  snapshot(): WebToolUsage[] {
    // Defensive copy so a caller mutating the returned array (or pushing
    // into it later) doesn't affect the meter, and vice versa.
    return this.calls.slice();
  }

  totalCostUsd(): number {
    let sum = 0;
    for (const c of this.calls) sum += c.costUsd;
    return sum;
  }

  isEmpty(): boolean {
    return this.calls.length === 0;
  }
}
