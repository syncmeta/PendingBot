import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
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
// B0/B1.5 STUB: the LLM call + streaming wiring lands in B5/B7. Today this
// handler:
//   - validates the user is a conversation_participants member (via RLS read)
//   - inserts the user's message via service role (idempotent on client_message_id)
//   - returns the inserted row
//
// The Realtime push is automatic — pendingbot.messages is in the publication,
// so any client with a `conv:${id}` channel sees the INSERT immediately. This
// is the link we want to verify end-to-end before B5 lands the LLM half.
messageRoutes.post('/', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

  let parsed: z.infer<typeof PostBody>;
  try {
    parsed = PostBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  // Verify the user is a participant. We use the user JWT for the read so
  // RLS is the gate — failure means "no row visible" not a 403, but the
  // effect is the same: not allowed.
  const supaUser = userClient(c.env, userJwt);
  const { data: conv, error: convErr } = await supaUser
    .from('conversations')
    .select('id, conversation_type, bot_id')
    .eq('id', parsed.conversationId)
    .maybeSingle();
  if (convErr) {
    return c.json({ error: 'database', detail: convErr.message }, 500);
  }
  if (!conv) {
    return c.json({ error: 'conversation not found or no access' }, 404);
  }

  // INSERT user's message. ON CONFLICT (client_message_id) DO NOTHING handles
  // retries from a flaky client. We then SELECT-back to get the canonical row
  // (whether ours or a prior one with the same client_message_id).
  const supaService = serviceClient(c.env);
  const { error: insertErr } = await supaService
    .schema('pendingbot')
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
  if (insertErr) {
    return c.json({ error: 'database', detail: insertErr.message }, 500);
  }

  // Read back the canonical row for response shape consistency.
  const { data: row, error: selectErr } = await supaService
    .schema('pendingbot')
    .from('messages')
    .select('id, client_message_id, conversation_id, user_id, role, content, status, created_at')
    .eq('client_message_id', parsed.clientMessageId)
    .single();
  if (selectErr || !row) {
    return c.json({ error: 'database', detail: selectErr?.message ?? 'row missing' }, 500);
  }

  // TODO(B5/B7): kick off LLM call here:
  //   ctx.waitUntil(generateBotReply({ env: c.env, conv, userJwt, row, recentContext: parsed.recentContext }))
  // For now we just acknowledge the user's write — the bot reply path is wired
  // in when streaming + Realtime push is fully tested.

  return c.json({ message: row, botReplyScheduled: false });
});

// POST /v1/messages/:id/stop — request the streaming bot reply for this turn
// to halt at the next safe boundary. See plans/.../03-streaming-interrupt.md.
messageRoutes.post('/:id/stop', async (c) => {
  const id = c.req.param('id');
  const supa = serviceClient(c.env);
  const { error } = await supa
    .schema('pendingbot')
    .from('messages')
    .update({ stop_requested: true })
    .eq('id', id)
    .eq('role', 'bot');
  if (error) return c.json({ error: 'database', detail: error.message }, 500);
  return c.json({ ok: true });
});
