import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { runChatTurn } from '../lib/bot-reply';
import { maybeRefreshMemory } from '../lib/memory';
import type { AppBindings } from '../types';

export const messageRoutes = new Hono<AppBindings>();
messageRoutes.use('*', requireSession());

const PostBody = z.object({
  conversationId: z.string().uuid(),
  clientMessageId: z.string().uuid(),         // UUID v7 from client (idempotency key)
  newMessage: z.string().min(1).max(64_000),
  attachmentIds: z.array(z.string().uuid()).optional(),
  // Recent history from the client's local cache (typically last 20 msgs).
  recentContext: z
    .array(
      z.object({
        role: z.enum(['user', 'bot', 'human', 'log']),
        content: z.string().nullable().optional(),
        created_at: z.string(), // ISO 8601 with timezone
      }),
    )
    .max(50)
    .optional(),
  // Oldest message id in the client's local context window. Used to
  // trigger lazy Honcho refresh when client window has moved past the
  // current memory's coverage. See plan/02 "刷新机制 (lazy)".
  oldestContextMessageId: z.string().uuid().optional(),
});

// POST /v1/messages
//
// Returns text/event-stream. SSE events:
//   event: typing       data: { state: 'thinking' }
//   event: token        data: { delta: '...' }
//   event: bubble       data: { id, index, bubble_group_id, content }
//   event: done         data: { bubble_group_id, total_content }
//   event: interrupted  data: { bubble_group_id, total_content }
//   event: error        data: { message }
//
// Client closes the connection to interrupt — Worker's request.signal fires
// and the LLM upstream is aborted.
messageRoutes.post('/', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

  let parsed: z.infer<typeof PostBody>;
  try {
    parsed = PostBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  // RLS-gate: user must be a participant of the conversation. We use the
  // user JWT for the read so the gate is RLS-driven, not Worker-trusted.
  const supaUser = userClient(c.env, userJwt);
  const { data: conv, error: convErr } = await supaUser
    .from('conversations')
    .select('id, conversation_type, bot_id')
    .eq('id', parsed.conversationId)
    .maybeSingle();
  if (convErr) return c.json({ error: 'database', detail: convErr.message }, 500);
  if (!conv) return c.json({ error: 'conversation not found or no access' }, 404);

  // Insert the user's message synchronously (idempotent). We do this BEFORE
  // opening the SSE stream so failures here come back as a normal JSON 500
  // rather than an event-stream error frame.
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

  const { data: userRow, error: selectErr } = await supaService
    .from('messages')
    .select('id')
    .eq('client_message_id', parsed.clientMessageId)
    .single();
  if (selectErr || !userRow) {
    return c.json({ error: 'database', detail: selectErr?.message ?? 'row missing' }, 500);
  }
  const parentMessageId = userRow.id as string;

  // No bot pinned (e.g. user_user, group with no default bot) → just ack
  // the user write. Group/discuss have their own routes for the bot turn.
  if (!conv.bot_id) {
    return c.json({ message: { id: parentMessageId }, botReplyScheduled: false });
  }

  const { data: bot, error: botErr } = await supaService
    .from('bots')
    .select('id, model_id, output_mode, is_active')
    .eq('id', conv.bot_id)
    .single();
  if (botErr || !bot) {
    return c.json({ error: 'bot lookup failed', detail: botErr?.message }, 500);
  }
  if (!bot.is_active) {
    return c.json({ message: { id: parentMessageId }, botReplyScheduled: false });
  }

  // Lazy Honcho refresh: if the client's window has moved past memory's
  // coverage, kick off a background catch-up. Doesn't block the SSE stream
  // (waitUntil keeps it running past Response close).
  if (parsed.oldestContextMessageId) {
    c.executionCtx.waitUntil(
      maybeRefreshMemory({
        env: c.env,
        userId,
        botId: bot.id,
        conversationId: parsed.conversationId,
        oldestContextMessageId: parsed.oldestContextMessageId,
      }),
    );
  }

  // Open SSE stream. Each ReadableStream chunk is one fully-formed
  // `event: NAME\ndata: JSON\n\n` block.
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      let closed = false;
      const emit = (event: string, data: unknown) => {
        if (closed) return;
        try {
          controller.enqueue(
            encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`),
          );
        } catch {
          /* controller may already be closed by the time we try to write */
        }
      };

      try {
        await runChatTurn({
          env: c.env,
          conversationId: parsed.conversationId,
          userId,
          parentMessageId,
          bot: { id: bot.id, model_id: bot.model_id, output_mode: bot.output_mode },
          recentContext: parsed.recentContext ?? [],
          newMessage: parsed.newMessage,
          signal: c.req.raw.signal,
          emit,
        });
      } finally {
        closed = true;
        try { controller.close(); } catch {}
      }
    },
    cancel() {
      // Caller closed the stream — nothing to do; runChatTurn observes the
      // same signal via signal.addEventListener('abort').
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      'X-Accel-Buffering': 'no',
    },
  });
});
