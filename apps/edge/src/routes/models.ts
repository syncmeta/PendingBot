import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { jsonError } from '../lib/http-error';
import type { AppBindings, Env } from '../types';

// GET /v1/models — aggregated model catalog for the iOS picker.
//
// Everything is derived from OpenRouter's public catalog — no provider
// API key, no BYOK, no second hop. The three native sections (Anthropic,
// Gemini, OpenAI) are SYNTHESISED from the matching OpenRouter vendor
// rows: each `anthropic/…`, `google/gemini…`, `openai/gpt…` row spawns a
// native twin whose slug is the provider-native model id (so inference
// can passthrough straight to the provider through AI Gateway on Unified
// Billing) while name / pricing / context / vision are borrowed from the
// OpenRouter row. Native rows sort to the TOP of the response so the iOS
// picker shows them before the (much larger) OpenRouter long tail.
//
// Why derive instead of fetching each provider's /models: those list
// endpoints need real provider auth, which Unified Billing doesn't cover.
// Deriving keeps the catalog key-free and always-populated; the only cost
// is a deterministic slug transform (Anthropic dots→dashes; Gemini and
// OpenAI tails pass through).
//
// blended_usd_per_million is a 7:2:1 (cache_hit/input/output) reference
// price from the OpenRouter row's own pricing — same number on the native
// twin and its OpenRouter origin so the "Nx" badge matches across rows.
//
// The OpenRouter long tail intentionally drops OpenAI / Anthropic / Google
// rows because those providers already appear as native sections. This also
// removes OpenRouter's `~vendor/...-latest` aliases, keeping both the picker
// and arena random pool from selecting the same native-backed families twice.

export const modelCatalogRoutes = new Hono<AppBindings>();
modelCatalogRoutes.use('*', requireSession());

interface OpenRouterCatalogModel {
  id: string;
  name?: string;
  created?: number;
  context_length?: number;
  architecture?: {
    input_modalities?: string[];
  };
  pricing?: {
    prompt?: string;
    completion?: string;
    input_cache_read?: string;
  };
}

type CatalogSource = 'openrouter' | 'openai' | 'anthropic' | 'google-ai-studio';

export interface OpenRouterModelOut {
  slug: string;
  display_name: string;
  provider: string;
  release_date: string | null;
  context_length: number | null;
  supports_vision: boolean;
  blended_usd_per_million: number | null;
  lmarena_license: string | null;
  lmarena_organization: string | null;
  lmarena_scores: Record<string, LMArenaScoreOut>;
  /// Which catalog this row came from. The picker shows one collapsible
  /// section per source; native sources lead the response.
  source: CatalogSource;
  /// bots.model_provider value stored when this row is picked. NULL for
  /// OpenRouter rows (default routing); the provider slug for native rows
  /// so the LLM router knows which AI Gateway native path to use.
  model_provider: string | null;
}

export interface LMArenaScoreOut {
  rating: number | null;
  rank: number | null;
  vote_count: number | null;
  category: string | null;
  leaderboard_publish_date: string | null;
}

const BLEND_WEIGHT_CACHE_HIT = 0.7;
const BLEND_WEIGHT_INPUT = 0.2;
const BLEND_WEIGHT_OUTPUT = 0.1;
const LMARENA_ROWS_URL = 'https://datasets-server.huggingface.co/rows';
const LMARENA_CACHE_KEY = 'model_catalog:lmarena:latest:v1';
const LMARENA_CACHE_TTL_SEC = 6 * 60 * 60;
const LMARENA_PAGE_SIZE = 100;
const LMARENA_MAX_ROWS_PER_SUBSET = 2_000;

export const LMARENA_SUBSETS = [
  'document',
  'document_style_control',
  'image_edit',
  'image_to_video',
  'search',
  'search_style_control',
  'text',
  'text_style_control',
  'text_to_image',
  'text_to_video',
  'video_edit',
  'vision',
  'vision_style_control',
  'webdev',
] as const;

type LMArenaSubset = typeof LMARENA_SUBSETS[number];

export interface LMArenaLeaderboardRow {
  model_name?: string;
  organization?: string;
  license?: string;
  rating?: number | null;
  rank?: number | null;
  vote_count?: number | null;
  category?: string | null;
  leaderboard_publish_date?: string | null;
}

