import type { Env } from '../types';
import { serviceClient, userClient } from './supabase';
import { resolveConv, type CachedConv } from './conv-cache';
import { resolveAttachmentOwnership, type AttachmentOwnership } from './attachment-cache';

export type GroupRole = 'owner' | 'admin' | 'member' | string;

export interface GroupConversation {
  id: string;
  conversation_type: string;
  user_id: string | null;
}

export interface GroupMembership {
  participant_id: string;
  role: GroupRole | null;
}

export interface MessageDeleteTarget {
  messageId: string;
  conversationId: string;
  authoredByCaller: boolean;
  conversationOwnedByCaller: boolean;
  conversationType: string | null;
  isBotReply: boolean;
}

export interface MessageRecallTarget {
  messageId: string;
  conversationId: string;
  conversationType: string | null;
  attachments: unknown;
  createdAt: string | null;
  alreadyDeleted: boolean;
}

export interface BotUseTarget {
  id: string;
  visibility: string | null;
  creator_id: string | null;
}

type AuthzCode = 'database_error' | 'forbidden' | 'not_found';
type MessageSendAuthzCode = AuthzCode | 'gone';

export type AuthzResult<T> =
  | ({ ok: true } & T)
  | { ok: false; code: AuthzCode; detail?: string; role?: GroupRole | null };

export type MessageSendAuthzResult<T> =
  | ({ ok: true } & T)
  | { ok: false; code: MessageSendAuthzCode; detail?: string };

export type MessageSendConversation = CachedConv & {
  conversation_type: 'user_bot' | 'self' | 'group' | 'user_user';
};

export async function authorizeAttachmentOwnership(
  env: Env,
  userId: string,
  attachmentIds: readonly string[],
  waitUntil: (p: Promise<unknown>) => void,
): Promise<AuthzResult<{ attachments: AttachmentOwnership[] }>> {
  if (attachmentIds.length === 0) return { ok: true, attachments: [] };
  const supa = serviceClient(env);
  let rows: AttachmentOwnership[] | null;
  try {
    rows = await resolveAttachmentOwnership(env, supa, attachmentIds, waitUntil);
  } catch (err) {
    return {
      ok: false,
      code: 'database_error',
      detail: (err as { message?: string }).message ?? 'attachment lookup failed',
    };
  }
  if (!rows) return { ok: false, code: 'not_found' };
  for (const row of rows) {
    if (row.user_id !== userId) return { ok: false, code: 'forbidden' };
  }
  return { ok: true, attachments: rows };
}

export async function authorizeMessageSendConversation(
  env: Env,
  userJwt: string,
  userId: string,
  conversationId: string,
  waitUntil: (p: Promise<unknown>) => void,
): Promise<MessageSendAuthzResult<{ conversation: MessageSendConversation }>> {
  const supaUser = userClient(env, userJwt);
  let conv: CachedConv | null;
  try {
    conv = await resolveConv(env, supaUser, conversationId, userId, waitUntil);
  } catch (err) {
    return {
      ok: false,
      code: 'database_error',
      detail: (err as { message?: string }).message ?? 'resolveConv failed',
    };
  }
  if (!conv) return { ok: false, code: 'not_found' };

  if (conv.conversation_type === 'user_user') {
    const supa = serviceClient(env);
    const { data: peer, error: peerErr } = await supa
      .from('conversation_participants')
      .select('participant_id')
      .eq('conversation_id', conversationId)
      .eq('participant_type', 'user')
      .neq('participant_id', userId)
      .limit(1)
      .maybeSingle();
    if (peerErr) return { ok: false, code: 'database_error', detail: peerErr.message };
    if (!peer) return { ok: false, code: 'gone' };
  }

  return {
    ok: true,
    conversation: {
      ...conv,
      conversation_type: normalizeMessageConversationType(conv.conversation_type),
    },
  };
}

function normalizeMessageConversationType(
  conversationType: string,
): MessageSendConversation['conversation_type'] {
  if (conversationType === 'self' || conversationType === 'group' || conversationType === 'user_user') {
    return conversationType;
  }
  return 'user_bot';
}

