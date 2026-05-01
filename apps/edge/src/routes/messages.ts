import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { generateBotReply } from '../lib/bot-reply';
import type { AppBindings } from '../types';

export const messageRoutes = new Hono<AppBindings>();

messageRoutes.use('*', requireSession());

// POST body schema. recentContext is the client's local cache of the last N
// messages (see plans/.../02-prompt-and-llm.md "客户端 POST 自带历史"). Worker
// uses this to assemble the LLM prompt without round-tripping Supabase.
const PostBody = z.object({
  conversationId: z.string().uuid(),
  clientMessageId: z.string().uuid(),         // UUID v7 from client (idempotency key)
  newMessage: z.string().min(1).max(64_000),
  attachmentIds: z.array(z.string().uuid()).optional(),
  recentContext: z
    .array(
      z.object({
        role: z.enum(['user', 'bot', 'human', 'log']),
        content: z.string().nullable().optional(),
        created_at: z.string(),               // ISO 8601 with timezone
      }),
    )
    .max(50)
    .optional(),
});

// POST /v1/messages
//
// 1. RLS-gate the user's membership in the conversation (read via user JWT).
// 2. Idempotently insert the user's message via service role.
// 3. Schedule the bot reply on `ctx.waitUntil`. The streaming runner inserts
//    its own bot row + flushes content_partial via Realtime — clients see
//    tokens by subscribing to the conv channel, no SSE on this endpoint.
messageRoutes.post('/', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

  let parsed: z.infer<typeof PostBody>;
  try {
    parsed = PostBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  const supaUser = userClient(c.env, userJwt);
  const { data: conv, error: convErr } = await supaUser
    .from('conversations')
    .select('id, conversation_type, bot_id')
    .eq('id', parsed.conversationId)
    .maybeSingle();
  if (convErr) return c.json({ error: 'database', detail: convErr.message }, 500);
  if (!conv) return c.json({ error: 'conversation not found or no access' }, 404);

  const supaService = serviceClient(c.env);
  const { error: insertErr } = await supaService
    .from('messages')
    .upsert(
      {
        client_message_id: parsed.clientMessageId,
        conversation_id: parsed.conversationId,
        user_id: userId,
        role: 'user',
        content: parsed.newMessage,
        status: 'done',
        attachments: parsed.attachmentIds ? { ids: parsed.attachmentIds } : null,
      },
      { onConflict: 'client_message_id', ignoreDuplicates: true },
    );
  if (insertErr) return c.json({ error: 'database', detail: insertErr.message }, 500);

  const { data: row, error: selectErr } = await supaService
    .from('messages')
    .select('id, client_message_id, conversation_id, user_id, role, content, status, created_at')
    .eq('client_message_id', parsed.clientMessageId)
    .single();
  if (selectErr || !row) {
    return c.json({ error: 'database', detail: selectErr?.message ?? 'row missing' }, 500);
  }

  // Schedule bot reply only if the conv has a pinned bot. user_user / group
  // conversations without a default bot don't auto-reply (group + discuss
  // dispatch lands in their own routes).
  let botReplyScheduled = false;
  if (conv.bot_id) {
    const { data: bot, error: botErr } = await supaService
      .from('bots')
      .select('id, model_id, output_mode, is_active')
      .eq('id', conv.bot_id)
      .single();
    if (botErr || !bot) {
      console.error('[messages] bot lookup failed', botErr);
    } else if (bot.is_active) {
      c.executionCtx.waitUntil(
        generateBotReply({
          env: c.env,
          conversationId: parsed.conversationId,
          parentMessageId: row.id as string,
          userId,
          bot: { id: bot.id, model_id: bot.model_id, output_mode: bot.output_mode },
          recentContext: parsed.recentContext ?? [],
          newMessage: parsed.newMessage,
        }),
      );
      botReplyScheduled = true;
    }
  }

  return c.json({ message: row, botReplyScheduled });
});

// POST /v1/messages/:id/stop — request the streaming bot reply for this turn
// to halt at the next safe boundary. See plans/.../03-streaming-interrupt.md.
messageRoutes.post('/:id/stop', async (c) => {
  const id = c.req.param('id');
  const supa = serviceClient(c.env);
  const { error } = await supa
    .from('messages')
    .update({ stop_requested: true })
    .eq('id', id)
    .eq('role', 'bot');
  if (error) return c.json({ error: 'database', detail: error.message }, 500);
  return c.json({ ok: true });
});
