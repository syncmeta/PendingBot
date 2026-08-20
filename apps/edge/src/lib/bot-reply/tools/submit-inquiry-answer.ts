// `submit_inquiry_answer` — closes out the ask_friend loop. Called by
// the SAME bot in the SAME relay conversation it was reaching out from,
// once the bot has wrapped up the back-and-forth with the human friend
// and has a final answer to ship back to the caller.
//
// Active vs. inactive routing decides how the answer gets back to the
// caller conversation:
//
//   - "active" (caller_conv has any message in the last 10s): write the
//     answer onto the inquiry row with status='answered_pending'. The
//     bot's next turn in caller_conv will see it in volatile context
//     (see builder.ts buildPendingInquiryAnswersSection) and weave the
//     answer into its natural reply. No new spontaneous bubble.
//
//   - "inactive": insert a fresh bot-role message in caller_conv with
//     the answer as content + push notification, mark the inquiry
//     'answered_delivered' on the spot. The bot speaks up unprompted.
//
// In both cases the tool returns immediately to the bot that called it;
// the relay-side bot can then say "好的,我把答案告诉ta了" to the friend.

import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import { uuidv7 } from '../../ids';
import { notifyUserMessage } from '../../push';
import type { ToolCtx } from '../tool-runner';

const ANSWER_MAX = 6_000;
// Caller-conv "active" window. Within this many ms of the last
// message, we assume someone is still in the chat and prefer
// natural-injection over speaking up. 10s lines up with the product
// brief.
const ACTIVE_WINDOW_MS = 10_000;

interface InquiryRow {
  id: string;
  caller_bot_id: string;
  caller_conversation_id: string;
  target_user_id: string;
  relay_conversation_id: string;
  status: string;
}

export async function submitInquiryAnswerTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const inquiryId =
    typeof args.inquiry_id === 'string' ? args.inquiry_id.trim() : '';
  const answer = typeof args.answer === 'string' ? args.answer.trim() : '';
  if (!inquiryId) return JSON.stringify({ error: 'empty inquiry_id' });
  if (!answer) return JSON.stringify({ error: 'empty answer' });
  if (answer.length > ANSWER_MAX) {
    return JSON.stringify({ error: `answer exceeds ${ANSWER_MAX} chars` });
  }

  const supa = serviceClient(env);
  const { data: inqData, error: inqErr } = await supa
    .from('bot_friend_inquiries')
    .select('id, caller_bot_id, caller_conversation_id, target_user_id, relay_conversation_id, status')
    .eq('id', inquiryId)
    .maybeSingle();
  if (inqErr) return JSON.stringify({ error: `inquiry lookup failed: ${inqErr.message}` });
  if (!inqData) return JSON.stringify({ error: `inquiry not found: ${inquiryId}` });

  const inquiry = inqData as InquiryRow;
  if (inquiry.status !== 'open') {
    return JSON.stringify({
      error: `inquiry already in status "${inquiry.status}" — too late to submit again`,
    });
  }

  // Ownership check: this tool must be called by the same bot, from the
  // relay conversation it actually went to. Both protect against weird
  // cross-contamination and let us be sure ctx.botId / ctx.conversationId
  // are talking about the right thing.
  if (inquiry.caller_bot_id !== ctx.botId) {
    return JSON.stringify({
      error: `inquiry is not yours (caller_bot_id mismatch)`,
    });
  }
  if (inquiry.relay_conversation_id !== ctx.conversationId) {
    return JSON.stringify({
      error: `submit_inquiry_answer must be called from the relay conversation (id ${inquiry.relay_conversation_id}), not ${ctx.conversationId}`,
    });
  }

  // Check caller_conv activity to pick routing.
  const { data: lastMsg } = await supa
    .from('messages')
    .select('created_at')
    .eq('conversation_id', inquiry.caller_conversation_id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  const lastTs = lastMsg?.created_at ? new Date(lastMsg.created_at as string).getTime() : 0;
  const ageMs = Date.now() - lastTs;
  const active = lastTs > 0 && ageMs <= ACTIVE_WINDOW_MS;

  if (active) {
    // Park the answer; next caller-conv turn will inject it via builder.
    const { error: upErr } = await supa
      .from('bot_friend_inquiries')
      .update({
        answer,
        status: 'answered_pending',
        answered_at: new Date().toISOString(),
      })
      .eq('id', inquiry.id);
    if (upErr) return JSON.stringify({ error: `inquiry update failed: ${upErr.message}` });

    ctx.emit('tool_result', {
      name: 'submit_inquiry_answer',
      inquiry_id: inquiry.id,
      route: 'pending_inject',
    });
    return JSON.stringify({
      status: 'pending_inject',
      route_reason: `caller_conv has activity within ${Math.round(ACTIVE_WINDOW_MS / 1000)}s; answer will surface in caller's next turn`,
      inquiry_id: inquiry.id,
    });
  }

  // Inactive: speak up in caller_conv directly.
  const callerMsgId = uuidv7();
  const { error: msgErr } = await supa.from('messages').insert({
    id: callerMsgId,
    client_message_id: callerMsgId,
    conversation_id: inquiry.caller_conversation_id,
    sender_bot_id: ctx.botId,
    role: 'bot',
    content: answer,
    status: 'done',
  });
  if (msgErr) {
    return JSON.stringify({ error: `caller-side msg insert failed: ${msgErr.message}` });
  }

  const { error: upErr } = await supa
    .from('bot_friend_inquiries')
    .update({
      answer,
      status: 'answered_delivered',
      answered_at: new Date().toISOString(),
    })
    .eq('id', inquiry.id);
  if (upErr) return JSON.stringify({ error: `inquiry update failed: ${upErr.message}` });

  // Push the spontaneous reply to the caller user. We look up caller
  // user via the caller conversation.
  const { data: convRow } = await supa
    .from('conversations')
    .select('user_id')
    .eq('id', inquiry.caller_conversation_id)
    .maybeSingle();
  const callerUserId = (convRow?.user_id as string | undefined) ?? null;
  const { data: botRow } = await supa
    .from('bots')
    .select('display_name')
    .eq('id', ctx.botId)
    .maybeSingle();
  const senderName = (botRow?.display_name as string | null) ?? '机器人';
  if (callerUserId) {
    await notifyUserMessage({
      env,
      userId: callerUserId,
      senderName,
      contentPreview: answer,
      threadId: inquiry.caller_conversation_id,
      extra: { conversationId: inquiry.caller_conversation_id, kind: 'bot_reply' },
      collapseId: inquiry.caller_conversation_id,
    }).catch((e) => {
      console.warn('[submit_inquiry_answer] caller push failed', e);
    });
  }

  ctx.emit('tool_result', {
    name: 'submit_inquiry_answer',
    inquiry_id: inquiry.id,
    route: 'spontaneous_message',
  });
  return JSON.stringify({
    status: 'spontaneous_message',
    route_reason: `caller_conv idle for ${Math.round(ageMs / 1000)}s; bot opened up with the answer directly`,
    inquiry_id: inquiry.id,
    caller_message_id: callerMsgId,
  });
}
