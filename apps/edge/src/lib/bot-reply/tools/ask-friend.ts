// `ask_friend` — public bot reaches out to a human friend with a
// question, asynchronously. The bot drafts a self-contained message,
// the tool drops it into the bot↔friend 1v1 conversation as a bot-role
// message + push notification, opens an inquiry row to track state,
// and returns immediately. The friend answers in their own time.
//
// When the bot (over in the relay 1v1) has what it needs, it calls
// `submit_inquiry_answer` to wrap up and send the answer back to the
// caller. See submit-inquiry-answer.ts for the回流 half.
//
// Only available to public bots (visibility='public_invite') — private
// bots have exactly one friend (the owner) and asking the owner is
// just… talking to them. Tool dispatcher gates this with the same
// visibility check used for inclusion in the per-turn tool list.

import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import { uuidv7 } from '../../ids';
import { getBotFriends } from '../../bot-social';
import { notifyUserMessage } from '../../push';
import type { ToolCtx } from '../tool-runner';

const QUESTION_MAX = 4_000;

async function botVisibility(env: Env, botId: string): Promise<string | null> {
  const supa = serviceClient(env);
  const { data } = await supa.from('bots').select('visibility, display_name').eq('id', botId).single();
  return (data?.visibility as string | undefined) ?? null;
}

async function findOrCreateRelayConv(
  env: Env,
  botId: string,
  targetUserId: string,
): Promise<{ conversationId: string; existed: boolean; error?: string }> {
  const supa = serviceClient(env);
  // Newest matching 1v1 conv wins — if multiple ever existed (shouldn't,
  // but be defensive), reuse the most recent.
  const { data: existing } = await supa
    .from('conversations')
    .select('id')
    .eq('conversation_type', 'user_bot')
    .eq('user_id', targetUserId)
    .eq('bot_id', botId)
    .order('updated_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (existing?.id) {
    return { conversationId: existing.id as string, existed: true };
  }

  const convId = uuidv7();
  const { error: convErr } = await supa.from('conversations').insert({
    id: convId,
    conversation_type: 'user_bot',
    user_id: targetUserId,
    bot_id: botId,
    title: '新对话',
  });
  if (convErr) return { conversationId: convId, existed: false, error: convErr.message };

  const { error: partErr } = await supa.from('conversation_participants').insert([
    { conversation_id: convId, participant_type: 'user', participant_id: targetUserId, role: 'owner' },
    { conversation_id: convId, participant_type: 'bot',  participant_id: botId,        role: 'member' },
  ]);
  if (partErr) return { conversationId: convId, existed: false, error: partErr.message };

  return { conversationId: convId, existed: false };
}

