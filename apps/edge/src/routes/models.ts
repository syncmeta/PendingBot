import { Hono, type Context } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { jsonError } from '../lib/http-error';
import { gatewayBaseUrl } from '../llm/providers';
import type { AppBindings } from '../types';

// GET /v1/models — aggregated model catalog for the iOS picker. Multiple
// upstream catalogs are merged: OpenRouter's public catalog and OpenAI's
// native catalog (reached through the AI Gateway). Nothing here is
// hand-maintained — model ids, names and pricing all come straight from
// upstream and are cached briefly.
//
// blended_usd_per_million is a 7:2:1 (cache_hit/input/output) reference
// price derived from OpenRouter's own per-model pricing, so the picker
// can show "≈$X / 1M" next to each row. OpenAI's catalog exposes no
// pricing of its own, so its rows borrow OpenRouter's pricing via the
// `openai/<slug>` ↔ `<slug>` mapping.

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
  /// section per source: 'openrouter' is the default catalog, 'openai'
  /// is OpenAI's own model list reached natively through the AI Gateway.
  source: 'openrouter' | 'openai';
  /// bots.model_provider value to store when this row is picked. NULL for
  /// the OpenRouter catalog (default routing); 'openai' for the native one.
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

// Isolate-local cache of OpenAI's raw /models id list. We only cache the
// ids — display name / pricing / context / vision are enriched on each
// request from the OpenRouter catalog, so the rows always reflect the
// latest OpenRouter metadata without a second AI Gateway hop.
let nativeIdsCache: { at: number; ids: string[] } | null = null;
const NATIVE_CATALOG_TTL_MS = 10 * 60_000;

// Fetch OpenAI's native /models id list through the AI Gateway openai
// passthrough. Returns the raw list of model ids; enrichment happens in
// the route handler against the OpenRouter catalog.
async function loadOpenAINativeIds(c: Context<AppBindings>): Promise<string[]> {
  const now = Date.now();
  if (nativeIdsCache && now - nativeIdsCache.at < NATIVE_CATALOG_TTL_MS) {
    return nativeIdsCache.ids;
  }
  const token = c.env.CF_AIG_RUN_TOKEN;
  if (!token) return [];
  let baseURL: string;
  try {
    baseURL = gatewayBaseUrl(c.env, 'openai');
  } catch {
    return [];
  }
  // Unified Billing can't authenticate OpenAI's /models (no provider key
  // attached), so we ride a BYOK alias just for the catalog fetch. The
  // alias is set via env; without it the catalog stays empty and the
  // picker simply doesn't show the OpenAI-native section.
  const byokAlias = c.env.CF_AIG_BYOK_OPENAI_ALIAS;
  const headers: Record<string, string> = {
    'cf-aig-authorization': `Bearer ${token}`,
    Accept: 'application/json',
  };
  if (byokAlias) headers['cf-aig-byok-alias'] = byokAlias;
  try {
    const res = await fetch(`${baseURL}/models`, { headers });
    if (!res.ok) {
      console.warn('[v1/models] openai-native catalog', res.status);
      return [];
    }
    const json = (await res.json()) as { data?: Array<{ id?: string }> };
    const ids = (json.data ?? [])
      .map((m) => m.id)
      .filter((id): id is string => typeof id === 'string');
    nativeIdsCache = { at: now, ids };
    return ids;
  } catch (err) {
    console.warn('[v1/models] openai-native catalog fetch failed', err);
    return [];
  }
}

// Build the OpenAI-native section by enriching each id with metadata
// from the OpenRouter catalog (display name, pricing, context, vision).
// Slugs align one-to-one: OpenAI `gpt-4o` ↔ OpenRouter `openai/gpt-4o`.
// Ids without an OpenRouter counterpart are dropped — OpenAI's /models
// is noisy (date-pinned variants, internal previews, embeddings, TTS,
// etc.) and the picker only cares about chat-capable models the user
// can actually compare on price.
function enrichNativeOpenAI(
  ids: string[],
  orMap: Map<string, OpenRouterCatalogModel>,
): OpenRouterModelOut[] {
  const rows: OpenRouterModelOut[] = [];
  for (const id of ids) {
    const m = orMap.get(`openai/${id}`);
    if (!m) continue;
    const displayName = stripVendorPrefix(m.name) ?? prettifyTail(id);
    const inputModalities = m.architecture?.input_modalities ?? [];
    rows.push({
      slug: id,
      display_name: displayName,
      provider: 'openai',
      context_length: typeof m.context_length === 'number' ? m.context_length : null,
      supports_vision: inputModalities.includes('image'),
      blended_usd_per_million: blendedFromCatalog(m.pricing),
      source: 'openai' as const,
      model_provider: 'openai',
    });
  }
  return rows;
}

modelCatalogRoutes.get('/', async (c) => {
  const [res, nativeIds] = await Promise.all([
    fetch('https://openrouter.ai/api/v1/models'),
    loadOpenAINativeIds(c),
  ]);
  if (!res.ok) {
    const body = (await res.text()).slice(0, 300);
    console.warn('[v1/models] upstream', res.status, body);
    return jsonError(c, 502, 'upstream_error', { detail: { status: res.status } });
  }
  const json = (await res.json()) as { data?: OpenRouterCatalogModel[] };
  const catalog = json.data ?? [];
  const orMap = new Map<string, OpenRouterCatalogModel>(catalog.map((m) => [m.id, m]));
  const out: OpenRouterModelOut[] = catalog.map((m) => {
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
  // Append OpenAI's native catalog as a second source, enriched against
  // OpenRouter's catalog so display names and prices match the OpenRouter
  // rows. The picker renders it as a separate collapsible section
  // ("OpenAI（原生）").
  const nativeOpenAI = enrichNativeOpenAI(nativeIds, orMap);
  return c.json([...out, ...nativeOpenAI]);
});

function stripVendorPrefix(name?: string): string | null {
  if (!name) return null;
  const idx = name.indexOf(': ');
  return idx >= 0 ? name.slice(idx + 2) : name;
}

function prettifyTail(tail: string): string {
  return tail.replace(/[-_]/g, ' ');
}