export type LMArenaRowsBySubset = Partial<Record<LMArenaSubset, LMArenaLeaderboardRow[]>>;

function blendedFromCatalog(p: OpenRouterCatalogModel['pricing']): number | null {
  if (!p) return null;
  const prompt = Number(p.prompt);
  const completion = Number(p.completion);
  if (!Number.isFinite(prompt) || !Number.isFinite(completion)) return null;
  const cacheRaw = Number(p.input_cache_read);
  const cacheHit = Number.isFinite(cacheRaw) ? cacheRaw : prompt;
  const perToken =
    BLEND_WEIGHT_CACHE_HIT * cacheHit +
    BLEND_WEIGHT_INPUT * prompt +
    BLEND_WEIGHT_OUTPUT * completion;
  return perToken * 1_000_000;
}

function releaseDateFromCreated(created: unknown): string | null {
  if (typeof created !== 'number' || !Number.isFinite(created) || created <= 0) return null;
  const date = new Date(created * 1000);
  if (Number.isNaN(date.getTime())) return null;
  return date.toISOString().slice(0, 10);
}

// A native source: the OpenRouter vendor prefix it derives from, the
// model_provider/source slug it emits, and the slug transform from the
// OpenRouter tail to the provider-native model id used for inference.
interface NativeDerivation {
  source: Exclude<CatalogSource, 'openrouter'>;
  // OpenRouter vendor segment before the slash (id.startsWith(`${vendor}/`)).
  orVendor: string;
  // Map the OpenRouter tail (after the slash) to the provider-native id.
  nativeSlug(tail: string): string;
  // Skip OpenRouter-only routing variants / non-chat modalities that the
  // native API either doesn't expose or wouldn't accept as a chat model.
  skip(tail: string): boolean;
}

// Substrings that mark a row as non-chat (image/audio/tts/embeddings/etc.)
// or as an OpenRouter-only routing variant — dropped from native sections.
const NON_CHAT_MARKERS = [
  'image',
  'audio',
  'tts',
  'whisper',
  'embedding',
  'realtime',
  'moderation',
];

export function looksNonChat(tail: string): boolean {
  const t = tail.toLowerCase();
  return NON_CHAT_MARKERS.some((m) => t.includes(m));
}

const NATIVE_DERIVATIONS: readonly NativeDerivation[] = [
  {
    source: 'anthropic',
    orVendor: 'anthropic',
    // Anthropic native ids use dashes throughout; OpenRouter writes the
    // version with a dot (claude-sonnet-4.6 → claude-sonnet-4-6). The
    // resulting id is a valid Anthropic alias.
    nativeSlug: (tail) => tail.replace(/\./g, '-'),
    // `-fast` is an OpenRouter latency-routing variant with no native id.
    skip: (tail) => looksNonChat(tail) || tail.endsWith('-fast'),
  },
  {
    source: 'google-ai-studio',
    orVendor: 'google',
    // Gemini's native ids match the OpenRouter tail as-is
    // (google/gemini-2.5-flash → gemini-2.5-flash).
    nativeSlug: (tail) => tail,
    // Only keep the gemini line; drop image/audio variants and the
    // experimental `-customtools` previews that aren't plain chat.
    skip: (tail) =>
      !tail.startsWith('gemini') || looksNonChat(tail) || tail.includes('customtools'),
  },
  {
    source: 'openai',
    orVendor: 'openai',
    // OpenAI native ids match the OpenRouter tail (openai/gpt-5.1 →
    // gpt-5.1). Codex / oss / safeguard variants aren't on the standard
    // chat-completions surface, so drop them.
    nativeSlug: (tail) => tail,
    skip: (tail) =>
      looksNonChat(tail) ||
      tail.includes('codex') ||
      tail.includes('oss') ||
      tail.includes('safeguard'),
  },
];

const NATIVE_BACKED_OPENROUTER_VENDORS = new Set(['openai', 'anthropic', 'google']);

export function isNativeBackedOpenRouterSlug(slug: string): boolean {
  const normalized = slug.startsWith('~') ? slug.slice(1) : slug;
  const slash = normalized.indexOf('/');
  if (slash <= 0) return false;
  return NATIVE_BACKED_OPENROUTER_VENDORS.has(normalized.slice(0, slash));
}

