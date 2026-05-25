import type { Env } from '../types';
import { serviceClient, userClient } from './supabase';

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

type AuthzCode = 'database_error' | 'forbidden' | 'not_found';

export type AuthzResult<T> =
  | ({ ok: true } & T)
  | { ok: false; code: AuthzCode; detail?: string; role?: GroupRole | null };

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
