// KV-backed cache for the conversations row that the pre-stream gate
// in POST /v1/messages reads.
//
// Security model:
//   - For user_bot / self / user_user / discuss / surf / portrait convs
//     (single-owner), the cached `user_id` IS the membership proof —
//     worker compares it against the caller's userId locally.
//   - For group convs, ownership is multi-party (conversation_participants);
//     the cached row is fine to use as routing config but membership
//     must still be verified through a separate channel. Today that
//     falls through to a Supabase RLS read on every group request —
//     groups stay on Supabase for the gate until we add a member cache.
//
// Invalidation:
//   - The worker deletes the entry after any conversations-row write so
//     the next read pulls fresh values.
//   - iOS-direct INSERT/UPDATE on conversations (via Supabase RLS) is
//     bounded by the 1h TTL on the KV entry.

import type { SupabaseClient } from './supabase';
import type { Env } from '../types';

const CONV_PREFIX = 'conv:';
const CONV_TTL_SEC = 3600;

export interface CachedConv {
  id: string;
  conversation_type: string;
  bot_id: string | null;
  user_id: string | null;
  round_count: number | null;
  current_model_slug: string | null;
  current_model_provider: string | null;
}

export async function getCachedConv(env: Env, convId: string): Promise<CachedConv | null> {
  return env.MEMORY.get<CachedConv>(CONV_PREFIX + convId, 'json');
}

export async function putCachedConv(env: Env, conv: CachedConv): Promise<void> {
  await env.MEMORY.put(CONV_PREFIX + conv.id, JSON.stringify(conv), {
    expirationTtl: CONV_TTL_SEC,
  });
}

export async function deleteCachedConv(env: Env, convId: string): Promise<void> {
  await env.MEMORY.delete(CONV_PREFIX + convId);
}

/// Single-owner conv types — the cached user_id field is the gate.
///
/// ⚠️ RLS 对齐不变量:这里的每个类型都必须满足「conversations.user_id 一定
/// 在 conversation_participants 里有对应 participant_type='user' 行」——
/// 否则 owner 本地放行(user_id === caller)会比 RLS(is_participant)更宽 =
/// 越权读。多方会话(group / temporary_group / crew / subagent)绝不能加进来;
/// 成员判定必须走 roster / RLS。护栏测试:apps/edge/tests/projection-rls-guard.test.ts。
export const SINGLE_OWNER_TYPES: ReadonlySet<string> = new Set([
  'user_bot',
  'self',
  'user_user',
  'discuss',
  'surf',
  'portrait',
]);

/// Resolve conv + check membership without hitting Supabase when the
/// cache is warm AND the conv is single-owner. For groups (and for cold
/// reads), falls through to the existing RLS-gated Supabase query;
/// success warms KV for next time.
///
/// Returns null if the conv doesn't exist or the caller has no access.
export async function resolveConv(
  env: Env,
  supaUser: SupabaseClient,
  convId: string,
  userId: string,
  waitUntil: (p: Promise<unknown>) => void,
): Promise<CachedConv | null> {
  const cached = await getCachedConv(env, convId);
  if (cached) {
    if (SINGLE_OWNER_TYPES.has(cached.conversation_type)) {
      // Local membership check — no Supabase needed.
      if (cached.user_id === userId) return cached;
      // user_id mismatch (or null) — fall through to RLS in case the
      // cached row is stale (e.g. user_id was set on the DB after KV
      // was populated by a different path).
    } else {
      // Group / unknown type — still need Supabase RLS for membership.
    }
  }

  // Miss or membership not provable locally — read with RLS so the
  // gate is authoritative. supaUser carries the user JWT.
  const { data, error } = await supaUser
    .from('conversations')
    .select('id, conversation_type, bot_id, user_id, round_count, current_model_slug, current_model_provider')
    .eq('id', convId)
    .maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const row: CachedConv = {
    id: data.id as string,
    conversation_type: data.conversation_type as string,
    bot_id: (data.bot_id ?? null) as string | null,
    user_id: (data.user_id ?? null) as string | null,
    round_count: (data.round_count ?? null) as number | null,
    current_model_slug: (data.current_model_slug ?? null) as string | null,
    current_model_provider: (data.current_model_provider ?? null) as string | null,
  };
  waitUntil(putCachedConv(env, row));
  return row;
}
