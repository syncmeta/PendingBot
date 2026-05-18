import { Hono, type Context } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { jsonError } from '../lib/http-error';
import { serviceClient } from '../lib/supabase';
import { blendedUsdPerMillion } from '../llm/router';
import type { AppBindings } from '../types';

// GET /v1/openrouter/models — proxy OpenRouter's catalog, reshaped for the
// iOS model picker. Strip pricing detail the client doesn't render and
// keep slug/display_name/provider/context_length only. Provider strategy
// (WorldRouter primary, OpenRouter fallback) doesn't change the catalog —
// model IDs are OpenRouter-style on both sides.
//
// For models we have aliases registered for in pendingbot.llm_models /
// .llm_model_aliases, attach a blended_usd_per_million reference price
// (7:2:1 cache_hit/input/output) computed from the cheapest enabled alias,
// plus our canonical local_slug. iOS uses this to show "≈$X / 1M" next to
// the model row so users can compare cost across providers when picking.

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
}

interface OpenRouterModelOut {
  slug: string;
  display_name: string;
  provider: string;
  context_length: number | null;
  /// True when the model accepts image input. The vision-model picker
  /// in ConversationSettingsView filters on this.
  supports_vision: boolean;
  /// Our canonical llm_models.slug when we've registered this model
  /// locally — null for OpenRouter rows we don't curate. iOS prefers
  /// this when set so bot configs reference our stable slug rather
  /// than OR's id (which OR sometimes renames).
  local_slug: string | null;
  /// USD per 1M tokens, blended 7:2:1 (cache_hit/input/output) over
  /// the cheapest enabled alias on any provider. Null when no priced
  /// alias is registered yet — the row still routes via the OpenRouter
  /// passthrough fallback but at unknown cost.
  blended_usd_per_million: number | null;
  /// Which catalog this row came from. The picker shows one collapsible
  /// section per source: 'openrouter' is the default catalog, 'openai'
  /// is OpenAI's own model list reached natively through the AI Gateway.
  /// A model the bot routes via `source` → bots.model_provider.
  source: 'openrouter' | 'openai';
  /// bots.model_provider value to store when this row is picked. NULL for
  /// the OpenRouter catalog (default routing); 'openai' for the native one.
  model_provider: string | null;
}

// Isolate-local cache of OpenAI's native catalog. Purely a cache — it
// auto-expires and re-fetches from OpenAI's own /models; nothing here is
// hand-maintained. Keeps the picker snappy without a per-open round-trip.
let nativeCatalogCache: { at: number; rows: OpenRouterModelOut[] } | null = null;
const NATIVE_CATALOG_TTL_MS = 10 * 60_000;

// OpenAI's native catalog, reached through the AI Gateway openai
// passthrough. No pricing is attached — the native route bills through
// the gateway, so the picker shows these without a cost figure.
async function loadOpenAINativeCatalog(
  c: Context<AppBindings>,
): Promise<OpenRouterModelOut[]> {
  const now = Date.now();
  if (nativeCatalogCache && now - nativeCatalogCache.at < NATIVE_CATALOG_TTL_MS) {
    return nativeCatalogCache.rows;
  }
  const token = c.env.CF_AIG_RUN_TOKEN;
  if (!token) return [];
  const supa = serviceClient(c.env);
  const { data: provider } = await supa
    .from('llm_providers')
    .select('base_url')
    .eq('slug', 'openai')
    .eq('enabled', true)
    .maybeSingle();
  if (!provider?.base_url) return [];
  try {
    const res = await fetch(`${provider.base_url}/models`, {
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
        local_slug: null,
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

interface LocalAugment {
  localSlug: string;
  blendedUsdPerMillion: number | null;
}

async function loadLocalAugments(
  c: Context<AppBindings>,
): Promise<Map<string, LocalAugment>> {
  const supa = serviceClient(c.env);
  const { data, error } = await supa
    .from('llm_models')
    .select(
      `slug, openrouter_canonical_slug,
       llm_model_aliases ( enabled, input_price, cached_input_price, output_price )`,
    )
    .not('openrouter_canonical_slug', 'is', null)
    .eq('enabled', true);
  if (error) {
    console.warn('[openrouter/models] load local augments', error);
    return new Map();
  }
  const out = new Map<string, LocalAugment>();
  for (const row of data ?? []) {
    const orSlug = row.openrouter_canonical_slug;
    if (!orSlug) continue;
    let cheapest: number | null = null;
    for (const a of row.llm_model_aliases ?? []) {
      if (!a.enabled) continue;
      const blended = blendedUsdPerMillion({
        inputPrice: a.input_price as number | null,
        cachedInputPrice: a.cached_input_price as number | null,
        outputPrice: a.output_price as number | null,
      });
      if (blended == null) continue;
      if (cheapest == null || blended < cheapest) cheapest = blended;
    }
    out.set(orSlug, {
      localSlug: row.slug,
      blendedUsdPerMillion: cheapest,
    });
  }
  return out;
}

openrouterRoutes.get('/models', async (c) => {
  const [res, augments, nativeOpenAI] = await Promise.all([
    fetch('https://openrouter.ai/api/v1/models'),
    loadLocalAugments(c),
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
    const aug = augments.get(m.id) ?? null;
    return {
      slug: m.id,
      display_name: displayName,
      provider,
      context_length: typeof m.context_length === 'number' ? m.context_length : null,
      supports_vision: inputModalities.includes('image'),
      local_slug: aug?.localSlug ?? null,
      blended_usd_per_million: aug?.blendedUsdPerMillion ?? null,
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
