// KV-backed cache for the three bot-reply system-prompt fragments that
// the runChatTurn Promise.all currently round-trips to Supabase for:
//   - chatMemo  (skills row scoped to bot_id + conversation_id, user null)
//   - botNote   (skills row scoped to bot_id + user_id)
//   - subscribed skills (skill_subscriptions × skills)
//
// chatMemo + botNote are written exclusively by worker-side refreshers
// (memory.ts refreshChatMemo / refreshBotNote), so write-through KV is
// straightforward. Subscribed skills are mutated by iOS-direct DB calls
// — that side has no worker hook, so we lean on a 5-minute TTL for
// staleness bounds.

import type { SupabaseClient } from './supabase';
import type { Env } from '../types';

const MEMO_PREFIX = 'memo:';
const NOTE_PREFIX = 'botnote:';
const SUBS_PREFIX = 'subs:';

// chatMemo / botNote rarely churn — long TTL is fine.
const PERSONA_TTL_SEC = 60 * 60; // 1 h

// Subscriptions can be toggled by the user via iOS-direct SQL; bound
// staleness so a toggle visible to the user kicks in within minutes.
const SUBS_TTL_SEC = 5 * 60; // 5 min

export interface CachedSkill {
  name: string;
  description: string;
  body: string;
  allowedTools: string[];
}

// ─────────────────────────────────────────────────────────────────────
// chatMemo (per bot × conv)
// ─────────────────────────────────────────────────────────────────────

export async function getCachedChatMemo(
  env: Env,
  botId: string,
  conversationId: string,
): Promise<string | null> {
  return env.MEMORY.get(`${MEMO_PREFIX}${botId}:${conversationId}`, 'text');
}

export async function putCachedChatMemo(
  env: Env,
  botId: string,
  conversationId: string,
  body: string,
): Promise<void> {
  await env.MEMORY.put(`${MEMO_PREFIX}${botId}:${conversationId}`, body, {
    expirationTtl: PERSONA_TTL_SEC,
  });
}

export async function deleteCachedChatMemo(
  env: Env,
  botId: string,
  conversationId: string,
): Promise<void> {
  await env.MEMORY.delete(`${MEMO_PREFIX}${botId}:${conversationId}`);
}

/// Read chat memo via KV, falling back to Supabase on miss.
export async function resolveChatMemo(
  env: Env,
  supa: SupabaseClient,
  botId: string,
  conversationId: string,
  waitUntil: (p: Promise<unknown>) => void,
): Promise<string | null> {
  const cached = await getCachedChatMemo(env, botId, conversationId);
  if (cached !== null) return cached.length > 0 ? cached : null;
  const { data } = await supa
    .from('skills')
    .select('body_md')
    .eq('bot_id', botId)
    .eq('conversation_id', conversationId)
    .is('user_id', null)
    .maybeSingle();
  const body = (data?.body_md as string | undefined)?.trim() || null;
  // Cache positive AND negative results — the bot-reply path queries
  // every turn, so a "no memo" answer is just as important to cache as
  // a hit. Store empty string for the no-memo case.
  waitUntil(putCachedChatMemo(env, botId, conversationId, body ?? ''));
  return body;
}

// ─────────────────────────────────────────────────────────────────────
// botNote (per bot × user)
// ─────────────────────────────────────────────────────────────────────

export async function getCachedBotNote(
  env: Env,
  botId: string,
  userId: string,
): Promise<string | null> {
  return env.MEMORY.get(`${NOTE_PREFIX}${botId}:${userId}`, 'text');
}

export async function putCachedBotNote(
  env: Env,
  botId: string,
  userId: string,
  body: string,
): Promise<void> {
  await env.MEMORY.put(`${NOTE_PREFIX}${botId}:${userId}`, body, {
    expirationTtl: PERSONA_TTL_SEC,
  });
}