export async function askFriendTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  // Bot picks a friend by display name — much more natural than UUIDs.
  // We resolve case-insensitively against the bot's actual friend list;
  // if ambiguous or absent the tool errors with the available names so
  // the LLM can retry with a tighter spec.
  const targetName =
    typeof args.target_display_name === 'string'
      ? args.target_display_name.trim()
      : typeof args.target === 'string'
        ? args.target.trim()
        : '';
  const question = typeof args.question === 'string' ? args.question.trim() : '';
  if (!targetName) return JSON.stringify({ error: 'empty target_display_name' });
  if (!question) return JSON.stringify({ error: 'empty question' });
  if (question.length > QUESTION_MAX) {
    return JSON.stringify({ error: `question exceeds ${QUESTION_MAX} chars` });
  }

  const supa = serviceClient(env);

  // Visibility gate — defensive; the tool dispatcher should already
  // have filtered ask_friend out for private bots.
  const vis = await botVisibility(env, ctx.botId);
  if (vis !== 'public_invite') {
    return JSON.stringify({ error: 'ask_friend is only available to public bots' });
  }

  const friends = await getBotFriends(supa, ctx.botId);
  const needle = targetName.toLowerCase();
  const matches = friends.filter((f) => f.display_name.toLowerCase() === needle);
  if (matches.length === 0) {
    return JSON.stringify({
      error: `no friend matches "${targetName}"`,
      available_friends: friends.map((f) => f.display_name).slice(0, 20),
    });
  }
  if (matches.length > 1) {
    return JSON.stringify({
      error: `"${targetName}" is ambiguous (${matches.length} matches); ask_friend doesn't take user ids yet, so rename one of them or pick by surrounding context`,
    });
  }
  const target = matches[0];

  // Find-or-create the bot↔friend 1v1. New convs may seed an
  // automatic title later via the title runner; '新对话' is the same
  // placeholder open_user_bot_conv uses.
  const relay = await findOrCreateRelayConv(env, ctx.botId, target.user_id);
  if (relay.error) {
    return JSON.stringify({ error: `relay conv setup failed: ${relay.error}` });
  }

  // Refuse if there's already an open inquiry on this relay — the
  // partial unique index will throw, but front-running it gives a
  // cleaner error to the LLM.
  const { data: openRow } = await supa
    .from('bot_friend_inquiries')
    .select('id, question')
    .eq('relay_conversation_id', relay.conversationId)
    .eq('status', 'open')
    .maybeSingle();
  if (openRow) {
    return JSON.stringify({
      error: `there is already an open inquiry on this friend; wait for them to answer first`,
      pending_inquiry_id: openRow.id,
    });
  }

  // Insert the outreach as a bot-role message. We use a UUID we already
  // know so the inquiry row can pin it via relay_outreach_message_id.
  const outreachMsgId = uuidv7();
  const { error: msgErr } = await supa.from('messages').insert({
    id: outreachMsgId,
    client_message_id: outreachMsgId,
    conversation_id: relay.conversationId,
    sender_bot_id: ctx.botId,
    role: 'bot',
    content: question,
    status: 'done',
  });
  if (msgErr) {
    return JSON.stringify({ error: `outreach msg insert failed: ${msgErr.message}` });
  }

  const inquiryId = uuidv7();
  const { error: inqErr } = await supa.from('bot_friend_inquiries').insert({
    id: inquiryId,
    caller_bot_id: ctx.botId,
    caller_conversation_id: ctx.conversationId,
    target_user_id: target.user_id,
    relay_conversation_id: relay.conversationId,
    relay_outreach_message_id: outreachMsgId,
    question,
    status: 'open',
  });
  if (inqErr) {
    return JSON.stringify({ error: `inquiry insert failed: ${inqErr.message}` });
  }

  // Notify the friend. notifyUserMessage already respects their preview
  // mode preference and fans out to all their devices.
  const { data: botRow } = await supa
    .from('bots')
    .select('display_name')
    .eq('id', ctx.botId)
    .maybeSingle();
  const senderName = (botRow?.display_name as string | null) ?? '机器人';
  // Push notification fires inline — only ~100-300ms typical and the
  // bot's turn is detached from the SSE response anyway (no client
  // bound to wait). Tool ctx doesn't expose executionCtx.waitUntil.
  await notifyUserMessage({
    env,
    userId: target.user_id,
    senderName,
    contentPreview: question,
    threadId: relay.conversationId,
    extra: { conversationId: relay.conversationId, kind: 'bot_reply' },
    collapseId: relay.conversationId,
  }).catch((e) => {
    console.warn('[ask_friend] push failed', e);
  });

  ctx.emit('tool_call', {
    name: 'ask_friend',
    target_display_name: target.display_name,
    inquiry_id: inquiryId,
  });
  ctx.emit('tool_result', {
    name: 'ask_friend',
    target_display_name: target.display_name,
    inquiry_id: inquiryId,
    relay_conversation_id: relay.conversationId,
    relay_existed: relay.existed,
  });

  return JSON.stringify({
    status: 'sent',
    inquiry_id: inquiryId,
    target_display_name: target.display_name,
    relay_conversation_id: relay.conversationId,
    note: '消息已发出。对方什么时候看到/什么时候回不由你掌控;等你和对方在那边对话清楚后,调 submit_inquiry_answer 把答案带回这边。',
  });
}
