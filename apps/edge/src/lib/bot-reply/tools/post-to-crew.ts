// `post_to_crew` — server-side stub for the spec v2 §9.3 tool.
//
// Two call paths converge on this file:
//
//   1) PendingCrew runner detects the agent emitting a tool call named
//      `post_to_crew` → PendingCrew translates it into an HTTP request
//      against POST /v1/sessions/:sessionId/post-to-crew (the
//      "server-side 接收侧" — see routes/crew-comms.ts in a follow-up).
//      This is the dominant path; the agent lives in Claude Code /
//      Codex and never enters bot-reply.
//
//   2) A captain or master bot, mid–bot-reply, decides it wants to drop
//      a key-milestone post to the crew board. Bot-reply's tool-runner
//      lands here. We map the call to the existing
//      create_crew_announcement RPC, which gates membership and
//      handles fan-out for us.
//
// Spec v2 §9.3 guidance for category names:
//   - 'progress'  → ongoing-status update ("I'm at step 3 of 5")
//   - 'question'  → blocking question for the crew ("need write access?")
//   - 'milestone' → completed-step or hand-off announcement
// We store the category in the announcement's payload (the
// crew_announcements.message_kind enum is fixed in DB; we don't extend
// it here, just shadow our category in payload.category for downstream
// renderers).

import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import { coerceMentions, resolveOutboundRecipients } from '../../crew-outbound';
import type { ToolCtx } from '../tool-runner';

const CONTENT_MAX = 4_000;
const CATEGORIES = ['progress', 'question', 'milestone'] as const;
type Category = (typeof CATEGORIES)[number];

function pickCategory(raw: unknown): Category | null {
  if (typeof raw !== 'string') return null;
  return (CATEGORIES as readonly string[]).includes(raw) ? (raw as Category) : null;
}

export async function postToCrewTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const content = typeof args.content === 'string' ? args.content.trim() : '';
  if (!content) return JSON.stringify({ error: 'content required' });
  if (content.length > CONTENT_MAX) {
    return JSON.stringify({ error: `content exceeds ${CONTENT_MAX} chars` });
  }
  const category = pickCategory(args.category);

  // Confirm this bot is acting inside a crew conversation. The
  // conversation_id in ToolCtx is whatever conv the bot is replying in —
  // it's only a crew if temporary_group_meta has a row for it.
  const supa = serviceClient(env);
  const { data: meta, error: metaErr } = await supa
    .from('temporary_group_meta')
    .select('conversation_id, responsible_subject_id, status, temporary_kind')
    .eq('conversation_id', ctx.conversationId)
    .maybeSingle();
  if (metaErr) {
    return JSON.stringify({ error: 'lookup failed', detail: metaErr.message });
  }
  if (!meta || meta.temporary_kind !== 'crew' || meta.status !== 'active') {
    return JSON.stringify({
      error: 'post_to_crew may only be called inside an active crew conversation',
    });
  }

  // Phase 2 — resolve outbound @ + reply_to into explicit recipient lists
  // (shared with the HTTP endpoint via lib/crew-outbound). @session / a
  // reply_to of a session post → session recipients (each gets a mailbox row);
  // a reply_to of a human message → member recipient (no mailbox). A malformed
  // @ / reply_to surfaces as an error envelope (the model can retry).
  const replyTo = typeof args.reply_to === 'string' ? args.reply_to : null;
  const recip = await resolveOutboundRecipients(
    env,
    ctx.conversationId,
    coerceMentions(args.mentions),
    replyTo,
  );
  if (recip.error) {
    return JSON.stringify({ error: recip.error.message });
  }

  // Map category → board payload + a message_kind compatible with the
  // crew_announcements check constraint. We don't surface 'progress' or
  // 'milestone' as DB enums; they live in payload.category.
  const dbMessageKind = category === 'question' ? 'question' : 'status';
  const payload: Record<string, unknown> = {
    text: content,
    posted_by_bot_id: ctx.botId,
    source: 'bot_reply_tool',
  };
  if (category) payload.category = category;

  // We don't have a session_id in the bot-reply context (this path is
  // bot-as-sender, not session-as-sender). Call the human-sender RPC,
  // which expects an actor_user_id — use the user the bot is replying
  // to, since that's the active caller in this turn.
  const { data, error } = await supa.rpc('create_crew_announcement_for_subject', {
    p_crew_conversation_id: ctx.conversationId,
    p_responsible_subject_id: meta.responsible_subject_id,
    p_actor_user_id: ctx.userId,
    p_recipient_session_ids: recip.sessionIds,
    p_recipient_member_ids: recip.memberIds,
    p_message_kind: dbMessageKind,
    p_summary: content,
    p_payload: payload,
    p_board_visible: true,
  } as never);
  if (error) {
    const message = error.message ?? 'rpc error';
    return JSON.stringify({ error: 'create_crew_announcement failed', detail: message });
  }

  // Also mirror the post into the crew group chat (spec §9: the chat IS the
  // conversation's `messages`). The announcement above is the board source of
  // truth; this extra row is what makes the post visible in the group stream
  // as a bot card (role='bot', sender_bot_id). The reply_to linkage rides in
  // log_payload.in_reply_to (no new column). Best-effort: a failure here must
  // NOT fail the tool call — the announcement already succeeded.
  const mirrorMessageId = crypto.randomUUID();
  try {
    const { error: msgErr } = await supa.from('messages').insert({
      id: mirrorMessageId,
      client_message_id: crypto.randomUUID(),
      conversation_id: ctx.conversationId,
      sender_bot_id: ctx.botId,
      role: 'bot',
      content,
      status: 'done',
      ...(recip.inReplyTo
        ? { log_kind: 'crew_reply', log_payload: { in_reply_to: recip.inReplyTo } }
        : {}),
    } as never);
    if (msgErr) {
      console.warn('[post_to_crew] messages mirror insert failed', msgErr.message);
    }
  } catch (e) {
    console.warn('[post_to_crew] messages mirror insert threw', e);
  }

  // Directed mailbox fan-out for each @session / reply_to-of-a-session target
  // (Phase 2, parity with the HTTP endpoint). Member recipients (a human
  // auto-@d via reply_to) get NO mailbox. Best-effort: an enqueue failure must
  // NOT fail the tool call.
  for (const targetSessionId of recip.sessionIds) {
    const { error: enqErr } = await supa.rpc('enqueue_session_mailbox', {
      p_session_id: targetSessionId,
      p_message_kind: 'instruction',
      p_summary: content,
      p_payload: { source: recip.inReplyTo ? 'crew_reply' : 'crew_mention' },
      p_source_message_id: mirrorMessageId,
    } as never);
    if (enqErr) {
      console.warn('[post_to_crew] enqueue_session_mailbox failed', targetSessionId, enqErr.message);
    }
  }

  ctx.emit('tool_result', { name: 'post_to_crew', announcement_id: data, category });
  return JSON.stringify({
    ok: true,
    announcement_id: data,
    category: category ?? null,
  });
}
