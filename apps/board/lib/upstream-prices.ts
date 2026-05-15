// Upstream price fetcher — manual "pull from provider" flow for the
// board /aliases/upstream page. Different providers expose pricing
// differently; we dispatch by provider.slug and by the
// `config.pricing_source` knob on the provider row.
//
// Supported strategies today:
//   - openrouter (hardcoded): GET https://openrouter.ai/api/v1/models
//     → per-token USD strings; we multiply by 1e6 so units match
//     llm_model_aliases.{input,cached_input,output,cache_write}_price
//     which store USD per million tokens.
//   - mirror: provider.config.pricing_source = { kind: 'mirror',
//     source_slug: <some other provider's slug>, factor: <number> }
//     → for each alias on this provider, find the alias of the same
//     canonical model on the source provider, multiply each price by
//     factor. Used by WorldRouter (~70% of OpenRouter list).
//
// Anything else returns "unsupported" so the diff page can render
// "no upstream fetch wired up" for those rows.

import type { SupabaseClient } from '@supabase/supabase-js';
import type { Database } from '@pendingbot/edge/db/schema';

type SupaAdmin = SupabaseClient<Database, 'pendingbot'>;

export interface UpstreamPriceSet {
  /** USD per million tokens; null = unknown / not exposed. */
  input_price: number | null;
  cached_input_price: number | null;
  output_price: number | null;
  cache_write_price: number | null;
}

export interface PricingSourceMirror {
  kind: 'mirror';
  source_slug: string;
  factor: number;
}

/**
 * Decoded pricing strategy off a provider row's config. Anything not
 * matching falls back to 'unsupported'.
 */
export type PricingSource =
  | { kind: 'openrouter' }
  | { kind: 'worldrouter_public' }
  | PricingSourceMirror
  | { kind: 'unsupported'; reason: string };

export function decodePricingSource(
  providerSlug: string,
  config: unknown,
): PricingSource {
  if (config && typeof config === 'object' && !Array.isArray(config)) {
    const c = config as Record<string, unknown>;
    const src = c.pricing_source;
    if (src && typeof src === 'object' && !Array.isArray(src)) {
      const s = src as Record<string, unknown>;
      if (s.kind === 'openrouter') return { kind: 'openrouter' };
      if (s.kind === 'worldrouter_public') return { kind: 'worldrouter_public' };
      if (s.kind === 'mirror') {
        const source_slug = typeof s.source_slug === 'string' ? s.source_slug : '';
        const factor = Number(s.factor);
        if (source_slug && Number.isFinite(factor) && factor > 0) {
          return { kind: 'mirror', source_slug, factor };
        }
        return {
          kind: 'unsupported',
          reason: 'mirror config missing source_slug / valid factor',
        };
      }
    }
  }
  // Legacy fallback: providers seeded before pricing_source was wired
  // up. The 20260515 migration backfills both openrouter and
  // worldrouter, so this branch only fires for hand-added rows.
  if (providerSlug === 'openrouter') return { kind: 'openrouter' };
  return {
    kind: 'unsupported',
    reason: 'provider has no pricing_source — admin enters prices by hand',
  };
}

// ── OpenRouter native fetch ─────────────────────────────────────────────
// Anonymous GET — the /v1/models endpoint is public. Mirrors the cron's
// shape (apps/edge/src/cron/model-pricing.ts) but multiplies by 1e6 so
// units align with llm_model_aliases.

interface OpenRouterModel {
  id: string;
  pricing?: {
    prompt?: string;
    completion?: string;
    input_cache_read?: string;
    input_cache_write?: string;
  };
}

const PER_MILLION = 1_000_000;

function parsePerMillion(s: string | undefined): number | null {
  if (!s) return null;
  const n = Number(s);
  if (!Number.isFinite(n) || n < 0) return null;
  return n * PER_MILLION;
}

let openRouterCache: { at: number; map: Map<string, UpstreamPriceSet> } | null = null;
const OPENROUTER_TTL_MS = 5 * 60_000;

export async function fetchOpenRouterCatalog(): Promise<
  Map<string, UpstreamPriceSet>
> {
  const now = Date.now();
  if (openRouterCache && now - openRouterCache.at < OPENROUTER_TTL_MS) {
    return openRouterCache.map;
  }
  const res = await fetch('https://openrouter.ai/api/v1/models', {
    // No auth — /v1/models is public. Add an API key only if a 401
    // shows up in practice (rate-limited anon access).
    headers: { Accept: 'application/json' },
  });
  if (!res.ok) {
    throw new Error(
      `openrouter /v1/models ${res.status}: ${(await res.text()).slice(0, 300)}`,
    );
  }
  const json = (await res.json()) as { data?: OpenRouterModel[] };
  const map = new Map<string, UpstreamPriceSet>();
  for (const m of json.data ?? []) {
    if (!m.id) continue;
    map.set(m.id, {
      input_price: parsePerMillion(m.pricing?.prompt),
      cached_input_price: parsePerMillion(m.pricing?.input_cache_read),
      output_price: parsePerMillion(m.pricing?.completion),
      cache_write_price: parsePerMillion(m.pricing?.input_cache_write),
    });
  }
  openRouterCache = { at: now, map };
  return map;
}

