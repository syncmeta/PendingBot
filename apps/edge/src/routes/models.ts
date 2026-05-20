import { Hono, type Context } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { jsonError } from '../lib/http-error';
import { gatewayBaseUrl } from '../llm/providers';
import type { AppBindings } from '../types';

// GET /v1/models — aggregated model catalog for the iOS picker. Several
// upstream catalogs are merged: OpenRouter's public catalog and the
// three native catalogs reached through AI Gateway (Anthropic, Google AI
// Studio, OpenAI). Nothing here is hand-maintained — model ids, names
// and pricing all come straight from upstream and are cached briefly.
//
// blended_usd_per_million is a 7:2:1 (cache_hit/input/output) reference
// price derived from OpenRouter's own per-model pricing, so the picker
// can show "≈$X / 1M" next to each row. Native catalogs (anthropic /
// google-ai-studio / openai) don't expose pricing of their own, so each
// native row borrows the matching OpenRouter mirror's pricing via the
// `{provider}/{slug}` ↔ `{slug}` mapping.
//
// Native rows are returned BEFORE the OpenRouter rows so the iOS picker
// shows them at the top of the list. Within the native group the order
// is anthropic → google-ai-studio → openai.

export const modelCatalogRoutes = new Hono<AppBindings>();
modelCatalogRoutes.use('*', requireSession());

interface OpenRouterCatalogModel {
  id: string;
  name?: string;
  context_length?: number;
  /// OpenRouter exposes per-model `architecture.input_modalities` like
  /// ["text","image","video"]. We surface a derived boolean so the iOS
  /// vision-model picker can filter without having to know the schema.
  architecture?: {
    input_modalities?: string[];
  };
  /// Per-token USD pricing (strings). `prompt` / `completion` are the
  /// input / output rates; `input_cache_read` is the cached-input rate.
  pricing?: {
    prompt?: string;
    completion?: string;
    input_cache_read?: string;
  };
}

type CatalogSource = 'openrouter' | 'openai' | 'anthropic' | 'google-ai-studio';

interface OpenRouterModelOut {
  slug: string;
  display_name: string;
  provider: string;
  context_length: number | null;
  /// True when the model accepts image input. The vision-model picker
  /// in ConversationSettingsView filters on this.
  supports_vision: boolean;
  /// USD per 1M tokens, blended 7:2:1 (cache_hit/input/output) from the
  /// upstream catalog's own pricing. Null when no OpenRouter mirror
  /// exposes pricing for this slug.
  blended_usd_per_million: number | null;
  /// Which catalog this row came from. The picker shows one collapsible
  /// section per source. Native sources land at the top of the response;
  /// 'openrouter' is the long tail.
  source: CatalogSource;
  /// bots.model_provider value to store when this row is picked. NULL for
  /// the OpenRouter catalog (default routing); the provider slug for any
  /// native row so the LLM router knows which AI Gateway path to use.
  model_provider: string | null;
}

const BLEND_WEIGHT_CACHE_HIT = 0.7;
const BLEND_WEIGHT_INPUT = 0.2;
const BLEND_WEIGHT_OUTPUT = 0.1;

// Blended USD-per-1M-token reference price from OpenRouter's per-token
// pricing. Weighted 7:2:1 over (cache_hit, input, output). Returns null
// when prompt or completion pricing is missing/unparseable.
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

// Isolate-local cache of each native catalog's raw model id list. We
// only cache the ids — display name / pricing / context / vision are
// enriched on each request from the OpenRouter catalog, so the rows
// always reflect the latest OpenRouter metadata without a second AI
// Gateway hop per call.
interface NativeIdsCache {
  at: number;
  ids: string[];
}
const nativeIdsCache: Record<CatalogSource, NativeIdsCache | null> = {
  openrouter: null,
  openai: null,
  anthropic: null,
  'google-ai-studio': null,
};
const NATIVE_CATALOG_TTL_MS = 10 * 60_000;

