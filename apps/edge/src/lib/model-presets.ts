import type { Env } from '../types';
import {
  buildModelCatalog,
  fetchLMArenaRows,
  isNativeBackedOpenRouterSlug,
  looksNonChat,
  type OpenRouterModelOut,
} from '../routes/models';

export type ResolverKind =
  | 'top_flagship' | 'chinese_flagship' | 'latest_per_vendor'
  | 'fastest' | 'most_popular' | 'manual';

export interface PresetParams {
  authors?: string[];
  flagship?: 'most_expensive' | 'latest' | 'latest_in_series';
  series?: string;            // glob 前缀，如 'claude-opus-'，latest_in_series 用
  count?: number;
  min_rating?: number;
  manual_models?: string[];
}

export interface PresetDef {
  slug: string;
  title: string;
  description: string;
  resolver_kind: ResolverKind;
  params: PresetParams;
  default_selected?: boolean;
}

export interface ResolvedPreset {
  slug: string;
  title: string;
  description: string;
  default_selected: boolean;
  models: { slug: string; display_name: string; provider: string }[];
}

const PRESET_CACHE_PREFIX = 'model_preset:v1:';
const PRESET_TTL_SEC = 6 * 60 * 60;

// chat-only catalog 行（排除 native-backed OpenRouter 双胞胎 + 非 chat）
function chatRows(catalog: OpenRouterModelOut[]): OpenRouterModelOut[] {
  return catalog.filter((m) => {
    if (m.source === 'openrouter' && isNativeBackedOpenRouterSlug(m.slug)) return false;
    const slash = m.slug.indexOf('/');
    const tail = slash > 0 ? m.slug.slice(slash + 1) : m.slug;
    return !looksNonChat(tail);
  });
}

function ratingOf(m: OpenRouterModelOut): number | null {
  return m.lmarena_scores?.text?.rating ?? null;
}

function flagshipForAuthor(rows: OpenRouterModelOut[], strategy: PresetParams['flagship'], series?: string): OpenRouterModelOut | null {
  let pool = rows;
  if (strategy === 'latest_in_series' && series) {
    pool = rows.filter((m) => m.slug.includes(series));
  }
  if (pool.length === 0) return null;
  if (strategy === 'latest' || strategy === 'latest_in_series') {
    return [...pool].sort((a, b) => (b.release_date ?? '').localeCompare(a.release_date ?? ''))[0];
  }
  // most_expensive (default)
  return [...pool].sort((a, b) => (b.blended_usd_per_million ?? -1) - (a.blended_usd_per_million ?? -1))[0];
}

// 纯函数：从给定 catalog 算出 slug 列表（fastest 由 Task 1.2 覆盖）。
export function resolvePresetModelsFromCatalog(def: PresetDef, catalog: OpenRouterModelOut[]): string[] {
  const rows = chatRows(catalog);
  const p = def.params ?? {};
  switch (def.resolver_kind) {
    case 'manual':
      return p.manual_models ?? [];
    case 'top_flagship':
    case 'chinese_flagship': {
      const authors = p.authors ?? [];
      const out: string[] = [];
      for (const a of authors) {
        const f = flagshipForAuthor(rows.filter((m) => m.provider === a || providerMatchesAuthor(m, a)), p.flagship, p.series);
        if (f) out.push(f.slug);
      }
      return out;
    }
    case 'latest_per_vendor': {
      const byVendor = new Map<string, OpenRouterModelOut>();
      for (const m of rows) {
        const cur = byVendor.get(m.provider);
        if (!cur || (m.release_date ?? '') > (cur.release_date ?? '')) byVendor.set(m.provider, m);
      }
      return [...byVendor.values()]
        .sort((a, b) => (b.release_date ?? '').localeCompare(a.release_date ?? ''))
        .slice(0, p.count ?? 8)
        .map((m) => m.slug);
    }
    case 'most_popular': {
      return rows
        .filter((m) => ratingOf(m) != null)
        .sort((a, b) => (ratingOf(b) ?? 0) - (ratingOf(a) ?? 0))
        .slice(0, p.count ?? 5)
        .map((m) => m.slug);
    }
    case 'fastest':
      return []; // Task 1.2 覆盖（需 endpoints 吞吐）
  }
}

// native 行的 provider 是 'openai'/'anthropic'/'google-ai-studio'；OpenRouter 行
// provider 是厂商段（'openai'/'deepseek'/...）。author 匹配两者。
function providerMatchesAuthor(m: OpenRouterModelOut, author: string): boolean {
  if (author === 'google') return m.provider === 'google' || m.provider === 'google-ai-studio';
  return m.provider === author;
}

function enrich(slugs: string[], catalog: OpenRouterModelOut[]): ResolvedPreset['models'] {
  const bySlug = new Map(catalog.map((m) => [m.slug, m]));
  return slugs.flatMap((s) => {
    const m = bySlug.get(s);
    return m ? [{ slug: m.slug, display_name: m.display_name, provider: m.provider }] : [];
  });
}

// 读 DB 定义 + 算 + KV 缓存。Task 1.2 会在这里接入 fastest 的 endpoints 分支。
export async function resolveModelPreset(env: Env, def: PresetDef): Promise<ResolvedPreset> {
  const cacheKey = PRESET_CACHE_PREFIX + def.slug;
  const cached = await env.MEMORY.get<ResolvedPreset>(cacheKey, 'json').catch(() => null);
  if (cached) return cached;
  const catalog = await buildModelCatalog(await fetchLMArenaRows(env));
  const slugs = resolvePresetModelsFromCatalog(def, catalog);
  const resolved: ResolvedPreset = {
    slug: def.slug, title: def.title, description: def.description,
    default_selected: def.default_selected ?? false,
    models: enrich(slugs, catalog),
  };
  await env.MEMORY.put(cacheKey, JSON.stringify(resolved), { expirationTtl: PRESET_TTL_SEC }).catch(() => {});
  return resolved;
}