// ── WorldRouter public-page scrape ──────────────────────────────────────
// WorldRouter doesn't expose pricing through their inference API or
// control plane (the control-plane /supported-models endpoint exists
// but is session-cookie protected). The public /models page, however,
// SSRs prices into data-model-* attributes on each card row:
//
//   <div data-model-id="claude-haiku-4-5"
//        data-model-provider="Anthropic"
//        data-model-input-price="70 Credits"
//        data-model-output-price="350 Credits"
//        data-model-cache-read-price="7 Credits"
//        data-model-cache-write-price="87.5 Credits">
//
// 1 Credit = $0.01 USD (verified against the closed-source 0.7× discount:
// Claude Haiku 4.5 = 70 Credits = $0.70/M = OpenRouter's $1/M × 0.7).
// So price-in-USD-per-1M = credits × 0.01.

const WORLDROUTER_MODELS_URL = 'https://www.worldrouter.ai/models';
const CREDIT_TO_USD = 0.01;

function parseCredits(s: string | null | undefined): number | null {
  if (!s) return null;
  const trimmed = s.trim();
  if (!trimmed || trimmed === 'N/A') return null;
  if (trimmed === 'Free' || trimmed === '0 Credits') return 0;
  // "1,750 Credits" → 1750; "9.8 Credits" → 9.8
  const m = trimmed.match(/^([\d,]+(?:\.\d+)?)\s*Credits?$/i);
  if (!m) return null;
  const n = Number(m[1]!.replace(/,/g, ''));
  if (!Number.isFinite(n) || n < 0) return null;
  return n * CREDIT_TO_USD;
}

let worldRouterCache: { at: number; map: Map<string, UpstreamPriceSet> } | null = null;
const WORLDROUTER_TTL_MS = 5 * 60_000;

/**
 * Fetch and parse the WorldRouter public models page. Returns a map
 * keyed by the WR model id (matches what we store in
 * llm_model_aliases.provider_model_id for WR rows, e.g.
 * "claude-haiku-4-5"). All prices are in USD per 1M tokens.
 *
 * Implementation note: we deliberately parse with regex rather than
 * pulling in a DOM library — the cards are flat tags with no nested
 * structure to walk, and shipping cheerio (~150KB) for one selector
 * isn't worth it. If WR ever rearranges the markup so the data-model-*
 * attributes don't sit together on the opening tag, switch to a real
 * parser. */
export async function fetchWorldRouterCatalog(): Promise<
  Map<string, UpstreamPriceSet>
> {
  const now = Date.now();
  if (worldRouterCache && now - worldRouterCache.at < WORLDROUTER_TTL_MS) {
    return worldRouterCache.map;
  }
  const res = await fetch(WORLDROUTER_MODELS_URL, {
    headers: { Accept: 'text/html' },
  });
  if (!res.ok) {
    throw new Error(
      `worldrouter /models ${res.status}: ${(await res.text()).slice(0, 300)}`,
    );
  }
  const html = await res.text();
  const map = new Map<string, UpstreamPriceSet>();
  // Each card opens with a div whose attrs include data-model-id and
  // four price attributes. Capture the tag and extract attrs from it.
  const tagRe = /<[a-z]+\s[^>]*data-model-id="[^"]+"[^>]*>/g;
  const attr = (tag: string, key: string): string | null => {
    const m = tag.match(new RegExp(`${key}="([^"]*)"`));
    return m ? m[1]! : null;
  };
  for (const m of html.matchAll(tagRe)) {
    const tag = m[0];
    const id = attr(tag, 'data-model-id');
    if (!id) continue;
    map.set(id, {
      input_price: parseCredits(attr(tag, 'data-model-input-price')),
      cached_input_price: parseCredits(attr(tag, 'data-model-cache-read-price')),
      output_price: parseCredits(attr(tag, 'data-model-output-price')),
      cache_write_price: parseCredits(attr(tag, 'data-model-cache-write-price')),
    });
  }
  if (map.size === 0) {
    // Page changed shape — fail loudly rather than silently returning
    // empty. The /aliases/upstream page surfaces this as an error.
    throw new Error(
      'worldrouter /models returned 0 parseable cards — page markup likely changed',
    );
  }
  worldRouterCache = { at: now, map };
  return map;
}

