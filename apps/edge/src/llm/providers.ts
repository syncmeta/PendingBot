import type { Env } from '../types';

// Static provider catalog. Every LLM call goes through one Cloudflare AI
// Gateway; the provider is just a path segment on the gateway URL. Two
// providers exist: `openrouter` (default, Chat Completions dialect) and
// `openai` (native, Responses API dialect). There is no DB-backed
// provider / alias / model table — model metadata is pulled live from the
// upstream catalogs (see routes/models.ts) and per-request cost comes
// from the AI Gateway logs (see lib/ai-gateway.ts). The only thing this
// side owns is the global markup, stored in billing_config.

export type ProviderApiStyle = 'chat' | 'responses';
export type ProviderSlug = 'openrouter' | 'openai';

const API_STYLE: Record<ProviderSlug, ProviderApiStyle> = {
  openrouter: 'chat',
  openai: 'responses',
};

// Resolve a caller-supplied provider hint (bots.model_provider, a manual
// pin, …) to a known provider. `openai` selects the native Responses
// route; anything else — null, 'openrouter', or an unknown string —
// falls to the default OpenRouter passthrough.
export function resolveProviderSlug(hint?: string | null): ProviderSlug {
  return hint === 'openai' ? 'openai' : 'openrouter';
}

export function providerApiStyle(slug: ProviderSlug): ProviderApiStyle {
  return API_STYLE[slug];
}

// AI Gateway inference endpoint for a provider:
//   https://gateway.ai.cloudflare.com/v1/{account}/{gateway}/{provider}
export function gatewayBaseUrl(env: Env, slug: ProviderSlug): string {
  const account = env.CF_ACCOUNT_ID;
  const gateway = env.CF_AIG_GATEWAY;
  if (!account || !gateway) {
    throw new Error(
      'CF_ACCOUNT_ID / CF_AIG_GATEWAY not bound — cannot build the AI ' +
        'Gateway endpoint',
    );
  }
  return `https://gateway.ai.cloudflare.com/v1/${account}/${gateway}/${slug}`;
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
