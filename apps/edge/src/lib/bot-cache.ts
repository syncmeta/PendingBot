// KV-backed cache for bot metadata so the pre-stream gate in POST
// /v1/messages doesn't have to round-trip Supabase for fields that
// rarely change (model_id, output_mode, visibility, creator_id, etc.).
//
// Invalidation strategy:
//   - Worker PATCH /v1/bots/:id writes through (instant).
//   - iOS-direct INSERT / UPDATE (via Supabase RLS) is NOT visible to
//     the worker — we bound staleness with a 1 h TTL on the KV entry.
//     After expiry the next read falls back to Supabase and re-warms.
//
// 1 h was picked because bot edits are rare (model swap, voice toggle)
// and a stale model_id is harmless for the duration. Visibility/
// creator_id are effectively immutable post-create.

import type { SupabaseClient } from './supabase';
import type { Env } from '../types';

const BOT_PREFIX = 'bot:meta:';
const BOT_TTL_SEC = 3600;

export interface CachedBot {
  id: string;
  display_name: string;
  model_id: string | null;
  /// API route pin (a provider slug, e.g. 'openai'). NULL = default
  /// routing. Drives the router's preferProvider for this bot's turns.
  model_provider: string | null;
  output_mode: string;
  is_active: boolean;
  config: Record<string, unknown> | null;
  visibility: string;
  creator_id: string | null;
  /// IANA timezone the bot considers itself in. Public bots only;
  /// private bots leave it NULL (they always 1:1 with the creator and
  /// the per-turn clientTz already carries the right tz). Used by
  /// builder for system-prompt self-awareness and by group dispatch as
  /// the time-hint tz.
  tz: string | null;
}

export async function getCachedBot(env: Env, botId: string): Promise<CachedBot | null> {
  return env.MEMORY.get<CachedBot>(BOT_PREFIX + botId, 'json');
}

export async function putCachedBot(env: Env, bot: CachedBot): Promise<void> {
  await env.MEMORY.put(BOT_PREFIX + bot.id, JSON.stringify(bot), {
    expirationTtl: BOT_TTL_SEC,
  });
}

export async function deleteCachedBot(env: Env, botId: string): Promise<void> {
  await env.MEMORY.delete(BOT_PREFIX + botId);
}

/// Resolve bot metadata via KV; on miss, fall back to Supabase and
/// warm the cache. The waitUntil shim lets us populate without
/// blocking the request that triggered the miss.
export async function resolveBot(
  env: Env,
  supa: SupabaseClient,
  botId: string,
  waitUntil: (p: Promise<unknown>) => void,
): Promise<CachedBot | null> {
  const cached = await getCachedBot(env, botId);
  if (cached) return cached;
  const { data, error } = await supa
    .from('bots')
    .select('id, display_name, model_id, model_provider, output_mode, is_active, config, visibility, creator_id, tz')
    .eq('id', botId)
    .single();
  if (error || !data) return null;
  const bot: CachedBot = {
    id: data.id as string,
    display_name: (data.display_name ?? '') as string,
    model_id: (data.model_id ?? null) as string | null,
    model_provider: (data.model_provider ?? null) as string | null,
    output_mode: data.output_mode as string,
    is_active: data.is_active as boolean,
    config: (data.config ?? null) as Record<string, unknown> | null,
    visibility: data.visibility as string,
    creator_id: (data.creator_id ?? null) as string | null,
    tz: (data.tz ?? null) as string | null,
  };
  waitUntil(putCachedBot(env, bot));
  return bot;
}
