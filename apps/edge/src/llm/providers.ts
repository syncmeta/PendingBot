import type { Env } from '../types';

// Static provider catalog. Every LLM call goes through one Cloudflare AI
// Gateway; the provider is a path segment on the gateway URL. Providers:
//   `openrouter`        — OpenRouter passthrough, Chat Completions dialect
//   `openai`            — OpenAI native, Responses API dialect
//   `anthropic`         — Anthropic native, Messages API (/anthropic/v1/messages)
//   `google-ai-studio`  — Gemini native, generateContent (/google-ai-studio/v1beta/…)
//
// Anthropic and Gemini speak their OWN native protocols — NOT the OpenAI
// Chat Completions dialect and NOT the AI Gateway /compat translation
// layer (which would strip provider-specific features like Claude's
// extended thinking / prompt-cache control and Gemini's Search grounding
// / Maps). They route through their native passthrough paths on the
// gateway and authenticate with cf-aig-authorization alone (Unified
// Billing — Cloudflare-managed credentials, no BYOK key). The adapters
// in anthropic-adapter.ts / gemini-adapter.ts translate to/from the
// internal Chat-Completions-shaped message format.
//
// There is no DB-backed provider / alias / model table — model metadata
// is derived from the OpenRouter catalog (see routes/models.ts) and
// per-request cost comes from the AI Gateway logs (see lib/ai-gateway.ts).
// The only thing this side owns is the global markup, stored in
// billing_config.

export type ProviderApiStyle = 'chat' | 'responses' | 'anthropic' | 'gemini';
export type ProviderSlug =
  | 'openrouter'
  | 'openai'
  | 'anthropic'
  | 'google-ai-studio';

const API_STYLE: Record<ProviderSlug, ProviderApiStyle> = {
  openrouter: 'chat',
  openai: 'responses',
  anthropic: 'anthropic',
  'google-ai-studio': 'gemini',
};

// Path segment on the AI Gateway URL. Each provider rides its own native
// passthrough path; the adapter appends the provider-specific tail
// (Anthropic `/v1/messages`, Gemini `/v1beta/models/{model}:…`).
const GATEWAY_PATH: Record<ProviderSlug, string> = {
  openrouter: 'openrouter',
  openai: 'openai',
  anthropic: 'anthropic',
  'google-ai-studio': 'google-ai-studio',
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
// where {path} is the provider's native passthrough segment.
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
