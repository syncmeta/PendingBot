// Model-pool resolver. A bot can define a pool with a price-multiplier window
// (the slider) UNIONed with an explicit model allowlist, minus an exclude list.
// A new conversation draws its main model from that pool once, while blind
// regenerated answers can draw candidate models without changing the current
// conversation model.
//
// Pool = native rows for OpenAI / Anthropic / Google plus the OpenRouter long
// tail. The shared /v1/models catalog already removes OpenRouter rows for
// native-backed providers, including their `~...latest` aliases, so these
// families appear once and route through their native provider.
//
// The catalog is cached in KV (the OpenRouter fetch is ~hundreds of ms and
// the turn path can't afford it every round). A cache miss falls back to a
// live fetch; a fetch failure makes pickRandomModel return null so the
// caller can fall back to the bot's pinned model.

import type { Env } from '../types';
import {
  buildModelCatalog,
  fetchLMArenaRows,
  isNativeBackedOpenRouterSlug,
  looksNonChat,
} from '../routes/models';
import { resolveModelPreset, makeCatalogProvider, type PresetDef } from '../lib/model-presets';
import { serviceClient } from '../lib/supabase';

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
  // Allowed vendors/providers. null = all vendors; [] = no vendors.
  vendors: string[] | null;
  // Relative release window in days. null = all release dates.
  release_window_days: number | null;
  // 选中的模型预设 slug（model_presets.slug）。对话时展开成模型并集并入 models。
  // null/empty = 无预设（纯显式/自定义）。
  presets: string[] | null;
}

export interface PickedModel {
  slug: string;
  // Routing hint stored on the message + handed to the LLM router. Native
  // rows carry their provider slug; OpenRouter rows stay null.
  modelProvider: string | null;
  vendor: string;
  blendedUsdPerMillion: number | null;
}

// Slimmed catalog row cached in KV — only the fields the resolver needs.
interface PoolEntry {
  slug: string;
  vendor: string;
  price: number | null;
  releaseDate: string | null;
  modelProvider: string | null;
}

const POOL_CACHE_KEY = 'model_pool:v2';
const POOL_TTL_SEC = 3600;

// Parse the jsonb blob stored on bots.config.modelPool into a validated config,
// or null when the value isn't a usable model-pool config.
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
  const vendorStrs = (v: unknown): string[] | null => {
    if (!Array.isArray(v)) return null;
    return v.filter((x): x is string => typeof x === 'string' && x.length > 0);
  };
  return {
    price_min: num(o.price_min),
    price_max: num(o.price_max),
    models: strs(o.models),
    exclude: strs(o.exclude),
    vendors: vendorStrs(o.vendors),
    release_window_days: num(o.release_window_days),
    presets: strs(o.presets),
  };
}

// Build the chat-only arena pool from the full catalog.
export function poolFromCatalog(catalog: Awaited<ReturnType<typeof buildModelCatalog>>): PoolEntry[] {
  const pool: PoolEntry[] = [];
  for (const m of catalog) {
    if (m.source === 'openrouter' && isNativeBackedOpenRouterSlug(m.slug)) continue;
    const slash = m.slug.indexOf('/');
    const tail = slash > 0 ? m.slug.slice(slash + 1) : m.slug;
    if (looksNonChat(tail)) continue;
    pool.push({
      slug: m.slug,
      vendor: m.provider,
      price: m.blended_usd_per_million,
      releaseDate: m.release_date,
      modelProvider: m.model_provider,
    });
  }
  return pool;
}

