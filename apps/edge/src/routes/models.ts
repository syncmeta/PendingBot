import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';

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

export const modelCatalogRoutes = new Hono<AppBindings>();
modelCatalogRoutes.use('*', requireSession());

interface OpenRouterCatalogModel {
  id: string;
  name?: string;
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

interface OpenRouterModelOut {
  slug: string;
  display_name: string;
  provider: string;
  context_length: number | null;
  supports_vision: boolean;
  blended_usd_per_million: number | null;
  /// Which catalog this row came from. The picker shows one collapsible
  /// section per source; native sources lead the response.
  source: CatalogSource;
  /// bots.model_provider value stored when this row is picked. NULL for
  /// OpenRouter rows (default routing); the provider slug for native rows
  /// so the LLM router knows which AI Gateway native path to use.
  model_provider: string | null;
}

const BLEND_WEIGHT_CACHE_HIT = 0.7;
const BLEND_WEIGHT_INPUT = 0.2;
const BLEND_WEIGHT_OUTPUT = 0.1;

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

function looksNonChat(tail: string): boolean {
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
      source: d.source,
      model_provider: d.source,
    });
  }
  return rows;
}

modelCatalogRoutes.get('/', async (c) => {
  const res = await fetch('https://openrouter.ai/api/v1/models');
  if (!res.ok) {
    const body = (await res.text()).slice(0, 300);
    console.warn('[v1/models] upstream', res.status, body);
    return jsonError(c, 502, 'upstream_error', { detail: { status: res.status } });
  }
  const json = (await res.json()) as { data?: OpenRouterCatalogModel[] };
  const catalog = json.data ?? [];

  const openrouterRows: OpenRouterModelOut[] = catalog.map((m) => {
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
      source: 'openrouter' as const,
      model_provider: null,
    };
  });

  // Native sections lead the response, in NATIVE_DERIVATIONS order
  // (anthropic → google-ai-studio → openai). iOS pins these three groups
  // to the top of its picker.
  const nativeRows = NATIVE_DERIVATIONS.flatMap((d) => deriveNative(d, catalog));
  return c.json([...nativeRows, ...openrouterRows]);
});
