// Bot-side social graph queries.
//
// Two flat reads the bot needs to know about itself:
//
//   getBotFriends(botId)  — every human who added this bot. Sourced
//                            from user_bot_contacts; the bot↔bot link
//                            isn't a thing (FK only allows user_id from
//                            auth.users), so this is by construction
//                            the "human friends" list.
//
//   getBotGroups(botId)   — every group the bot is sitting in. Reverse
//                            lookup on conversation_participants
//                            (participant_id has no FK, so we filter on
//                            participant_type='bot').
//
// Both use a service-role client — these reads run server-side during
// prompt construction / tool execution and must not be gated by the
// caller's RLS perspective. Access checks for any user-facing API
// surface live in the get_bot_friends RPC + route layer instead.

import type { SupabaseClient } from './supabase';

export interface BotFriend {
  user_id: string;
  display_name: string;
  avatar_path: string | null;
  added_at: string;
}

export interface BotGroup {
  conversation_id: string;
  title: string | null;
  joined_at: string;
}

export async function getBotFriends(
  supa: SupabaseClient,
  botId: string,
): Promise<BotFriend[]> {
  const { data: rows, error } = await supa
    .from('user_bot_contacts')
    .select('user_id, added_at')
    .eq('bot_id', botId)
    .order('added_at', { ascending: false });
  if (error) throw error;
  const list = rows ?? [];
  if (list.length === 0) return [];

  // pendingbot.users has self-only RLS; service client bypasses, but
  // we still need a separate query because user_bot_contacts.user_id
  // references auth.users (cross-schema) — PostgREST can't infer the
  // join across schemas.
  const ids = list.map((r) => r.user_id as string);
  const { data: profiles, error: pErr } = await supa
    .from('users')
    .select('id, display_name, avatar_path')
    .in('id', ids);
  if (pErr) throw pErr;
  const byId = new Map<string, { display_name: string; avatar_path: string | null }>();
  for (const p of profiles ?? []) {
    byId.set(p.id as string, {
      display_name: (p.display_name as string | null) ?? '',
      avatar_path: (p.avatar_path as string | null) ?? null,
    });
  }
  return list.map((r) => {
    const u = byId.get(r.user_id as string);
    return {
      user_id: r.user_id as string,
      display_name: u?.display_name ?? '',
      avatar_path: u?.avatar_path ?? null,
      added_at: r.added_at as string,
    };
  });
}

export interface BotSocialSnapshot {
  isPublic: boolean;
  friendsCount: number;
  recentFriends: Array<{ display_name: string }>;
  groupsCount: number;
  recentGroups: Array<{ title: string | null }>;
}

/** One-shot fetch shaped for the builder's `socialGraph` input. Combines
 *  a single visibility read with the two reverse-lookups; safe to fire
 *  alongside the rest of the per-turn parallel reads in bot-reply. Top-N
 *  truncation happens here so the caller doesn't decide policy. */
export async function loadBotSocialSnapshot(
  supa: SupabaseClient,
  botId: string,
  topN = 5,
): Promise<BotSocialSnapshot> {
  const [visRow, friends, groups] = await Promise.all([
    supa.from('bots').select('visibility').eq('id', botId).single(),
    getBotFriends(supa, botId),
    getBotGroups(supa, botId),
  ]);
  const visibility = (visRow.data?.visibility as string | undefined) ?? 'private';
  return {
    isPublic: visibility === 'public_invite',
    friendsCount: friends.length,
    recentFriends: friends.slice(0, topN).map((f) => ({ display_name: f.display_name })),
    groupsCount: groups.length,
    recentGroups: groups.slice(0, topN).map((g) => ({ title: g.title })),
  };
}

export async function getBotGroups(
  supa: SupabaseClient,
  botId: string,
): Promise<BotGroup[]> {
  const { data, error } = await supa
    .from('conversation_participants')
    .select(
      'conversation_id, joined_at, conversation:conversations!inner(title, conversation_type)',
    )
    .eq('participant_type', 'bot')
    .eq('participant_id', botId)
    .eq('conversation.conversation_type', 'group')
    .order('joined_at', { ascending: false });
  if (error) throw error;
  return (data ?? []).map((row: any) => ({
    conversation_id: row.conversation_id as string,
    title: (row.conversation?.title as string | null) ?? null,
    joined_at: row.joined_at as string,
  }));
}
