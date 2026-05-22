// Random-model resolver for the arena feature. When a bot has
// config.arena set, every turn picks a fresh model from the catalog instead
// of the bot's pinned slug. The pool is defined by a price-multiplier window
// (the slider) UNIONed with an explicit model allowlist, minus an exclude
// list — so the price range is the "pool" and individual models can be
// hand-added (out of range) or hand-removed (in range).
//
// Pool = the OpenRouter long tail only (catalog `source === 'openrouter'`),
// deliberately NOT the synthesized native twins. Reasons:
//   - the native rows are dot/dash twins of openrouter rows, so including
//     both would double-weight those models in the random draw;
//   - one uniform route (openrouter passthrough) keeps the arena fair —
//     every contender is reached the same way, so the leaderboard reflects
//     the model, not the routing path.
// Every random pick therefore routes via openrouter (model_provider null).
//
// The catalog is cached in KV (the OpenRouter fetch is ~hundreds of ms and
// the turn path can't afford it every round). A cache miss falls back to a
// live fetch; a fetch failure makes pickRandomModel return null so the
// caller can fall back to the bot's pinned model.

import type { Env } from '../types';
import { buildModelCatalog, looksNonChat } from '../routes/models';

export interface RandomModelConfig {
  // Inclusive bounds on blended_usd_per_million (the same number the iOS
  // "Nx" badge shows). null = unbounded on that side. The slider drives
  // these; together they define the price-range pool.
  price_min: number | null;
  price_max: number | null;
  // Explicit model slugs the user multi-selected. Unioned with the
  // price-range pool. When this is the only thing set, the arena is exactly
  // these models. null / empty = no explicit picks.
  models: string[] | null;
  // Models to drop from the pool (hand-removed in-range rows). null/empty = none.
  exclude: string[] | null;
}

export interface PickedModel {
  slug: string;
  // Routing hint stored on the message + handed to the LLM router. Always
  // null for random picks (openrouter passthrough).
  modelProvider: null;
  vendor: string;
  blendedUsdPerMillion: number | null;
}

// Slimmed catalog row cached in KV — only the fields the resolver needs.
interface PoolEntry {
  slug: string;
  vendor: string;
  price: number | null;
}

const POOL_CACHE_KEY = 'arena:model_pool';
const POOL_TTL_SEC = 3600;

// Parse the jsonb blob stored on bots.config.arena into a validated config,
// or null when the value isn't a usable arena config (absent / wrong shape
// → "not in arena mode").
export function parseRandomModelConfig(raw: unknown): RandomModelConfig | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  const num = (v: unknown): number | null =>
    typeof v === 'number' && Number.isFinite(v) ? v : null;
  const strs = (v: unknown): string[] | null => {
    if (!Array.isArray(v)) return null;
    const a = v.filter((x): x is string => typeof x === 'string' && x.length > 0);
    return a.length > 0 ? a : null;
  };
  return {
    price_min: num(o.price_min),
    price_max: num(o.price_max),
    models: strs(o.models),
    exclude: strs(o.exclude),
  };
}

// Build the chat-only openrouter pool from the full catalog.
function poolFromCatalog(catalog: Awaited<ReturnType<typeof buildModelCatalog>>): PoolEntry[] {
  const pool: PoolEntry[] = [];
  for (const m of catalog) {
    if (m.source !== 'openrouter') continue;
    const slash = m.slug.indexOf('/');
    const tail = slash > 0 ? m.slug.slice(slash + 1) : m.slug;
    if (looksNonChat(tail)) continue;
    pool.push({ slug: m.slug, vendor: m.provider, price: m.blended_usd_per_million });
  }
  return pool;
}

// KV-cached pool. Miss → live fetch + write-through. Fetch failure →
// null (caller falls back to the pinned model).
async function getPool(env: Env): Promise<PoolEntry[] | null> {
  const cached = await env.MEMORY.get<PoolEntry[]>(POOL_CACHE_KEY, 'json');
  if (cached && cached.length > 0) return cached;
  try {
    const pool = poolFromCatalog(await buildModelCatalog());
    if (pool.length > 0) {
      await env.MEMORY.put(POOL_CACHE_KEY, JSON.stringify(pool), {
        expirationTtl: POOL_TTL_SEC,
      });
    }
    return pool;
  } catch (err) {
    console.warn('[random-model] catalog fetch failed', err);
    return null;
  }
}

// Resolve the arena pool: (price-range members ∪ explicit `models`) − `exclude`.
// When `models` is set but no price bound is given, the pool is ONLY those
// explicit models (multi-select with no range). All bounds absent + no
// models = the whole chat catalog.
export function filterPool(pool: PoolEntry[], cfg: RandomModelConfig): PoolEntry[] {
  const include = cfg.models ? new Set(cfg.models) : null;
  const exclude = cfg.exclude ? new Set(cfg.exclude) : null;
  const hasPriceBound = cfg.price_min != null || cfg.price_max != null;
  return pool.filter((m) => {
    if (exclude?.has(m.slug)) return false;
    if (include?.has(m.slug)) return true;
    if (cfg.price_min != null && (m.price == null || m.price < cfg.price_min)) return false;
    if (cfg.price_max != null && (m.price == null || m.price > cfg.price_max)) return false;
    // Explicit picks with no price range → the pool is exactly those picks.
    if (include && !hasPriceBound) return false;
    return true;
  });
}

// Pick one random model satisfying the config. excludeSlugs drops models
// already used under the same prompt (so a regenerated variant lands a
// DIFFERENT model when the constrained pool still has alternatives).
// Returns null when no candidate qualifies — caller falls back.
export async function pickRandomModel(
  env: Env,
  cfg: RandomModelConfig,
  opts?: { excludeSlugs?: string[] },
): Promise<PickedModel | null> {
  const pool = await getPool(env);
  if (!pool || pool.length === 0) return null;

  let candidates = filterPool(pool, cfg);
  const exclude = opts?.excludeSlugs;
  if (exclude && exclude.length > 0) {
    const without = candidates.filter((m) => !exclude.includes(m.slug));
    // Only honor the exclusion when it leaves something to pick — a
    // 1-model pool shouldn't dead-end a regenerate.
    if (without.length > 0) candidates = without;
  }
  if (candidates.length === 0) return null;

  const chosen = candidates[Math.floor(Math.random() * candidates.length)];
  return {
    slug: chosen.slug,
    modelProvider: null,
    vendor: chosen.vendor,
    blendedUsdPerMillion: chosen.price,
  };
}
