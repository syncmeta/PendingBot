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

export interface PendingInquiryAnswer {
  inquiry_id: string;
  target_display_name: string;
  question: string;
  answer: string;
}

export interface OpenRelayInquiry {
  inquiry_id: string;
  question: string;
}

export interface InquiryContext {
  pendingAnswers: PendingInquiryAnswer[];
  openRelayInquiries: OpenRelayInquiry[];
}

/** Load + atomically claim the inquiry-side volatile context for one
 *  per-turn run:
 *    - pendingAnswers   : answered_pending rows where caller_conv is ours
 *                         and caller_bot_id is us. Switched to
 *                         answered_delivered before returning so they
 *                         only surface once (lose-on-error trade is
 *                         accepted — beats double-delivering).
 *    - openRelayInquiries : open rows where relay_conv is ours and
 *                           caller_bot_id is us. Read-only — they stay
 *                           open until submit_inquiry_answer fires. */
export async function loadInquiryContext(
  supa: SupabaseClient,
  botId: string,
  conversationId: string,
): Promise<InquiryContext> {
  // Pending (caller side). Read first so we can immediately flip status
  // to answered_delivered; the flip happens after we have the rows so
  // the bot doesn't lose them if the SELECT fails.
  const { data: pendingRows } = await supa
    .from('bot_friend_inquiries')
    .select('id, target_user_id, question, answer')
    .eq('caller_bot_id', botId)
    .eq('caller_conversation_id', conversationId)
    .eq('status', 'answered_pending');

  let pendingAnswers: PendingInquiryAnswer[] = [];
  if (pendingRows && pendingRows.length > 0) {
    const ids = pendingRows.map((r) => r.id as string);
    // Resolve target display names. Service-role read of users; cheap
    // batch.
    const targetIds = Array.from(
      new Set(pendingRows.map((r) => r.target_user_id as string)),
    );
    const { data: userRows } = await supa
      .from('users')
      .select('id, display_name')
      .in('id', targetIds);
    const nameById = new Map<string, string>();
    for (const u of userRows ?? []) {
      nameById.set(u.id as string, (u.display_name as string) ?? '');
    }
    pendingAnswers = pendingRows.map((r) => ({
      inquiry_id: r.id as string,
      target_display_name: nameById.get(r.target_user_id as string) ?? '某位好友',
      question: (r.question as string) ?? '',
      answer: (r.answer as string) ?? '',
    }));
    // Atomic-ish claim — flip status so the next turn doesn't re-show
    // them. Failure to flip is logged but doesn't abort: the bot still
    // sees the answer this turn; the duplicate next turn is benign
    // (LLM will notice and not re-mention).
    const { error: flipErr } = await supa
      .from('bot_friend_inquiries')
      .update({ status: 'answered_delivered' })
      .in('id', ids);
    if (flipErr) {
      console.warn('[inquiry] pending → delivered flip failed', flipErr);
    }
  }

  const { data: openRows } = await supa
    .from('bot_friend_inquiries')
    .select('id, question')
    .eq('caller_bot_id', botId)
    .eq('relay_conversation_id', conversationId)
    .eq('status', 'open');
  const openRelayInquiries: OpenRelayInquiry[] = (openRows ?? []).map((r) => ({
    inquiry_id: r.id as string,
    question: (r.question as string) ?? '',
  }));

  return { pendingAnswers, openRelayInquiries };
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