export async function loadGroupConversationForUser(
  env: Env,
  userJwt: string,
  userId: string,
  conversationId: string,
): Promise<AuthzResult<{ conversation: GroupConversation; membership: GroupMembership }>> {
  const supaUser = userClient(env, userJwt);
  const { data: conv, error: convErr } = await supaUser
    .from('conversations')
    .select('id, conversation_type, user_id')
    .eq('id', conversationId)
    .maybeSingle();
  if (convErr) return { ok: false, code: 'database_error', detail: convErr.message };
  if (!conv || conv.conversation_type !== 'group') {
    return { ok: false, code: 'not_found' };
  }

  const member = await loadGroupMembership(env, conversationId, userId);
  if (!member.ok) return member;

  return {
    ok: true,
    conversation: {
      id: conv.id,
      conversation_type: conv.conversation_type,
      user_id: conv.user_id ?? null,
    },
    membership: member.membership,
  };
}

export async function loadGroupMembership(
  env: Env,
  conversationId: string,
  userId: string,
): Promise<AuthzResult<{ membership: GroupMembership }>> {
  const supa = serviceClient(env);
  const { data, error } = await supa
    .from('conversation_participants')
    .select('participant_id, role')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'user')
    .eq('participant_id', userId)
    .maybeSingle();
  if (error) return { ok: false, code: 'database_error', detail: error.message };
  if (!data) return { ok: false, code: 'forbidden' };
  return {
    ok: true,
    membership: {
      participant_id: data.participant_id,
      role: data.role ?? null,
    },
  };
}

export async function isGroupHumanParticipant(
  env: Env,
  conversationId: string,
  userId: string,
): Promise<AuthzResult<{ participantId: string }>> {
  const member = await loadGroupMembership(env, conversationId, userId);
  if (!member.ok) return member;
  return { ok: true, participantId: member.membership.participant_id };
}

export async function isGroupBotParticipant(
  env: Env,
  conversationId: string,
  botId: string,
): Promise<AuthzResult<{ participantId: string }>> {
  const supa = serviceClient(env);
  const { data, error } = await supa
    .from('conversation_participants')
    .select('participant_id')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'bot')
    .eq('participant_id', botId)
    .maybeSingle();
  if (error) return { ok: false, code: 'database_error', detail: error.message };
  if (!data) return { ok: false, code: 'forbidden' };
  return { ok: true, participantId: data.participant_id };
}

export async function requireGroupRole(
  env: Env,
  conversationId: string,
  userId: string,
  roles: readonly GroupRole[],
): Promise<AuthzResult<{ role: GroupRole | null }>> {
  const member = await loadGroupMembership(env, conversationId, userId);
  if (!member.ok) return member;
  const role = member.membership.role;
  if (!role || !roles.includes(role)) {
    return { ok: false, code: 'forbidden', role };
  }
  return { ok: true, role };
}

export async function listGroupAdminUserIds(
  env: Env,
  conversationId: string,
): Promise<AuthzResult<{ userIds: string[] }>> {
  const supa = serviceClient(env);
  const { data, error } = await supa
    .from('conversation_participants')
    .select('participant_id')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'user')
    .in('role', ['owner', 'admin']);
  if (error) return { ok: false, code: 'database_error', detail: error.message };
  return {
    ok: true,
    userIds: (data ?? []).map((row) => row.participant_id),
  };
}

export async function findSharedUserUserConversation(
  env: Env,
  userId: string,
  otherUserId: string,
): Promise<AuthzResult<{ conversationId: string | null }>> {
  const supa = serviceClient(env);
  const { data: mine, error: mineErr } = await supa
    .from('conversation_participants')
    .select('conversation_id, conversations!inner(conversation_type)')
    .eq('participant_type', 'user')
    .eq('participant_id', userId)
    .eq('conversations.conversation_type', 'user_user');
  if (mineErr) return { ok: false, code: 'database_error', detail: mineErr.message };

  const myConvIds = (mine ?? []).map((row) => row.conversation_id);
  if (myConvIds.length === 0) return { ok: true, conversationId: null };

  const { data: theirs, error: theirsErr } = await supa
    .from('conversation_participants')
    .select('conversation_id')
    .eq('participant_type', 'user')
    .eq('participant_id', otherUserId)
    .in('conversation_id', myConvIds);
  if (theirsErr) return { ok: false, code: 'database_error', detail: theirsErr.message };

  return {
    ok: true,
    conversationId: (theirs ?? [])[0]?.conversation_id ?? null,
  };
}