function stripVendorPrefix(name?: string): string | null {
  if (!name) return null;
  const idx = name.indexOf(': ');
  return idx >= 0 ? name.slice(idx + 2) : name;
}

function prettifyTail(tail: string): string {
  return tail.replace(/[-_]/g, ' ');
}

// Build the native rows for one derivation by scanning the OpenRouter
// catalog for its vendor prefix and emitting a native twin per qualifying
// row. De-duped on the native slug (OpenRouter sometimes lists multiple
// dotted variants that collapse to the same dashed native id).
function deriveNative(
  d: NativeDerivation,
  catalog: OpenRouterCatalogModel[],
): OpenRouterModelOut[] {
  const seen = new Set<string>();
  const rows: OpenRouterModelOut[] = [];
  const prefix = `${d.orVendor}/`;
  for (const m of catalog) {
    if (!m.id.startsWith(prefix)) continue;
    const tail = m.id.slice(prefix.length);
    if (d.skip(tail)) continue;
    const slug = d.nativeSlug(tail);
    if (seen.has(slug)) continue;
    seen.add(slug);
    const inputModalities = m.architecture?.input_modalities ?? [];
    rows.push({
      slug,
      display_name: stripVendorPrefix(m.name) ?? prettifyTail(tail),
      provider: d.source,
      context_length: typeof m.context_length === 'number' ? m.context_length : null,
      supports_vision: inputModalities.includes('image'),
      blended_usd_per_million: blendedFromCatalog(m.pricing),
      release_date: releaseDateFromCreated(m.created),
      lmarena_license: null,
      lmarena_organization: null,
      lmarena_scores: {},
      source: d.source,
      model_provider: d.source,
    });
  }
  return rows;
}

export class CatalogUpstreamError extends Error {
  constructor(public status: number) {
    super(`OpenRouter catalog upstream returned ${status}`);
    this.name = 'CatalogUpstreamError';
  }
}

function normalizedKey(value: string | undefined): string | null {
  if (!value) return null;
  const normalized = value.toLowerCase().replace(/[^a-z0-9]+/g, '');
  return normalized || null;
}

function uniqueKeys(values: Array<string | undefined>): string[] {
  return [...new Set(values.flatMap((v) => {
    const key = normalizedKey(v);
    return key ? [key] : [];
  }))];
}

function providerAliases(provider: string): string[] {
  switch (provider) {
    case 'google-ai-studio':
      return ['google', 'google-ai-studio'];
    case 'x-ai':
      return ['x-ai', 'xai'];
    case 'moonshotai':
      return ['moonshotai', 'kimi'];
    case 'z-ai':
      return ['z-ai', 'zai', 'z ai'];
    default:
      return [provider];
  }
}

function modelTail(slug: string): string {
  const withoutAlias = slug.startsWith('~') ? slug.slice(1) : slug;
  const slash = withoutAlias.indexOf('/');
  return slash > 0 ? withoutAlias.slice(slash + 1) : withoutAlias;
}

function modelNameKeys(model: OpenRouterModelOut): string[] {
  return uniqueKeys([model.display_name, model.slug, modelTail(model.slug)]);
}

function modelCreatorKeys(model: OpenRouterModelOut): string[] {
  return uniqueKeys(providerAliases(model.provider));
}

function lmarenaScore(row: LMArenaLeaderboardRow): LMArenaScoreOut | null {
  const rating = typeof row.rating === 'number' && Number.isFinite(row.rating) ? row.rating : null;
  const rank = typeof row.rank === 'number' && Number.isFinite(row.rank) ? row.rank : null;
  if (rating == null && rank == null) return null;
  return {
    rating,
    rank,
    vote_count: typeof row.vote_count === 'number' && Number.isFinite(row.vote_count)
      ? row.vote_count
      : null,
    category: typeof row.category === 'string' ? row.category : null,
    leaderboard_publish_date: typeof row.leaderboard_publish_date === 'string'
      ? row.leaderboard_publish_date.slice(0, 10)
      : null,
  };
}

