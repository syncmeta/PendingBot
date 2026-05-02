import OpenAI from 'openai';
import type { Env } from '../types';

// OpenAI SDK pointed at OpenRouter. One client per request — the SDK is
// stateless aside from the api key, so the cost is just object alloc.
//
// We don't pin a default model here; the model is per-bot (bots.model_id)
// and selected at call time. OpenRouter routes to the upstream provider.
export function openrouterClient(env: Env): OpenAI {
  return new OpenAI({
    apiKey: env.OPENROUTER_API_KEY,
    baseURL: 'https://openrouter.ai/api/v1',
    defaultHeaders: {
      // Optional but recommended by OpenRouter for billing analytics.
      'HTTP-Referer': 'https://pendingname.com',
      'X-Title': 'PendingBot',
    },
  });
}
