import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';

// Pull the OpenRouter model catalog and upsert into pendingbot.model_pricing.
// We only persist the fields we use for cost accounting; OpenRouter's full
// blob is logged in metadata for forensic debugging.
//
// Pricing is per-token in USD strings ('0.000003'); we keep them as numerics
// to make column math obvious downstream.

interface OpenRouterModel {
  id: string; // "anthropic/claude-haiku-4-5"
  pricing?: {
    prompt?: string;
    completion?: string;
    request?: string;
    image?: string;
    web_search?: string;
    internal_reasoning?: string;
    input_cache_read?: string;
    input_cache_write?: string;
  };
  context_length?: number;
}

export async function syncModelPricing(env: Env): Promise<void> {
  // OpenRouter's model catalog is a public endpoint — no auth header.
  const res = await fetch('https://openrouter.ai/api/v1/models');
  if (!res.ok) {
    throw new Error(`openrouter models ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  const json = (await res.json()) as { data?: OpenRouterModel[] };
  const models = json.data ?? [];

  const supa = serviceClient(env);
  const now = new Date().toISOString();
  // Drop models without both input + output prices — model_pricing schema
  // requires them NOT NULL and missing prices typically mean a placeholder
  // row from OpenRouter we can't bill against anyway.
  const rows = models
    .map((m) => {
      const input = parseNum(m.pricing?.prompt);
      const output = parseNum(m.pricing?.completion);
      if (input === null || output === null) return null;
      return {
        model_id: m.id,
        input_price: input,
        cached_input_price: parseNum(m.pricing?.input_cache_read),
        output_price: output,
        currency: 'USD',
        updated_at: now,
      };
    })
    .filter((r): r is NonNullable<typeof r> => r !== null);
  if (rows.length === 0) return;

  // Chunk to keep request body small.
  const CHUNK = 100;
  for (let i = 0; i < rows.length; i += CHUNK) {
    const slice = rows.slice(i, i + CHUNK);
    const { error } = await supa
      .from('model_pricing')
      .upsert(slice, { onConflict: 'model_id' });
    if (error) {
      console.warn('[cron/model-pricing] upsert chunk failed', error);
    }
  }
  console.log('[cron/model-pricing] synced', rows.length, 'models');
}

function parseNum(s?: string): number | null {
  if (!s) return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}