function preferLMArenaRow(next: LMArenaLeaderboardRow, current?: LMArenaLeaderboardRow): boolean {
  if (!current) return true;
  if ((next.category ?? '') === 'overall' && (current.category ?? '') !== 'overall') return true;
  if ((next.category ?? '') !== 'overall' && (current.category ?? '') === 'overall') return false;
  const nextRating = typeof next.rating === 'number' ? next.rating : -Infinity;
  const currentRating = typeof current.rating === 'number' ? current.rating : -Infinity;
  return nextRating > currentRating;
}

export function attachLMArenaScores(
  catalog: OpenRouterModelOut[],
  rowsBySubset: LMArenaRowsBySubset,
): OpenRouterModelOut[] {
  const subsetIndexes = new Map<LMArenaSubset, {
    byCreatorAndName: Map<string, LMArenaLeaderboardRow>;
    byUniqueName: Map<string, LMArenaLeaderboardRow | null>;
  }>();

  for (const subset of LMARENA_SUBSETS) {
    const rows = rowsBySubset[subset] ?? [];
    const byCreatorAndName = new Map<string, LMArenaLeaderboardRow>();
    const byUniqueName = new Map<string, LMArenaLeaderboardRow | null>();
    for (const row of rows) {
      if (!lmarenaScore(row)) continue;
      const creatorKeys = uniqueKeys([row.organization]);
      const nameKeys = uniqueKeys([row.model_name]);
      for (const creator of creatorKeys) {
        for (const name of nameKeys) {
          const key = `${creator}:${name}`;
          const existing = byCreatorAndName.get(key);
          if (preferLMArenaRow(row, existing)) byCreatorAndName.set(key, row);
        }
      }
      for (const name of nameKeys) {
        const existing = byUniqueName.get(name);
        if (existing === undefined || (existing && preferLMArenaRow(row, existing))) {
          byUniqueName.set(name, row);
        } else if (existing && normalizedKey(existing.organization) !== normalizedKey(row.organization)) {
          byUniqueName.set(name, null);
        }
      }
    }
    subsetIndexes.set(subset, { byCreatorAndName, byUniqueName });
  }

  return catalog.map((model) => {
    const lmarena_scores: Record<string, LMArenaScoreOut> = {};
    let lmarena_license = model.lmarena_license;
    let lmarena_organization = model.lmarena_organization;
    let release_date = model.release_date;

    for (const subset of LMARENA_SUBSETS) {
      const index = subsetIndexes.get(subset);
      if (!index) continue;
      let matched: LMArenaLeaderboardRow | null | undefined;
      for (const creator of modelCreatorKeys(model)) {
        for (const name of modelNameKeys(model)) {
          matched = index.byCreatorAndName.get(`${creator}:${name}`);
          if (matched) break;
        }
        if (matched) break;
      }
      if (!matched) {
        for (const name of modelNameKeys(model)) {
          matched = index.byUniqueName.get(name);
          if (matched) break;
        }
      }
      const score = matched ? lmarenaScore(matched) : null;
      if (!score) continue;
      lmarena_scores[subset] = score;
      lmarena_license ??= typeof matched?.license === 'string' ? matched.license : null;
      lmarena_organization ??= typeof matched?.organization === 'string' ? matched.organization : null;
      release_date ??= score.leaderboard_publish_date;
    }
    return { ...model, release_date, lmarena_license, lmarena_organization, lmarena_scores };
  });
}

async function fetchLMArenaSubsetRows(subset: LMArenaSubset): Promise<LMArenaLeaderboardRow[]> {
  const rows: LMArenaLeaderboardRow[] = [];
  for (let offset = 0; offset < LMARENA_MAX_ROWS_PER_SUBSET; offset += LMARENA_PAGE_SIZE) {
    const url = new URL(LMARENA_ROWS_URL);
    url.searchParams.set('dataset', 'lmarena-ai/leaderboard-dataset');
    url.searchParams.set('config', subset);
    url.searchParams.set('split', 'latest');
    url.searchParams.set('offset', String(offset));
    url.searchParams.set('length', String(LMARENA_PAGE_SIZE));
    const res = await fetch(url.toString());
    if (!res.ok) {
      const body = (await res.text()).slice(0, 300);
      console.warn('[v1/models] lmarena upstream', subset, res.status, body);
      break;
    }
    const json = (await res.json()) as { rows?: Array<{ row?: LMArenaLeaderboardRow }> };
    const page = Array.isArray(json.rows) ? json.rows.flatMap((r) => (r.row ? [r.row] : [])) : [];
    rows.push(...page);
    if (page.length < LMARENA_PAGE_SIZE) break;
  }
  return rows;
}