// One native-catalog source. Each upstream exposes its model list at a
// different path under its AI Gateway slug; the response shape also
// differs (OpenAI/Anthropic return `{ data: [{id}, …] }`, Gemini returns
// `{ models: [{name: 'models/…'}, …] }`). The parser collapses both
// shapes onto a flat list of provider-local ids.
interface NativeSource {
  source: Exclude<CatalogSource, 'openrouter'>;
  catalogPath: string;
  byokAliasEnv:
    | 'CF_AIG_BYOK_OPENAI_ALIAS'
    | 'CF_AIG_BYOK_ANTHROPIC_ALIAS'
    | 'CF_AIG_BYOK_GOOGLE_AI_STUDIO_ALIAS';
  /// Convert the upstream catalog payload into the list of provider-local
  /// ids we care about (the picker-facing slug — no `models/` prefix).
  parseIds(json: unknown): string[];
}

const NATIVE_SOURCES: readonly NativeSource[] = [
  {
    source: 'anthropic',
    // Anthropic native /v1/models — { data: [{id, …}] }
    catalogPath: '/anthropic/v1/models',
    byokAliasEnv: 'CF_AIG_BYOK_ANTHROPIC_ALIAS',
    parseIds(json) {
      const j = json as { data?: Array<{ id?: string }> };
      return (j.data ?? [])
        .map((m) => m.id)
        .filter((id): id is string => typeof id === 'string');
    },
  },
  {
    source: 'google-ai-studio',
    // Gemini /v1beta/models — { models: [{name: 'models/gemini-…', …}] }
    catalogPath: '/google-ai-studio/v1beta/models',
    byokAliasEnv: 'CF_AIG_BYOK_GOOGLE_AI_STUDIO_ALIAS',
    parseIds(json) {
      const j = json as { models?: Array<{ name?: string; supportedGenerationMethods?: string[] }> };
      return (j.models ?? [])
        .filter((m) => {
          // Skip embeddings / TTS / image-gen variants — the picker is
          // about chat-capable models the user can compare on price.
          const methods = m.supportedGenerationMethods ?? [];
          return methods.includes('generateContent');
        })
        .map((m) => (m.name ?? '').replace(/^models\//, ''))
        .filter((id) => id.length > 0);
    },
  },
  {
    source: 'openai',
    // OpenAI native /models — { data: [{id, …}] }
    catalogPath: '/openai/models',
    byokAliasEnv: 'CF_AIG_BYOK_OPENAI_ALIAS',
    parseIds(json) {
      const j = json as { data?: Array<{ id?: string }> };
      return (j.data ?? [])
        .map((m) => m.id)
        .filter((id): id is string => typeof id === 'string');
    },
  },
];

// Fetch one native catalog through its AI Gateway slug. Returns an empty
// list when the BYOK alias env var isn't set (catalog stays empty in the
// picker, but inference can still work via Unified Billing).
async function loadNativeIds(
  c: Context<AppBindings>,
  src: NativeSource,
): Promise<string[]> {
  const now = Date.now();
  const cached = nativeIdsCache[src.source];
  if (cached && now - cached.at < NATIVE_CATALOG_TTL_MS) {
    return cached.ids;
  }
  const token = c.env.CF_AIG_RUN_TOKEN;
  if (!token) return [];
  // The catalog fetch goes through each provider's native passthrough
  // path (not /compat), so we build the URL from the gateway base for
  // a known provider slug. gatewayBaseUrl wraps the account+gateway
  // segment; we strip the trailing `/<provider>` and append our path.
  let baseURL: string;
  try {
    baseURL = gatewayBaseUrl(c.env, 'openai').replace(/\/openai$/, '');
  } catch {
    return [];
  }
  const url = `${baseURL}${src.catalogPath}`;
  const byokAlias = c.env[src.byokAliasEnv];
  const headers: Record<string, string> = {
    'cf-aig-authorization': `Bearer ${token}`,
    Accept: 'application/json',
  };
  if (byokAlias) headers['cf-aig-byok-alias'] = byokAlias;
  try {
    const res = await fetch(url, { headers });
    if (!res.ok) {
      console.warn(`[v1/models] ${src.source} catalog`, res.status);
      return [];
    }
    const json = await res.json();
    const ids = src.parseIds(json);
    nativeIdsCache[src.source] = { at: now, ids };
    return ids;
  } catch (err) {
    console.warn(`[v1/models] ${src.source} catalog fetch failed`, err);
    return [];
  }
}

// Build one native section by enriching each id with metadata from the
// OpenRouter catalog (display name, pricing, context, vision). Slugs
// align one-to-one between OpenRouter and each native:
//   OpenAI         `gpt-4o`              ↔ OpenRouter `openai/gpt-4o`
//   Anthropic      `claude-sonnet-4-5`   ↔ OpenRouter `anthropic/claude-sonnet-4-5`
//   Google Gemini  `gemini-2.5-flash`    ↔ OpenRouter `google/gemini-2.5-flash`
// Ids without an OpenRouter counterpart are dropped — the native /models
// lists are noisy (date-pinned variants, internal previews, embeddings,
// TTS, etc.) and the picker only cares about chat-capable models the
// user can actually compare on price.
function enrichNative(
  source: Exclude<CatalogSource, 'openrouter'>,
  ids: string[],
  orMap: Map<string, OpenRouterCatalogModel>,
): OpenRouterModelOut[] {
  // Native source slug → OpenRouter vendor prefix for the same model.
  // OpenAI/Anthropic happen to use the same prefix on OpenRouter
  // ('openai/' / 'anthropic/'), Google AI Studio maps to 'google/'.
  const orVendor =
    source === 'google-ai-studio'
      ? 'google'
      : source === 'anthropic'
        ? 'anthropic'
        : 'openai';
  const rows: OpenRouterModelOut[] = [];
  for (const id of ids) {
    const m = orMap.get(`${orVendor}/${id}`);
    if (!m) continue;
    const displayName = stripVendorPrefix(m.name) ?? prettifyTail(id);
    const inputModalities = m.architecture?.input_modalities ?? [];
    rows.push({
      slug: id,
      display_name: displayName,
      provider: source,
      context_length: typeof m.context_length === 'number' ? m.context_length : null,
      supports_vision: inputModalities.includes('image'),
      blended_usd_per_million: blendedFromCatalog(m.pricing),
      source,
      model_provider: source,
    });
  }
  return rows;
}

modelCatalogRoutes.get('/', async (c) => {
  const [orRes, ...nativeIdLists] = await Promise.all([
    fetch('https://openrouter.ai/api/v1/models'),
    ...NATIVE_SOURCES.map((src) => loadNativeIds(c, src)),
  ]);
  if (!orRes.ok) {
    const body = (await orRes.text()).slice(0, 300);
    console.warn('[v1/models] upstream', orRes.status, body);
    return jsonError(c, 502, 'upstream_error', { detail: { status: orRes.status } });
  }
  const json = (await orRes.json()) as { data?: OpenRouterCatalogModel[] };
  const catalog = json.data ?? [];
  const orMap = new Map<string, OpenRouterCatalogModel>(catalog.map((m) => [m.id, m]));
  const openrouterRows: OpenRouterModelOut[] = catalog.map((m) => {
    const slash = m.id.indexOf('/');
    const provider = slash > 0 ? m.id.slice(0, slash) : 'unknown';
    const tail = slash > 0 ? m.id.slice(slash + 1) : m.id;
    // OpenRouter's "name" is "Vendor: Model" — strip the vendor prefix so
    // the picker's section header isn't redundant with the row title.
    const displayName = stripVendorPrefix(m.name) ?? prettifyTail(tail);
    const inputModalities = m.architecture?.input_modalities ?? [];
    return {
      slug: m.id,
      display_name: displayName,
      provider,
      context_length: typeof m.context_length === 'number' ? m.context_length : null,
      supports_vision: inputModalities.includes('image'),
      blended_usd_per_million: blendedFromCatalog(m.pricing),
      source: 'openrouter' as const,
      model_provider: null,
    };
  });
  // Build each native section in NATIVE_SOURCES order (anthropic →
  // google-ai-studio → openai) and concatenate them ahead of the
  // OpenRouter long tail. iOS renders these as sticky-top sections so
  // the user sees "原生 Anthropic" / "原生 Gemini" / "原生 OpenAI"
  // before the OpenRouter catalog.
  const nativeRows: OpenRouterModelOut[] = NATIVE_SOURCES.flatMap((src, i) =>
    enrichNative(src.source, nativeIdLists[i] ?? [], orMap),
  );
  return c.json([...nativeRows, ...openrouterRows]);
});

function stripVendorPrefix(name?: string): string | null {
  if (!name) return null;
  const idx = name.indexOf(': ');
  return idx >= 0 ? name.slice(idx + 2) : name;
}

function prettifyTail(tail: string): string {
  return tail.replace(/[-_]/g, ' ');
}
