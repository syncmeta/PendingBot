import { publishToHub } from './realtime-publish';
import { projectUnreadRow } from './projection-writethrough';
import { serviceClient } from './supabase';
import type { Env } from '../types';

type ReadThroughInput = {
  env: Env;
  userId: string;
  conversationId: string;
  messageId?: string;
  messageSeq?: number | null;
};

export async function notifyConversationUnreadState(
  env: Env,
  conversationId: string,
  onlyUserIds?: string[],
): Promise<void> {
  const supa = serviceClient(env);
  let query = supa
    .from('user_unread_counts')
    .select(
      'user_id, conversation_id, unread_count, last_message_id, last_message_seq, last_message_at, last_message_preview',
    )
    .eq('conversation_id', conversationId);

  if (onlyUserIds && onlyUserIds.length > 0) {
    query = query.in('user_id', onlyUserIds);
  }

  const { data, error } = await query;
  if (error) {
    console.warn('[unread-state] unread read failed', error.message);
    return;
  }

  // 两件事一起做:
  //   1. 推实时增量(连着的客户端立刻更红点/预览)
  //   2. **写穿边缘会话列表投影** —— user_unread_counts 的 realtime_notify
  //      触发器在 2026-05-29 被撤时,理由写的就是"改由边缘自己发",但边缘这半
  //      一直没接上,于是列表投影的未读/预览/最后活跃时间永远停在建行那一刻。
  //      这里就是那条欠了两个多月的通道。
  await Promise.all(
    (data ?? []).flatMap((row) => [
      publishToHub(env, `user:${row.user_id}`, {
        type: 'change',
        table: 'user_unread_counts',
        op: 'update',
        record: row as Record<string, unknown>,
      }),
      projectUnreadRow(env, row as Record<string, unknown>),
    ]),
  );
}

export async function markConversationReadThroughLatest(
  input: ReadThroughInput,
): Promise<{ messageSeq: number | null }> {
  const supa = serviceClient(input.env);
  const resolved = await resolveReadTarget(input);
  const messageSeq = resolved.messageSeq;

  const participantPatch: {
    last_read_message_id?: string;
    last_read_message_seq?: number | null;
  } = {
    last_read_message_seq: messageSeq,
  };
  if (resolved.messageId) {
    participantPatch.last_read_message_id = resolved.messageId;
  }

  const { error: participantErr } = await supa
    .from('conversation_participants')
    .update(participantPatch)
    .eq('conversation_id', input.conversationId)
    .eq('participant_type', 'user')
    .eq('participant_id', input.userId);
  if (participantErr) {
    console.warn('[unread-state] participant read ack failed', participantErr.message);
  }

  let unreadQuery = supa
    .from('user_unread_counts')
    .update({ unread_count: 0 })
    .eq('conversation_id', input.conversationId)
    .eq('user_id', input.userId);
  if (messageSeq !== null) {
    unreadQuery = unreadQuery.lte('last_message_seq', messageSeq);
  } else if (resolved.messageId) {
    unreadQuery = unreadQuery.eq('last_message_id', resolved.messageId);
  }

  const { error: unreadErr } = await unreadQuery;
  if (unreadErr) {
    console.warn('[unread-state] unread clear failed', unreadErr.message);
  }

  await notifyConversationUnreadState(input.env, input.conversationId, [input.userId]);
  return { messageSeq };
}

async function resolveReadTarget(input: ReadThroughInput): Promise<{
  messageId: string | null;
  messageSeq: number | null;
}> {
  if (typeof input.messageSeq === 'number') {
    return { messageId: input.messageId ?? null, messageSeq: input.messageSeq };
  }

  const supa = serviceClient(input.env);
  if (input.messageId) {
    const { data, error } = await supa
      .from('messages')
      .select('id, message_seq')
      .eq('conversation_id', input.conversationId)
      .eq('id', input.messageId)
      .maybeSingle();
    if (error) {
      console.warn('[unread-state] message read target failed', error.message);
      return { messageId: input.messageId, messageSeq: null };
    }
    return {
      messageId: data?.id ?? input.messageId,
      messageSeq: typeof data?.message_seq === 'number' ? data.message_seq : null,
    };
  }

  const { data, error } = await supa
    .from('messages')
    .select('id, message_seq')
    .eq('conversation_id', input.conversationId)
    .order('message_seq', { ascending: false })
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) {
    console.warn('[unread-state] latest read target failed', error.message);
    return { messageId: null, messageSeq: null };
  }

  return {
    messageId: data?.id ?? null,
    messageSeq: typeof data?.message_seq === 'number' ? data.message_seq : null,
  };
}