export async function fetchLMArenaRows(env: Env): Promise<LMArenaRowsBySubset> {
  const cached = await env.MEMORY.get<LMArenaRowsBySubset>(
    LMARENA_CACHE_KEY,
    'json',
  ).catch(() => null);
  if (cached && typeof cached === 'object') return cached;

  const rowsBySubset: LMArenaRowsBySubset = {};
  await Promise.all(LMARENA_SUBSETS.map(async (subset) => {
    try {
      rowsBySubset[subset] = await fetchLMArenaSubsetRows(subset);
    } catch (err) {
      console.warn('[v1/models] lmarena fetch failed', subset, err);
      rowsBySubset[subset] = [];
    }
  }));

  await env.MEMORY.put(LMARENA_CACHE_KEY, JSON.stringify(rowsBySubset), {
    expirationTtl: LMARENA_CACHE_TTL_SEC,
  }).catch((err) => console.warn('[v1/models] lmarena cache write failed', err));
  return rowsBySubset;
}

// Fetch + assemble the full model catalog (native twins first, then the
// OpenRouter long tail) — the array the /v1/models route returns. Factored
// out so the random-model resolver can reuse it off the route.
export async function buildModelCatalog(
  lmarenaRowsBySubset: LMArenaRowsBySubset = {},
): Promise<OpenRouterModelOut[]> {
  // CF 边缘缓存 OpenRouter 目录:成功响应缓 1h(catalog 变动稀疏,避免每次 /models
  // 都回 OpenRouter),错误不缓(下次重试)。跨 isolate 复用,比 isolate 级缓存可靠。(T2 #263)
  const res = await fetch('https://openrouter.ai/api/v1/models', {
    cf: { cacheTtlByStatus: { '200-299': 3600, '400-599': 0 }, cacheEverything: true },
  });
  if (!res.ok) {
    const body = (await res.text()).slice(0, 300);
    console.warn('[v1/models] upstream', res.status, body);
    throw new CatalogUpstreamError(res.status);
  }
  const json = (await res.json()) as { data?: OpenRouterCatalogModel[] };
  const catalog = json.data ?? [];

  const openrouterRows: OpenRouterModelOut[] = catalog
    .filter((m) => !isNativeBackedOpenRouterSlug(m.id))
    .map((m) => {
      const slash = m.id.indexOf('/');
      const provider = slash > 0 ? m.id.slice(0, slash) : 'unknown';
      const tail = slash > 0 ? m.id.slice(slash + 1) : m.id;
      const baseName = stripVendorPrefix(m.name) ?? prettifyTail(tail);
      const inputModalities = m.architecture?.input_modalities ?? [];
      return {
        slug: m.id,
        display_name: baseName,
        provider,
        context_length: typeof m.context_length === 'number' ? m.context_length : null,
        supports_vision: inputModalities.includes('image'),
        blended_usd_per_million: blendedFromCatalog(m.pricing),
        release_date: releaseDateFromCreated(m.created),
        lmarena_license: null,
        lmarena_organization: null,
        lmarena_scores: {},
        source: 'openrouter' as const,
        model_provider: null,
      };
    });

  // Native sections lead the response, in NATIVE_DERIVATIONS order
  // (anthropic → google-ai-studio → openai). iOS pins these three groups
  // to the top of its picker.
  const nativeRows = NATIVE_DERIVATIONS.flatMap((d) => deriveNative(d, catalog));
  return attachLMArenaScores([...nativeRows, ...openrouterRows], lmarenaRowsBySubset);
}

modelCatalogRoutes.get('/', async (c) => {
  try {
    const lmarenaRows = await fetchLMArenaRows(c.env);
    return c.json(await buildModelCatalog(lmarenaRows));
  } catch (err) {
    if (err instanceof CatalogUpstreamError) {
      return jsonError(c, 502, 'upstream_error', { detail: { status: err.status } });
    }
    throw err;
  }
});