// KV-cached pool. Miss → live fetch + write-through. Fetch failure →
// null (caller falls back to the pinned model).
async function getPool(env: Env): Promise<PoolEntry[] | null> {
  const cached = await env.MEMORY.get<PoolEntry[]>(POOL_CACHE_KEY, 'json');
  if (cached && cached.length > 0) return cached;
  try {
    const pool = poolFromCatalog(await buildModelCatalog(await fetchLMArenaRows(env)));
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
  const vendors = cfg.vendors ? new Set(cfg.vendors) : null;
  const releaseAfter = releaseCutoff(cfg.release_window_days);
  const hasPriceBound = cfg.price_min != null || cfg.price_max != null;
  return pool.filter((m) => {
    if (exclude?.has(m.slug)) return false;
    if (vendors && !vendors.has(m.vendor)) return false;
    if (releaseAfter && (!m.releaseDate || m.releaseDate < releaseAfter)) return false;
    if (include?.has(m.slug)) return true;
    if (cfg.price_min != null && (m.price == null || m.price < cfg.price_min)) return false;
    if (cfg.price_max != null && (m.price == null || m.price > cfg.price_max)) return false;
    // Explicit picks with no price range → the pool is exactly those picks.
    if (include && !hasPriceBound) return false;
    return true;
  });
}

function releaseCutoff(releaseWindowDays: number | null): string | null {
  if (releaseWindowDays == null || releaseWindowDays <= 0) return null;
  const now = new Date();
  const cutoff = new Date(now.getTime() - releaseWindowDays * 24 * 60 * 60 * 1000);
  return cutoff.toISOString().slice(0, 10);
}

// Pick one random model satisfying the config. excludeSlugs drops models
// already used under the same prompt (so a regenerated variant lands a
// DIFFERENT model when the constrained pool still has alternatives).
// Returns null when no candidate qualifies — caller falls back.
export type PresetResolver = (presetSlugs: string[]) => Promise<string[]>;

// 把 cfg.presets 解析成模型并集并入 cfg.models；展开后清空 presets，避免下游重复解析。
// 无 presets 时原样返回。resolve 注入以便单测。
export async function expandPresets(
  cfg: RandomModelConfig,
  resolve: PresetResolver,
): Promise<RandomModelConfig> {
  if (!cfg.presets || cfg.presets.length === 0) return cfg;
  let presetSlugs: string[];
  try {
    presetSlugs = await resolve(cfg.presets);
  } catch (err) {
    // Resolution (DB read / catalog fetch) failed — degrade to an empty pool
    // so the caller falls back to the pinned model, never aborts the turn.
    console.warn('[random-model] preset resolution failed', err);
    presetSlugs = [];
  }
  const merged = [...new Set([...(cfg.models ?? []), ...presetSlugs])];
  // presets were requested → `models` is now an EXPLICIT pool (possibly empty).
  // Keep it an array even when empty: filterPool then yields nothing →
  // pickRandomModel returns null → caller falls back to bots.model_id. Leaving
  // it null would make filterPool treat it as "no filter" and draw from the
  // WHOLE catalog (an off-pool model), violating the fallback contract.
  return { ...cfg, models: merged, presets: null };
}

// 读 model_presets 定义（service role 绕过 RLS）→ resolveModelPreset（KV 缓存）→ 模型并集。
async function resolvePresetsToSlugs(env: Env, presetSlugs: string[]): Promise<string[]> {
  const db = serviceClient(env).schema('pendingbot');
  const { data, error } = await db
    .from('model_presets')
    .select('slug, title, description, resolver_kind, params, default_selected')
    .in('slug', presetSlugs)
    .eq('enabled', true);
  if (error) console.warn('[random-model] model_presets read failed', error.message);
  const defs = (data ?? []) as unknown as PresetDef[];
  // 同一 turn 内多个预设共享一份目录（冷缓存时只 build 一次而非 N 次）。
  const provider = makeCatalogProvider(env);
  const resolved = await Promise.all(defs.map((d) => resolveModelPreset(env, d, provider)));
  return [...new Set(resolved.flatMap((r) => r.models.map((m) => m.slug)))];
}

export async function pickRandomModel(
  env: Env,
  cfg: RandomModelConfig,
  opts?: { excludeSlugs?: string[] },
): Promise<PickedModel | null> {
  const pool = await getPool(env);
  if (!pool || pool.length === 0) return null;

  const effectiveCfg = await expandPresets(cfg, (slugs) => resolvePresetsToSlugs(env, slugs));
  let candidates = filterPool(pool, effectiveCfg);
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
    modelProvider: chosen.modelProvider,
    vendor: chosen.vendor,
    blendedUsdPerMillion: chosen.price,
  };
}
