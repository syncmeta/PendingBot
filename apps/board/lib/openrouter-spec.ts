// Pull OpenRouter's full per-model spec (context length, modalities,
// supported parameters) and project it onto our llm_models shape.
// Pricing comes through upstream-prices.ts; this module is the
// non-pricing half of the same catalog.
//
// We treat OpenRouter as authoritative for these fields and overwrite
// on sync — admin doesn't get a "merge" choice. The opt-in is per-row
// (only models with openrouter_canonical_slug set are sync targets), so
// hand-curated rows that intentionally diverge from OR stay
// un-overwritten by leaving the slug column empty.

export interface OpenRouterSpec {
  id: string;
  name: string;
  description: string;
  contextLength: number | null;
  maxCompletionTokens: number | null;
  inputModalities: string[];
  outputModalities: string[];
  supportedParameters: string[];
  capabilities: Record<string, boolean>;
  hasInputCachePricing: boolean;
}

interface OpenRouterCatalogModel {
  id: string;
  name?: string;
  description?: string;
  context_length?: number;
  architecture?: {
    input_modalities?: string[];
    output_modalities?: string[];
  };
  pricing?: {
    input_cache_read?: string;
  };
  top_provider?: {
    context_length?: number;
    max_completion_tokens?: number;
  };
  supported_parameters?: string[];
}

let specCache: { at: number; map: Map<string, OpenRouterSpec> } | null = null;
const TTL_MS = 5 * 60_000;

export async function fetchOpenRouterSpecs(): Promise<Map<string, OpenRouterSpec>> {
  const now = Date.now();
  if (specCache && now - specCache.at < TTL_MS) return specCache.map;
  const res = await fetch('https://openrouter.ai/api/v1/models', {
    headers: { Accept: 'application/json' },
  });
  if (!res.ok) {
    throw new Error(
      `openrouter /v1/models ${res.status}: ${(await res.text()).slice(0, 300)}`,
    );
  }
  const json = (await res.json()) as { data?: OpenRouterCatalogModel[] };
  const map = new Map<string, OpenRouterSpec>();
  for (const m of json.data ?? []) {
    if (!m.id) continue;
    const inputModalities = m.architecture?.input_modalities ?? [];
    const outputModalities = m.architecture?.output_modalities ?? [];
    const supportedParameters = m.supported_parameters ?? [];
    const hasInputCachePricing = !!m.pricing?.input_cache_read;
    map.set(m.id, {
      id: m.id,
      name: m.name ?? m.id,
      description: m.description ?? '',
      contextLength:
        typeof m.top_provider?.context_length === 'number'
          ? m.top_provider.context_length
          : typeof m.context_length === 'number'
            ? m.context_length
            : null,
      maxCompletionTokens:
        typeof m.top_provider?.max_completion_tokens === 'number'
          ? m.top_provider.max_completion_tokens
          : null,
      inputModalities,
      outputModalities,
      supportedParameters,
      hasInputCachePricing,
      capabilities: deriveCapabilities({
        inputModalities,
        supportedParameters,
        hasInputCachePricing,
      }),
    });
  }
  specCache = { at: now, map };
  return map;
}

// Project OpenRouter's surface area onto our capabilities jsonb. The
// keys here match what llm_models.capabilities uses elsewhere in the
// codebase (router.ts, model form). Anything not derivable from the
// OpenRouter response stays unset rather than guessed.
function deriveCapabilities(s: {
  inputModalities: string[];
  supportedParameters: string[];
  hasInputCachePricing: boolean;
}): Record<string, boolean> {
  return {
    vision: s.inputModalities.includes('image'),
    tool_use: s.supportedParameters.includes('tools'),
    // OR doesn't surface a flag for prompt-cache support; presence of
    // an input_cache_read price row is the only reliable signal.
    prompt_cache: s.hasInputCachePricing,
    reasoning: s.supportedParameters.includes('reasoning'),
    json_mode:
      s.supportedParameters.includes('response_format') ||
      s.supportedParameters.includes('structured_outputs'),
  };
}

export function _resetOpenRouterSpecCache(): void {
  specCache = null;
}