/** For tests / forcing a fresh pull from the board UI. */
export function _resetUpstreamCatalogCache(): void {
  openRouterCache = null;
  worldRouterCache = null;
}

// ── Per-alias resolution ───────────────────────────────────────────────

export interface AliasForResolution {
  aliasId: string;
  /** canonical model id (uuid) on llm_models — used for mirror lookup. */
  modelId: string;
  /** provider_model_id on this alias — used as the OpenRouter catalog key. */
  providerModelId: string;
  /** parent provider slug — drives strategy. */
  providerSlug: string;
  /** parent provider's config — drives strategy. */
  providerConfig: unknown;
  current: UpstreamPriceSet;
}

/**
 * Resolve upstream prices for one alias. Returns null when no upstream
 * value can be determined (unsupported strategy, model not in catalog,
 * mirror source missing). Caller surfaces the reason in the diff UI.
 */
export async function resolveUpstreamPrices(
  alias: AliasForResolution,
  ctx: {
    openRouter: Map<string, UpstreamPriceSet>;
    worldRouter: Map<string, UpstreamPriceSet>;
    /** aliasId → AliasForResolution for every enabled alias across all
     * providers. Used to find mirror sources without an extra DB query
     * per alias. */
    aliasesByProviderAndModel: Map<string, Map<string, AliasForResolution>>;
  },
): Promise<{ prices: UpstreamPriceSet | null; reason?: string }> {
  const strategy = decodePricingSource(alias.providerSlug, alias.providerConfig);

  if (strategy.kind === 'openrouter') {
    const hit = ctx.openRouter.get(alias.providerModelId);
    if (!hit) {
      return {
        prices: null,
        reason: `model "${alias.providerModelId}" not in OpenRouter catalog`,
      };
    }
    return { prices: hit };
  }

  if (strategy.kind === 'worldrouter_public') {
    const hit = ctx.worldRouter.get(alias.providerModelId);
    if (!hit) {
      return {
        prices: null,
        reason: `model "${alias.providerModelId}" not on the WorldRouter public catalog — update provider_model_id to match WR's id (e.g. "claude-haiku-4-5")`,
      };
    }
    return { prices: hit };
  }

  if (strategy.kind === 'mirror') {
    // Find the alias on the source provider that maps to the same
    // canonical model. Without it we can't compute a mirror price.
    const sourceProviderAliases = ctx.aliasesByProviderAndModel.get(
      strategy.source_slug,
    );
    const sourceAlias = sourceProviderAliases?.get(alias.modelId);
    if (!sourceAlias) {
      return {
        prices: null,
        reason: `no alias on '${strategy.source_slug}' for this canonical model`,
      };
    }
    // Recurse one level — the source alias should be a native one. If
    // somebody chains mirror→mirror→… we just refuse, to keep this
    // bounded.
    const sourceStrategy = decodePricingSource(
      sourceAlias.providerSlug,
      sourceAlias.providerConfig,
    );
    if (sourceStrategy.kind !== 'openrouter') {
      return {
        prices: null,
        reason: `mirror source '${strategy.source_slug}' is not a native pricing source`,
      };
    }
    const hit = ctx.openRouter.get(sourceAlias.providerModelId);
    if (!hit) {
      return {
        prices: null,
        reason: `mirror source '${sourceAlias.providerModelId}' not in OpenRouter catalog`,
      };
    }
    return {
      prices: {
        input_price: scale(hit.input_price, strategy.factor),
        cached_input_price: scale(hit.cached_input_price, strategy.factor),
        output_price: scale(hit.output_price, strategy.factor),
        cache_write_price: scale(hit.cache_write_price, strategy.factor),
      },
    };
  }

  return { prices: null, reason: strategy.reason };
}

function scale(v: number | null, factor: number): number | null {
  if (v == null) return null;
  // Round to 6 decimal places — matches numeric(12,6) column precision
  // so the "new value" we render is exactly what'll land in the DB.
  return Math.round(v * factor * 1e6) / 1e6;
}

// ── Top-level orchestration ────────────────────────────────────────────

export interface AliasDiffRow {
  aliasId: string;
  modelSlug: string;
  modelDisplayName: string;
  providerSlug: string;
  providerModelId: string;
  current: UpstreamPriceSet;
  upstream: UpstreamPriceSet | null;
  /** Per-field change flag, true iff value differs (treats null vs 0 as same). */
  changed: {
    input_price: boolean;
    cached_input_price: boolean;
    output_price: boolean;
    cache_write_price: boolean;
  };
  /** Set when upstream is null OR no field changed. */
  note: string | null;
}

