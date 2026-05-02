import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { runChatTurn } from '../lib/bot-reply';
import { maybeRefreshMemory } from '../lib/memory';
import { runLookback } from '../lib/lookback-runner';
import type { AppBindings } from '../types';

export const messageRoutes = new Hono<AppBindings>();
messageRoutes.use('*', requireSession());

const PostBody = z.object({
  conversationId: z.string().uuid(),
  clientMessageId: z.string().uuid(),         // UUID v7 from client (idempotency key)
  // newMessage is optional ONLY when autoLookback is true (the client is
  // auto-firing because a lookback note arrived and 30s of silence passed).
  newMessage: z.string().min(1).max(64_000).optional(),
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
  oldestContextMessageId: z.string().uuid().optional(),
  // Lookback notes the client has cached (received via Realtime). Each
  // active note is fed into the bot's prompt as a private context block.
  // The bot may emit [DROP_LOOKBACK] in its reply to flag them as no
  // longer needed; the runner strips the marker before bubbling and
  // updates active=false on the rows below.
  activeLookbacks: z
    .array(z.object({ id: z.string().uuid(), body_md: z.string() }))
    .max(10)
    .optional(),
  // Set when this POST is the client's auto-fire after a lookback note
  // arrived and 30s of user silence passed. Worker will:
  //   - skip the user message INSERT (no real user input)
  //   - reuse the recentContext as-is to drive the bot turn
  // Result: the bot replies "as if" the user just sent something, with
  // the lookback note in scope.
  autoLookback: z.boolean().optional(),
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
    .select('id, conversation_type, bot_id, round_count')
    .eq('id', parsed.conversationId)
    .maybeSingle();
  if (convErr) return c.json({ error: 'database', detail: convErr.message }, 500);
  if (!conv) return c.json({ error: 'conversation not found or no access' }, 404);

  // Body shape varies by mode:
  //   normal     newMessage required, INSERT user row, parent = that row
  //   autoLookback newMessage absent, no user row written, parent = last
  //                user row in conv (best effort) or null
  if (!parsed.autoLookback && !parsed.newMessage) {
    return c.json({ error: 'newMessage required' }, 400);
  }

  const supaService = serviceClient(c.env);
  let parentMessageId: string | null = null;
  if (!parsed.autoLookback) {
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
    parentMessageId = userRow.id as string;
  } else {
    // autoLookback: anchor parent to the last user row in this conv so the
    // bot reply still has something sensible to point at if anyone queries.
    const { data: lastUser } = await supaService
      .from('messages')
      .select('id')
      .eq('conversation_id', parsed.conversationId)
      .eq('role', 'user')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    parentMessageId = (lastUser?.id as string | undefined) ?? null;
  }

  // No bot pinned (e.g. user_user, group with no default bot) → just ack
  // the user write. Group/discuss have their own routes for the bot turn.
  if (!conv.bot_id) {
    return c.json({ message: { id: parentMessageId }, botReplyScheduled: false });
  }

  const { data: bot, error: botErr } = await supaService
    .from('bots')
    .select('id, model_id, output_mode, is_active, config')
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
        const result = await runChatTurn({
          env: c.env,
          conversationId: parsed.conversationId,
          userId,
          parentMessageId: parentMessageId ?? '',
          bot: { id: bot.id, model_id: bot.model_id, output_mode: bot.output_mode },
          recentContext: parsed.recentContext ?? [],
          newMessage: parsed.newMessage ?? '（系统注入：根据上一轮的查证笔记，自然继续上面的对话。不要提到这是自动触发的。）',
          activeLookbacks: parsed.activeLookbacks ?? [],
          signal: c.req.raw.signal,
          emit,
        });

        if (result.finalStatus === 'done' && result.bubblesInserted > 0) {
          const { data: updatedConv } = await supaService
            .from('conversations')
            .update({
              round_count: (conv.round_count ?? 0) + 1,
              last_turn_status: 'done',
              updated_at: new Date().toISOString(),
            })
            .eq('id', parsed.conversationId)
            .select('round_count')
            .single();

          // If the bot opted to drop the lookbacks (emitted [DROP_LOOKBACK]),
          // mark them inactive. runChatTurn returned the ids it dropped.
          if (result.droppedLookbackIds.length > 0) {
            await supaService
              .from('bot_lookbacks')
              .update({ active: false, updated_at: new Date().toISOString() })
              .in('id', result.droppedLookbackIds);
          }

          // Per-bot opt-in lookback cadence; defaults below mirror the old
          // auto-review knobs (every 10 rounds).
          maybeAutoLookback({
            env: c.env,
            ctx: c.executionCtx,
            conversationId: parsed.conversationId,
            botId: bot.id,
            botConfig: bot.config as LookbackConfigEnvelope | null,
            roundCount: updatedConv?.round_count ?? 0,
          });
        }
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

// Per-bot lookback config. Lives in `bots.config` jsonb. Defaults:
// enabled, every 10 rounds.
interface LookbackConfigEnvelope {
  lookback?: { enabled?: boolean; roundInterval?: number };
}

function maybeAutoLookback(input: {
  env: AppBindings['Bindings'];
  ctx: ExecutionContext;
  conversationId: string;
  botId: string;
  botConfig: LookbackConfigEnvelope | null;
  roundCount: number;
}) {
  const cfg = input.botConfig?.lookback ?? {};
  if (cfg.enabled === false) return;
  const interval = Math.max(1, cfg.roundInterval ?? 10);
  if (input.roundCount === 0) return;
  if (input.roundCount % interval !== 0) return;

  input.ctx.waitUntil(
    runLookback({
      env: input.env,
      conversationId: input.conversationId,
      botId: input.botId,
    }),
  );
}
