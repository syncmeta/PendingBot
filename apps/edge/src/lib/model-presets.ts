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
  | 'fastest' | 'most_popular' | 'manual' | 'latest_in_series';

export interface PresetParams {
  authors?: string[];
  flagship?: 'most_expensive' | 'latest' | 'latest_in_series';
  series?: string;            // glob 前缀，如 'claude-opus-'，latest_in_series 用
  count?: number;
  min_rating?: number;
  manual_models?: string[];
  // latest_in_series 用：每条产品线一个 {author, series}，各取系列内最新的
  // 非小号/非别名行。是"opus latest / gpt latest / kimi latest"的事实承载。
  lines?: { author: string; series: string }[];
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
// 候选上限。每个候选要单发一次 OpenRouter endpoints 请求拿吞吐，而 Workers 同时
// 只允许 ~6 个 outbound 连接 —— cap 太大会把冷解析排成长队。15 足够覆盖第一梯队。
const FASTEST_CANDIDATE_CAP = 15;

// Aggregate cache for the GET /v1/model-presets list response (route owns the TTL).
export const MODEL_PRESETS_LIST_CACHE_KEY = 'model_presets:list:v1';

// Invalidate preset caches after a board edit so changes take effect immediately
// rather than waiting out the TTL. slug omitted = list cache only.
export async function bustModelPresetCaches(env: Env, slug?: string): Promise<void> {
  await env.MEMORY.delete(MODEL_PRESETS_LIST_CACHE_KEY).catch(() => {});
  if (slug) await env.MEMORY.delete(PRESET_CACHE_PREFIX + slug).catch(() => {});
}

// 可上 bot 的 chat 行：排除 native-backed OpenRouter 双胞胎、非 chat、以及
// 不该当预设内容的噪声——`:free` 档、OpenRouter 自家 meta 模型（openrouter/*）、
// `-fast` 延迟路由变体。实测发现 latest_per_vendor 会捞到 openrouter/fusion、
// nvidia/*-content-safety:free 之类，故收紧。
function chatRows(catalog: OpenRouterModelOut[]): OpenRouterModelOut[] {
  return catalog.filter((m) => {
    if (m.source === 'openrouter' && isNativeBackedOpenRouterSlug(m.slug)) return false;
    if (m.slug.endsWith(':free')) return false;
    if (m.slug.startsWith('openrouter/')) return false;
    if (m.slug.endsWith('-fast')) return false;
    const slash = m.slug.indexOf('/');
    const tail = slash > 0 ? m.slug.slice(slash + 1) : m.slug;
    return !looksNonChat(tail);
  });
}

// 有真实付费定价的行（blended > 0）。free / 占位（-1）/ 无价行排除——
// "各家最新" 之类按时间排序时避免捞到免费档与 meta 模型。
function isPaid(m: OpenRouterModelOut): boolean {
  return (m.blended_usd_per_million ?? 0) > 0;
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

// "系列内最新旗舰"排除规则：滚动别名 + 小号/特化变体。关键——按 - . / 分段做
// 精确匹配,绝不裸子串(否则 'mini' 会误杀 'minimax')。新厂商若用别的小号命名,
// 在此补段;这是已知的命名-漂移尾巴(见 docs/tech-debt.md)。pro/max/ultra 不在此
// 列(它们多是旗舰档),plus 在(实测中端,如 qwen3.7-plus 对 qwen3.7-max)。
const NON_FLAGSHIP_SEGMENTS = new Set([
  'fast', 'flash', 'mini', 'nano', 'lite', 'air', 'turbo', 'distill',
  'code', 'preview', 'exp', 'plus',
  // 非 chat（与 chatRows 重叠，叠加无害）
  'image', 'audio', 'tts', 'whisper', 'embedding', 'realtime', 'moderation',
]);

export function isNonFlagshipVariant(slug: string): boolean {
  if (slug.startsWith('~')) return true; // OpenRouter 滚动别名 ~vendor/...
  if (slug.endsWith('-latest')) return true; // 滚动别名 ...-latest
  return slug.toLowerCase().split(/[-./]/).some((seg) => NON_FLAGSHIP_SEGMENTS.has(seg));
}

// 纯函数：从给定 catalog 算出 slug 列表（fastest 由 Task 1.2 覆盖）。
export function resolvePresetModelsFromCatalog(def: PresetDef, catalog: OpenRouterModelOut[]): string[] {
  const rows = chatRows(catalog);
  const p = def.params ?? {};
  switch (def.resolver_kind) {
    case 'manual':
      return p.manual_models ?? [];
    case 'latest_in_series': {
      // 每条产品线：限定 author + series 前缀，剔小号/特化/别名，取发布日最新。
      // 同日 tiebreak 取 slug 字典序小者（基础版，如 gpt-5.5 胜过 gpt-5.5-pro）。
      const out: string[] = [];
      for (const ln of p.lines ?? []) {
        const cands = rows.filter(
          (m) =>
            (m.provider === ln.author || providerMatchesAuthor(m, ln.author)) &&
            m.slug.includes(ln.series) &&
            !isNonFlagshipVariant(m.slug),
        );
        if (cands.length === 0) continue;
        const newest = [...cands].sort(
          (a, b) =>
            (b.release_date ?? '').localeCompare(a.release_date ?? '') ||
            a.slug.localeCompare(b.slug),
        )[0];
        out.push(newest.slug);
      }
      return out;
    }
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
        if (!isPaid(m)) continue; // 免费/占位档不算"最新"
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

export type ThroughputFetcher = (slug: string) => Promise<number | null>;

export async function fetchThroughput(slug: string): Promise<number | null> {
  try {
    const res = await fetch(`https://openrouter.ai/api/v1/models/${slug}/endpoints`, {
      cf: { cacheTtlByStatus: { '200-299': 3600, '400-599': 0 }, cacheEverything: true },
    });
    if (!res.ok) return null;
    const json = (await res.json()) as { data?: { endpoints?: { throughput_last_30m?: number | null }[] } };
    const eps = json.data?.endpoints ?? [];
    const vals = eps.map((e) => e.throughput_last_30m).filter((v): v is number => typeof v === 'number');
    return vals.length ? Math.max(...vals) : null;
  } catch {
    return null;
  }
}

export async function resolveFastest(
  catalog: OpenRouterModelOut[],
  params: PresetParams,
  fetcher: ThroughputFetcher = fetchThroughput,
): Promise<string[]> {
  const minRating = params.min_rating ?? 1200;
  const candidates = chatRows(catalog)
    .filter((m) => (m.blended_usd_per_million ?? 0) > 0 && (ratingOf(m) ?? 0) >= minRating)
    .slice(0, FASTEST_CANDIDATE_CAP);
  const scored = await Promise.all(
    candidates.map(async (m) => ({ slug: m.slug, tput: await fetcher(m.slug) })),
  );
  return scored
    .filter((s) => s.tput != null)
    .sort((a, b) => (b.tput ?? 0) - (a.tput ?? 0))
    .slice(0, params.count ?? 5)
    .map((s) => s.slug);
}

// Memoized catalog provider：首次 await 才 build（OpenRouter 目录 + LMArena），之后
// 复用同一 promise。多个预设共享一份目录，把冷启动的 N× build 收敛成 1×；全 KV 命中
// 时 provider 从不被调用，零额外开销。list 路由、turn 路径、cron 预热都传它。
export type CatalogProvider = () => Promise<OpenRouterModelOut[]>;

export function makeCatalogProvider(env: Env): CatalogProvider {
  let p: Promise<OpenRouterModelOut[]> | null = null;
  return () => (p ??= (async () => buildModelCatalog(await fetchLMArenaRows(env)))());
}

// 读 DB 定义 + 算 + KV 缓存。fastest 走 per-model endpoints 吞吐分支。
// catalogProvider 没传则自建（单预设解析路径）；批量解析（list/turn/cron）传共享 provider。
export async function resolveModelPreset(
  env: Env,
  def: PresetDef,
  catalogProvider?: CatalogProvider,
): Promise<ResolvedPreset> {
  const cacheKey = PRESET_CACHE_PREFIX + def.slug;
  const cached = await env.MEMORY.get<ResolvedPreset>(cacheKey, 'json').catch(() => null);
  if (cached) return cached;
  const catalog = await (catalogProvider ?? makeCatalogProvider(env))();
  const slugs = def.resolver_kind === 'fastest'
    ? await resolveFastest(catalog, def.params ?? {})
    : resolvePresetModelsFromCatalog(def, catalog);
  const resolved: ResolvedPreset = {
    slug: def.slug, title: def.title, description: def.description,
    default_selected: def.default_selected ?? false,
    models: enrich(slugs, catalog),
  };
  await env.MEMORY.put(cacheKey, JSON.stringify(resolved), { expirationTtl: PRESET_TTL_SEC }).catch(() => {});
  return resolved;
}
