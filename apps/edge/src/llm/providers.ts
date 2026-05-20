import type { Env } from '../types';

// Static provider catalog. Every LLM call goes through one Cloudflare AI
// Gateway; the provider is a path segment on the gateway URL. Providers:
//   `openrouter`        — OpenRouter passthrough, Chat Completions dialect
//   `openai`            — OpenAI native, Responses API dialect
//   `anthropic`         — Anthropic native, Chat Completions via /compat
//   `google-ai-studio`  — Gemini native, Chat Completions via /compat
//
// Anthropic and Gemini share AI Gateway's /compat/chat/completions
// endpoint: the OpenAI SDK speaks plain Chat Completions and the model
// field carries the provider prefix (e.g. `anthropic/claude-sonnet-4-5`).
// That keeps the streaming merge loop in bot-reply identical across all
// four providers while still letting us tag the gateway log by upstream.
//
// There is no DB-backed provider / alias / model table — model metadata
// is pulled live from the upstream catalogs (see routes/models.ts) and
// per-request cost comes from the AI Gateway logs (see lib/ai-gateway.ts).
// The only thing this side owns is the global markup, stored in
// billing_config.

export type ProviderApiStyle = 'chat' | 'responses';
export type ProviderSlug =
  | 'openrouter'
  | 'openai'
  | 'anthropic'
  | 'google-ai-studio';

const API_STYLE: Record<ProviderSlug, ProviderApiStyle> = {
  openrouter: 'chat',
  openai: 'responses',
  anthropic: 'chat',
  'google-ai-studio': 'chat',
};

// Path segment on the AI Gateway URL. `openai` and `openrouter` get
// their own provider passthrough paths; `anthropic` and `google-ai-studio`
// both ride the cross-provider /compat path with the model field
// prefixed (modelToCall keeps the `{provider}/{slug}` form for those).
const GATEWAY_PATH: Record<ProviderSlug, string> = {
  openrouter: 'openrouter',
  openai: 'openai',
  anthropic: 'compat',
  'google-ai-studio': 'compat',
};

const VALID_SLUGS = new Set<string>(Object.keys(API_STYLE));

// Resolve a caller-supplied provider hint (bots.model_provider, a manual
// pin, …) to a known provider. Recognised values map 1:1; anything else
// — null, 'openrouter', or an unknown string — falls to the default
// OpenRouter passthrough.
export function resolveProviderSlug(hint?: string | null): ProviderSlug {
  return hint && VALID_SLUGS.has(hint) ? (hint as ProviderSlug) : 'openrouter';
}

export function providerApiStyle(slug: ProviderSlug): ProviderApiStyle {
  return API_STYLE[slug];
}

// AI Gateway inference endpoint for a provider:
//   https://gateway.ai.cloudflare.com/v1/{account}/{gateway}/{path}
// where {path} is the provider passthrough slug for openai/openrouter
// and the cross-provider /compat path for anthropic/google-ai-studio.
export function gatewayBaseUrl(env: Env, slug: ProviderSlug): string {
  const account = env.CF_ACCOUNT_ID;
  const gateway = env.CF_AIG_GATEWAY;
  if (!account || !gateway) {
    throw new Error(
      'CF_ACCOUNT_ID / CF_AIG_GATEWAY not bound — cannot build the AI ' +
        'Gateway endpoint',
    );
  }
  return `https://gateway.ai.cloudflare.com/v1/${account}/${gateway}/${GATEWAY_PATH[slug]}`;
}

// Compose the model id to send upstream. The /compat endpoint requires
// the model field to carry the provider prefix (e.g. `anthropic/claude-sonnet-4-5`,
// `google-ai-studio/gemini-2.5-flash`); openai/openrouter use the bare
// slug as-is. We accept either form on input — if a caller passes the
// already-prefixed form, we strip-and-reapply to avoid double-prefixing.
export function modelForUpstream(slug: ProviderSlug, modelSlug: string): string {
  if (slug === 'openai' || slug === 'openrouter') return modelSlug;
  const expectedPrefix = `${slug}/`;
  return modelSlug.startsWith(expectedPrefix)
    ? modelSlug
    : `${expectedPrefix}${modelSlug}`;
}

// Realtime (voice) per-1M-token pricing. OpenAI Realtime is a direct
// iOS↔OpenAI WebRTC/WebSocket session that never flows through the AI
// Gateway, so there is no gateway log to bill from — voice cost is
// computed from this table × the token counts the meter reports. OpenAI's
// /models API exposes no pricing, so these are maintained by hand; retune
// when OpenAI changes Realtime pricing.
export interface RealtimePrice {
  inputPrice: number;
  cachedInputPrice: number;
  outputPrice: number;
  audioInputPrice: number;
  audioOutputPrice: number;
}

export const REALTIME_PRICING: Record<string, RealtimePrice> = {
  'gpt-realtime-2': {
    inputPrice: 4,
    cachedInputPrice: 0.4,
    outputPrice: 24,
    audioInputPrice: 32,
    audioOutputPrice: 64,
  },
  'gpt-realtime-mini-2025-12-15': {
    inputPrice: 0.6,
    cachedInputPrice: 0.3,
    outputPrice: 2.4,
    audioInputPrice: 10,
    audioOutputPrice: 20,
  },
};
