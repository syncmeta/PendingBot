import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { runDiscuss } from '../lib/discuss-runner';
import type { AppBindings } from '../types';

export const discussRoutes = new Hono<AppBindings>();
discussRoutes.use('*', requireSession());

const StartBody = z.object({
  // Optional — provide an existing discuss conv id to continue an existing
  // group chat (next round). Omit to create a fresh one.
  conversationId: z.string().uuid().optional(),
  topic: z.string().min(1).max(8_000),
  botIds: z.array(z.string().uuid()).min(2).max(8),
  title: z.string().max(200).optional(),
});

// POST /v1/discuss/start
//
// Run one round: every selected bot speaks at most once. Re-call to run
// another round. The user is added as `observer` (read-only at the participant
// level — RLS on messages denies their direct INSERT for role='bot' anyway,
// but observer makes the social shape explicit).
discussRoutes.post('/start', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

  let parsed: z.infer<typeof StartBody>;
  try {
    parsed = StartBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  // Visibility gate: discuss takes raw bot_ids from the request, so we
  // must verify each bot is actually visible to the caller — otherwise
  // someone could discuss with a private bot of another user, or with a
  // public_invite bot they were never invited to. SELECT through the
  // user JWT so RLS does the filtering for us.
  {
    const supaUserCheck = userClient(c.env, userJwt);
    const { data: visibleBots, error: visibleErr } = await supaUserCheck
      .from('bots')
      .select('id')
      .in('id', parsed.botIds);
    if (visibleErr) {
      return c.json({ error: 'database', detail: visibleErr.message }, 500);
    }
    const visibleSet = new Set((visibleBots ?? []).map((r) => r.id as string));
    const missing = parsed.botIds.filter((id) => !visibleSet.has(id));
    if (missing.length > 0) {
      return c.json({ error: '没有权限使用其中部分机器人', missing }, 403);
    }
  }

  const supa = serviceClient(c.env);
  let conversationId = parsed.conversationId;

  if (conversationId) {
    // Continuing — gate ownership via RLS read.
    const supaUser = userClient(c.env, userJwt);
    const { data: conv, error } = await supaUser
      .from('conversations')
      .select('id, conversation_type')
      .eq('id', conversationId)
      .maybeSingle();
    if (error) return c.json({ error: 'database', detail: error.message }, 500);
    if (!conv) return c.json({ error: 'conversation not found or no access' }, 404);
    if (conv.conversation_type !== 'discuss') {
      return c.json({ error: 'conversation is not a discuss conv' }, 400);
    }
  } else {
    // Fresh discuss conv. bot_id is null (multi-bot); participants enumerate.
    const { data: conv, error: convErr } = await supa
      .from('conversations')
      .insert({
        conversation_type: 'discuss',
        feature: 'discuss',
        user_id: userId,
        title: parsed.title ?? '议论',
      })
      .select('id')
      .single();
    if (convErr || !conv) {
      return c.json({ error: 'database', detail: convErr?.message ?? 'insert failed' }, 500);
    }
    conversationId = conv.id as string;

    const participants = [
      {
        conversation_id: conversationId,
        participant_type: 'user' as const,
        participant_id: userId,
        role: 'observer' as const,
      },
      ...parsed.botIds.map((botId) => ({
        conversation_id: conversationId!,
        participant_type: 'bot' as const,
        participant_id: botId,
        role: 'member' as const,
      })),
    ];
    const { error: pErr } = await supa
      .from('conversation_participants')
      .insert(participants);
    if (pErr) {
      return c.json({ error: 'database', detail: pErr.message }, 500);
    }
  }

  // Record the topic as a user message in the discuss conv so the timeline
  // starts with the question. Only for fresh convs — continuing rounds
  // don't re-post the topic.
  if (!parsed.conversationId) {
    await supa.from('messages').insert({
      client_message_id: crypto.randomUUID(),
      conversation_id: conversationId,
      user_id: userId,
      role: 'user',
      status: 'done',
      content: parsed.topic,
    });
  }

  c.executionCtx.waitUntil(
    runDiscuss({
      env: c.env,
      conversationId,
      userId,
      topic: parsed.topic,
      botIds: parsed.botIds,
    }),
  );

  return c.json({ conversationId }, 202);
});

// POST /v1/discuss/:id/cancel — flip last_turn_status='cancelled'. The
// runner reads it at the top of every bot iteration and bails before the
// next LLM call. Latency between signal and stop is bounded by the
// currently-running bot's LLM call (no mid-call abort — we let the in-flight
// bot finish; cancel kicks in before the *next* one).
discussRoutes.post('/:id/cancel', async (c) => {
  const id = c.req.param('id');
  const userJwt = c.var.userJwt!;
  // RLS-gate via user client (caller must be a participant).
  const supa = userClient(c.env, userJwt);
  const { error } = await supa
    .from('conversations')
    .update({ last_turn_status: 'cancelled' })
    .eq('id', id);
  if (error) return c.json({ error: 'database', detail: error.message }, 500);
  return c.json({ ok: true });
});
