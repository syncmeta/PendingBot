import { Hono, type Context } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { jsonError } from '../lib/http-error';
import { gatewayBaseUrl } from '../llm/providers';
import type { AppBindings } from '../types';

// GET /v1/openrouter/models — proxy the upstream model catalogs, reshaped
// for the iOS model picker. Two sources are merged: OpenRouter's public
// catalog and OpenAI's native catalog (reached through the AI Gateway).
// Nothing here is hand-maintained — the catalog is fetched live and
// cached; model ids, names and pricing all come straight from upstream.
//
// blended_usd_per_million is a 7:2:1 (cache_hit/input/output) reference
// price derived from OpenRouter's own per-model pricing, so the picker
// can show "≈$X / 1M" next to each row. OpenAI's catalog exposes no
// pricing, so its rows carry a null price.

export const openrouterRoutes = new Hono<AppBindings>();
openrouterRoutes.use('*', requireSession());

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
  /// upstream catalog's own pricing. Null when the source exposes no
  /// pricing (OpenAI's native catalog).
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

// Isolate-local cache of OpenAI's native catalog. Purely a cache — it
// auto-expires and re-fetches from OpenAI's own /models; nothing here is
// hand-maintained. Keeps the picker snappy without a per-open round-trip.
let nativeCatalogCache: { at: number; rows: OpenRouterModelOut[] } | null = null;
const NATIVE_CATALOG_TTL_MS = 10 * 60_000;

// OpenAI's native catalog, reached through the AI Gateway openai
// passthrough. No pricing is attached — OpenAI's /models API exposes
// none, so the picker shows these without a cost figure.
async function loadOpenAINativeCatalog(
  c: Context<AppBindings>,
): Promise<OpenRouterModelOut[]> {
  const now = Date.now();
  if (nativeCatalogCache && now - nativeCatalogCache.at < NATIVE_CATALOG_TTL_MS) {
    return nativeCatalogCache.rows;
  }
  const token = c.env.CF_AIG_RUN_TOKEN;
  if (!token) return [];
  let baseURL: string;
  try {
    baseURL = gatewayBaseUrl(c.env, 'openai');
  } catch {
    return [];
  }
  try {
    const res = await fetch(`${baseURL}/models`, {
      headers: {
        'cf-aig-authorization': `Bearer ${token}`,
        Accept: 'application/json',
      },
    });
    if (!res.ok) {
      console.warn('[openrouter/models] openai-native catalog', res.status);
      return [];
    }
    const json = (await res.json()) as { data?: Array<{ id?: string }> };
    const rows: OpenRouterModelOut[] = (json.data ?? [])
      .map((m) => m.id)
      .filter((id): id is string => typeof id === 'string' && id.startsWith('gpt-'))
      .map((id) => ({
        slug: id,
        display_name: prettifyTail(id),
        provider: 'openai',
        context_length: null,
        supports_vision: false,
        blended_usd_per_million: null,
        source: 'openai' as const,
        model_provider: 'openai',
      }));
    nativeCatalogCache = { at: now, rows };
    return rows;
  } catch (err) {
    console.warn('[openrouter/models] openai-native catalog fetch failed', err);
    return [];
  }
}

openrouterRoutes.get('/models', async (c) => {
  const [res, nativeOpenAI] = await Promise.all([
    fetch('https://openrouter.ai/api/v1/models'),
    loadOpenAINativeCatalog(c),
  ]);
  if (!res.ok) {
    const body = (await res.text()).slice(0, 300);
    console.warn('[openrouter/models] upstream', res.status, body);
    return jsonError(c, 502, 'upstream_error', { detail: { status: res.status } });
  }
  const json = (await res.json()) as { data?: OpenRouterCatalogModel[] };
  const out: OpenRouterModelOut[] = (json.data ?? []).map((m) => {
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
  // Append OpenAI's native catalog as a second source. The picker renders
  // it as a separate collapsible section ("OpenAI（原生）").
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
