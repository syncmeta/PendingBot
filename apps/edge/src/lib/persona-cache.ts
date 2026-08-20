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
import type { ProviderSlug } from '../llm/providers';

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
//
// Two-tier KV to make popular skills cheap when many users subscribe:
//   subs:<userId>:<conversationId>   small refs list ({id, updated_at}) + aggregated allowed_tools
//   skill:<skill_id>:<updated_at>    shared body+frontmatter, reused across every subscriber
// Same skill body subscribed by N users => one copy in KV, not N.
// ─────────────────────────────────────────────────────────────────────

const SKILL_PREFIX = 'skill:';

// Body keys are versioned by updated_at, so editing a skill mints a new
// key and the old one ages out naturally. Long TTL is safe.
const SKILL_BODY_TTL_SEC = 24 * 60 * 60; // 24 h

interface SkillRef {
  id: string;
  updated_at: string;
}

interface CachedSubsRefs {
  refs: SkillRef[];
  /// Aggregated allowed_tools across all subscribed skills (used to
  /// gate sensitive tools like execute_code on the turn's tool list).
  /// Bounded by the same 5-min TTL as the refs list itself.
  allowedTools: string[];
}

interface CachedSubsBundle {
  skills: CachedSkill[];
  allowedTools: string[];
}

interface SkillFrontmatter {
  name?: string;
  description?: string;
  allowed_tools?: unknown;
}

function skillBodyKey(id: string, updatedAt: string): string {
  return `${SKILL_PREFIX}${id}:${updatedAt}`;
}

function extractAllowedTools(fm: SkillFrontmatter | null | undefined): string[] {
  const out: string[] = [];
  const tools = fm?.allowed_tools;
  if (Array.isArray(tools)) {
    for (const t of tools) if (typeof t === 'string') out.push(t);
  }
  return out;
}

function toCachedSkill(fm: SkillFrontmatter | null | undefined, body: string): CachedSkill {
  return {
    name: fm?.name ?? 'unnamed',
    description: fm?.description ?? '',
    body,
    allowedTools: extractAllowedTools(fm),
  };
}

function subsCacheKey(
  userId: string,
  conversationId: string,
  providerSlug: ProviderSlug,
): string {
  return `${SUBS_PREFIX}${userId}:${conversationId}:${providerSlug}`;
}

async function getCachedSubsRefs(
  env: Env,
  userId: string,
  conversationId: string,
  providerSlug: ProviderSlug,
): Promise<CachedSubsRefs | null> {
  return env.MEMORY.get<CachedSubsRefs>(
    subsCacheKey(userId, conversationId, providerSlug),
    'json',
  );
}

async function putCachedSubsRefs(
  env: Env,
  userId: string,
  conversationId: string,
  providerSlug: ProviderSlug,
  refs: CachedSubsRefs,
): Promise<void> {
  await env.MEMORY.put(
    subsCacheKey(userId, conversationId, providerSlug),
    JSON.stringify(refs),
    { expirationTtl: SUBS_TTL_SEC },
  );
}

async function putCachedSkillBody(
  env: Env,
  id: string,
  updatedAt: string,
  skill: CachedSkill,
): Promise<void> {
  await env.MEMORY.put(skillBodyKey(id, updatedAt), JSON.stringify(skill), {
    expirationTtl: SKILL_BODY_TTL_SEC,
  });
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
  providerSlug: ProviderSlug,
  waitUntil: (p: Promise<unknown>) => void,
): Promise<CachedSubsBundle> {
  let refsBundle = await getCachedSubsRefs(env, userId, conversationId, providerSlug);
  // Frontmatter we already fetched alongside refs — lets us skip the
  // bodies query for nothing-cached-but-just-fetched-meta rows.
  const freshMeta = new Map<string, SkillFrontmatter>();

  if (!refsBundle) {
    type SkillMetaRow = {
      id: string;
      updated_at: string;
      frontmatter: SkillFrontmatter;
    };
    // !inner forces an INNER JOIN so the embedded skills.provider
    // filter actually filters parent rows (default LEFT JOIN would
    // keep subscriptions whose skill is the wrong provider but with
    // a null embed, which we'd then have to drop in JS).
    const { data } = await supa
      .from('skill_subscriptions')
      .select('skills!inner(id, updated_at, frontmatter)')
      .eq('user_id', userId)
      .eq('skills.provider', providerSlug)
      .or(`conversation_id.eq.${conversationId},conversation_id.is.null`);

    const refs: SkillRef[] = [];
    const allowedToolSet = new Set<string>();
    for (const row of data ?? []) {
      const joined = (row as { skills: SkillMetaRow | SkillMetaRow[] | null }).skills;
      const arr = Array.isArray(joined) ? joined : joined ? [joined] : [];
      for (const s of arr) {
        refs.push({ id: s.id, updated_at: s.updated_at });
        freshMeta.set(s.id, s.frontmatter);
        for (const t of extractAllowedTools(s.frontmatter)) allowedToolSet.add(t);
      }
    }
    refsBundle = { refs, allowedTools: Array.from(allowedToolSet) };
    waitUntil(putCachedSubsRefs(env, userId, conversationId, providerSlug, refsBundle));
  }

  const bodyResults = await Promise.all(
    refsBundle.refs.map((r) =>
      env.MEMORY.get<CachedSkill>(skillBodyKey(r.id, r.updated_at), 'json'),
    ),
  );

  const skills: CachedSkill[] = new Array(refsBundle.refs.length);
  const missingIdxs: number[] = [];
  for (let i = 0; i < refsBundle.refs.length; i++) {
    const cached = bodyResults[i];
    if (cached) skills[i] = cached;
    else missingIdxs.push(i);
  }

  if (missingIdxs.length > 0) {
    const missingIds = missingIdxs.map((i) => refsBundle.refs[i].id);
    type SkillBodyRow = {
      id: string;
      frontmatter: SkillFrontmatter;
      body_md: string;
    };
    const { data: rows } = await supa
      .from('skills')
      .select('id, frontmatter, body_md')
      .in('id', missingIds);
    const byId = new Map<string, SkillBodyRow>();
    for (const r of (rows ?? []) as SkillBodyRow[]) byId.set(r.id, r);

    for (const i of missingIdxs) {
      const ref = refsBundle.refs[i];
      const row = byId.get(ref.id);
      if (!row) {
        // Skill row vanished between refs-fetch and bodies-fetch. Don't
        // cache; serve a placeholder so the caller sees a stable shape.
        skills[i] = { name: 'unavailable', description: '', body: '', allowedTools: [] };
        continue;
      }
      // Prefer fresh frontmatter from the refs-fetch when we have it
      // (it's the same row we'd be reading anyway, and avoids a tiny
      // race where updated_at advances mid-flight).
      const fm = freshMeta.get(ref.id) ?? row.frontmatter;
      const skill = toCachedSkill(fm, row.body_md);
      skills[i] = skill;
      waitUntil(putCachedSkillBody(env, ref.id, ref.updated_at, skill));
    }
  }

  return { skills, allowedTools: refsBundle.allowedTools };
}