export async function authorizeMessageDelete(
  env: Env,
  messageId: string,
  userId: string,
): Promise<AuthzResult<{ target: MessageDeleteTarget }>> {
  const supa = serviceClient(env);
  const { data: msg, error: msgErr } = await supa
    .schema('pendingbot')
    .from('messages')
    .select('id, user_id, sender_bot_id, conversation_id')
    .eq('id', messageId)
    .maybeSingle();
  if (msgErr) return { ok: false, code: 'database_error', detail: msgErr.message };
  if (!msg) return { ok: false, code: 'not_found' };

  const authoredByCaller = msg.user_id === userId;
  if (authoredByCaller) {
    return {
      ok: true,
      target: {
        messageId: msg.id,
        conversationId: msg.conversation_id,
        authoredByCaller: true,
        conversationOwnedByCaller: false,
        conversationType: null,
        isBotReply: !!msg.sender_bot_id,
      },
    };
  }

  const { data: conv, error: convErr } = await supa
    .schema('pendingbot')
    .from('conversations')
    .select('conversation_type, user_id')
    .eq('id', msg.conversation_id)
    .maybeSingle();
  if (convErr) return { ok: false, code: 'database_error', detail: convErr.message };

  const conversationType = (conv?.conversation_type as string | undefined) ?? null;
  const conversationOwnedByCaller = !!conv && conv.user_id === userId;
  const isBotReply = !!msg.sender_bot_id && !msg.user_id;
  const ownerMayDeletePresentationRow =
    conversationOwnedByCaller &&
    isBotReply &&
    (conversationType === 'user_bot' || conversationType === 'self');

  if (!ownerMayDeletePresentationRow) {
    return { ok: false, code: 'forbidden' };
  }

  return {
    ok: true,
    target: {
      messageId: msg.id,
      conversationId: msg.conversation_id,
      authoredByCaller: false,
      conversationOwnedByCaller,
      conversationType,
      isBotReply,
    },
  };
}

export async function authorizeMessageRecall(
  env: Env,
  messageId: string,
  userId: string,
): Promise<AuthzResult<{ target: MessageRecallTarget }>> {
  const supa = serviceClient(env);
  const { data: msg, error: msgErr } = await supa
    .schema('pendingbot')
    .from('messages')
    .select('id, user_id, sender_bot_id, conversation_id, status, attachments, created_at')
    .eq('id', messageId)
    .maybeSingle();
  if (msgErr) return { ok: false, code: 'database_error', detail: msgErr.message };
  if (!msg) return { ok: false, code: 'not_found' };

  // Bot rows have user_id=null / sender_bot_id set; they cannot be
  // recalled by anyone through the sender-initiated recall path.
  if (msg.user_id !== userId) return { ok: false, code: 'forbidden' };

  if (msg.status === 'deleted') {
    return {
      ok: true,
      target: {
        messageId: msg.id,
        conversationId: msg.conversation_id,
        conversationType: null,
        attachments: msg.attachments,
        createdAt: msg.created_at ?? null,
        alreadyDeleted: true,
      },
    };
  }

  const { data: conv, error: convErr } = await supa
    .schema('pendingbot')
    .from('conversations')
    .select('conversation_type')
    .eq('id', msg.conversation_id)
    .maybeSingle();
  if (convErr) return { ok: false, code: 'database_error', detail: convErr.message };

  return {
    ok: true,
    target: {
      messageId: msg.id,
      conversationId: msg.conversation_id,
      conversationType: (conv?.conversation_type as string | undefined) ?? 'user_bot',
      attachments: msg.attachments,
      createdAt: msg.created_at ?? null,
      alreadyDeleted: false,
    },
  };
}

export async function authorizeBotUse(
  env: Env,
  bot: BotUseTarget,
  userId: string,
): Promise<AuthzResult<{ allowed: true }>> {
  if (bot.visibility === 'private' && bot.creator_id !== userId) {
    return { ok: false, code: 'forbidden' };
  }

  if (bot.visibility === 'public_invite' && bot.creator_id !== userId) {
    const supa = serviceClient(env);
    const { data: invite, error } = await supa
      .from('bot_invites')
      .select('user_id')
      .eq('bot_id', bot.id)
      .eq('user_id', userId)
      .maybeSingle();
    if (error) return { ok: false, code: 'database_error', detail: error.message };
    if (!invite) return { ok: false, code: 'forbidden' };
  }

  return { ok: true, allowed: true };
}