/**
 * Walk every enabled alias and compute its diff vs upstream. Used by
 * the /aliases/upstream page on Pull. One call fans out a single
 * fetch to OpenRouter (cached) + one Supabase query for aliases.
 */
export async function buildUpstreamDiff(
  supa: SupaAdmin,
): Promise<{ rows: AliasDiffRow[]; fetchedAt: string }> {
  // Catalogs first — if either fails we throw early before doing DB work.
  // Both fetches are independent so run them in parallel; the cache
  // (5-min TTL) absorbs back-to-back Pull clicks.
  const [openRouter, worldRouter] = await Promise.all([
    fetchOpenRouterCatalog(),
    fetchWorldRouterCatalog(),
  ]);
  const fetchedAt = new Date().toISOString();

  const { data, error } = await supa
    .from('llm_model_aliases')
    .select(
      `id, model_id, provider_id, provider_model_id, enabled,
       input_price, cached_input_price, output_price, cache_write_price,
       llm_models ( slug, display_name ),
       llm_providers ( slug, config )`,
    )
    .eq('enabled', true);
  if (error) throw new Error(`load aliases: ${error.message}`);

  type Row = NonNullable<typeof data>[number] & {
    llm_models: { slug: string; display_name: string } | null;
    llm_providers: { slug: string; config: unknown } | null;
  };
  const rows = (data ?? []) as Row[];

  // Index aliases for mirror resolution: provider_slug → model_id → alias.
  const byProvider = new Map<string, Map<string, AliasForResolution>>();
  const resolutionList: AliasForResolution[] = [];
  for (const r of rows) {
    if (!r.llm_providers || !r.llm_models) continue;
    const resolution: AliasForResolution = {
      aliasId: r.id,
      modelId: r.model_id,
      providerModelId: r.provider_model_id,
      providerSlug: r.llm_providers.slug,
      providerConfig: r.llm_providers.config,
      current: {
        input_price: r.input_price as number | null,
        cached_input_price: r.cached_input_price as number | null,
        output_price: r.output_price as number | null,
        cache_write_price: r.cache_write_price as number | null,
      },
    };
    let providerMap = byProvider.get(resolution.providerSlug);
    if (!providerMap) {
      providerMap = new Map();
      byProvider.set(resolution.providerSlug, providerMap);
    }
    // First-write-wins on collision (shouldn't happen — (model_id,
    // provider_id) is meant to be unique per alias row in practice).
    if (!providerMap.has(resolution.modelId)) {
      providerMap.set(resolution.modelId, resolution);
    }
    resolutionList.push(resolution);
  }

  const out: AliasDiffRow[] = [];
  for (const a of resolutionList) {
    const row = rows.find((r) => r.id === a.aliasId);
    const model = row?.llm_models;
    const { prices, reason } = await resolveUpstreamPrices(a, {
      openRouter,
      worldRouter,
      aliasesByProviderAndModel: byProvider,
    });
    const changed = {
      input_price: differs(a.current.input_price, prices?.input_price ?? null),
      cached_input_price: differs(
        a.current.cached_input_price,
        prices?.cached_input_price ?? null,
      ),
      output_price: differs(a.current.output_price, prices?.output_price ?? null),
      cache_write_price: differs(
        a.current.cache_write_price,
        prices?.cache_write_price ?? null,
      ),
    };
    const anyChanged =
      changed.input_price ||
      changed.cached_input_price ||
      changed.output_price ||
      changed.cache_write_price;
    out.push({
      aliasId: a.aliasId,
      modelSlug: model?.slug ?? '(unknown)',
      modelDisplayName: model?.display_name ?? '',
      providerSlug: a.providerSlug,
      providerModelId: a.providerModelId,
      current: a.current,
      upstream: prices,
      changed,
      note: !prices ? reason ?? null : anyChanged ? null : 'no change',
    });
  }

  // Sort: changed rows first (most actionable), then by model slug for
  // stable scanning.
  out.sort((a, b) => {
    const aHas = a.upstream != null && a.note == null;
    const bHas = b.upstream != null && b.note == null;
    if (aHas !== bHas) return aHas ? -1 : 1;
    if (a.modelSlug !== b.modelSlug) return a.modelSlug.localeCompare(b.modelSlug);
    return a.providerSlug.localeCompare(b.providerSlug);
  });

  return { rows: out, fetchedAt: fetchedAt };
}

function differs(a: number | null, b: number | null): boolean {
  if (a == null && b == null) return false;
  if (a == null || b == null) return true;
  // 6-decimal precision matches the numeric(12,6) column.
  return Math.round(a * 1e6) !== Math.round(b * 1e6);
}