export async function deleteCachedBotNote(
  env: Env,
  botId: string,
  userId: string,
): Promise<void> {
  await env.MEMORY.delete(`${NOTE_PREFIX}${botId}:${userId}`);
}

/// Read bot's private user-note via KV, falling back to Supabase.
export async function resolveBotNote(
  env: Env,
  supa: SupabaseClient,
  botId: string,
  userId: string,
  waitUntil: (p: Promise<unknown>) => void,
): Promise<string | null> {
  const cached = await getCachedBotNote(env, botId, userId);
  if (cached !== null) return cached.length > 0 ? cached : null;
  const { data } = await supa
    .from('skills')
    .select('body_md')
    .eq('bot_id', botId)
    .eq('user_id', userId)
    .maybeSingle();
  const body = (data?.body_md as string | undefined) ?? null;
  waitUntil(putCachedBotNote(env, botId, userId, body ?? ''));
  return body;
}

// ─────────────────────────────────────────────────────────────────────
// Subscribed skills (per user × conv — joins global subs + conv subs)
// ─────────────────────────────────────────────────────────────────────

interface CachedSubsBundle {
  skills: CachedSkill[];
  /// Aggregated allowed_tools across all subscribed skills (used to
  /// gate sensitive tools like execute_code on the turn's tool list).
  allowedTools: string[];
}

export async function getCachedSubscriptions(
  env: Env,
  userId: string,
  conversationId: string,
): Promise<CachedSubsBundle | null> {
  return env.MEMORY.get<CachedSubsBundle>(
    `${SUBS_PREFIX}${userId}:${conversationId}`,
    'json',
  );
}

export async function putCachedSubscriptions(
  env: Env,
  userId: string,
  conversationId: string,
  bundle: CachedSubsBundle,
): Promise<void> {
  await env.MEMORY.put(
    `${SUBS_PREFIX}${userId}:${conversationId}`,
    JSON.stringify(bundle),
    { expirationTtl: SUBS_TTL_SEC },
  );
}

/// Read the user's subscribed skills (global + this conv) via KV with
/// a 5 min TTL fallback to Supabase. The shape mirrors what the
/// bot-reply caller currently builds from skill_subscriptions joined
/// with skills.
export async function resolveSubscriptions(
  env: Env,
  supa: SupabaseClient,
  userId: string,
  conversationId: string,
  waitUntil: (p: Promise<unknown>) => void,
): Promise<CachedSubsBundle> {
  const cached = await getCachedSubscriptions(env, userId, conversationId);
  if (cached) return cached;
  const { data } = await supa
    .from('skill_subscriptions')
    .select('skills(frontmatter, body_md)')
    .eq('user_id', userId)
    .or(`conversation_id.eq.${conversationId},conversation_id.is.null`);

  type SkillRow = {
    frontmatter: {
      name?: string;
      description?: string;
      allowed_tools?: unknown;
    };
    body_md: string;
  };
  const skills: CachedSkill[] = [];
  const allowedToolSet = new Set<string>();
  for (const row of data ?? []) {
    const joined = (row as { skills: SkillRow | SkillRow[] | null }).skills;
    const arr = Array.isArray(joined) ? joined : joined ? [joined] : [];
    for (const s of arr) {
      const tools = s.frontmatter?.allowed_tools;
      const skillTools: string[] = [];
      if (Array.isArray(tools)) {
        for (const t of tools) {
          if (typeof t === 'string') {
            skillTools.push(t);
            allowedToolSet.add(t);
          }
        }
      }
      skills.push({
        name: s.frontmatter?.name ?? 'unnamed',
        description: s.frontmatter?.description ?? '',
        body: s.body_md,
        allowedTools: skillTools,
      });
    }
  }
  const bundle: CachedSubsBundle = {
    skills,
    allowedTools: Array.from(allowedToolSet),
  };
  waitUntil(putCachedSubscriptions(env, userId, conversationId, bundle));
  return bundle;
}
