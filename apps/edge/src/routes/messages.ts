import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { runChatTurn } from '../lib/bot-reply';
import { maybeRefreshMemory } from '../lib/memory';
import { runLookback } from '../lib/lookback-runner';
import { runTitle } from '../lib/title-runner';
import { requireBalance, InsufficientBalanceError } from '../lib/billing';
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
  // Per-conv provider pin. Tri-state on the wire:
  //   absent  → "no opinion this turn" — Worker uses conv.provider_override
  //             from the row (cross-device persistence)
  //   null    → "clear the pin" — Worker also persists null onto the row
  //   string  → set/replace pin to this slug — Worker persists onto the row
  // When non-null, passed through to LLMRouter as preferProvider for this
  // turn. Fallback retries still work; if the chosen provider 503s, router
  // falls through to other providers (the pin biases, doesn't lock).
  providerOverride: z.string().nullable().optional(),
  // IANA timezone of the client (e.g. "Asia/Shanghai" / "America/Los_Angeles").
  // Used to render the per-turn time hint we append to the user's message in
  // the LLM prompt, so the model sees the user's *local* clock — not UTC.
  clientTz: z.string().max(64).optional(),
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
    // provider_override lands in 0038; schema.ts is regenerated lazily,
    // hence the cast below where it's read.
    .select('id, conversation_type, bot_id, round_count, provider_override')
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

  // Billing gate. Skip when the conv has no bot pinned (no LLM call will
  // happen anyway — the post below early-returns at !conv.bot_id). When
  // a bot IS pinned, refuse before inserting the user row so a broke
  // account can't fill the chat with replies that never get answered.
  //
  // Groups deliberately bypass this gate: per spec the user-experience
  // must never block on balance — exhausted members are excluded from
  // the next cost split (group_member_billing.overdrawn) instead of 402.
  // group-billing.ts (M6) handles that exclusion.
  if (conv.bot_id && conv.conversation_type !== 'group') {
    try {
      await requireBalance(supaUser, userId);
    } catch (err) {
      if (err instanceof InsufficientBalanceError) {
        return c.json(
          {
            error: 'insufficient_balance',
            balance_credits: err.balance,
            min_threshold: err.threshold,
          },
          402,
        );
      }
      throw err;
    }
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

  // Group branch — bot wake decisions live in the DO router (M4) and
  // the @mention parser (M5). For now the user write is acked and
  // Realtime takes over; bots stay silent unless a downstream caller
  // (router/mention) explicitly invokes dispatchGroupTurn.
  //
  // We *could* fire-and-forget a DO signal here once M4 lands; that
  // wiring goes in then. M3's only job is to make sure groups don't
  // accidentally fall into the user_bot SSE path below (they wouldn't,
  // because conv.bot_id is NULL, but defending explicitly).
  if (conv.conversation_type === 'group') {
    return c.json({
      message: { id: parentMessageId },
      botReplyScheduled: 'async' as const,
    });
  }

  // No bot pinned (e.g. user_user, self with no bot) → just ack
  // the user write.
  if (!conv.bot_id) {
    return c.json({ message: { id: parentMessageId }, botReplyScheduled: false });
  }

  const { data: bot, error: botErr } = await supaService
    .from('bots')
    .select('id, model_id, output_mode, is_active, config, visibility, creator_id')
    .eq('id', conv.bot_id)
    .single();
  if (botErr || !bot) {
    return c.json({ error: 'bot lookup failed', detail: botErr?.message }, 500);
  }
  if (!bot.is_active) {
    return c.json({ message: { id: parentMessageId }, botReplyScheduled: false });
  }

  // Visibility gate: is_participant() lets the user keep reading the conv
  // even after the creator un-invites them, and the worker uses the
  // service role to fetch the bot — both of which would otherwise let a
  // dropped invitee keep chatting on the creator's tab. Re-check here.
  // Preset bots (creator_id === null) are system-owned and openable by
  // anyone authed; only user-owned private bots gate on creator match.
  if (
    bot.visibility === 'private' &&
    bot.creator_id !== null &&
    bot.creator_id !== userId
  ) {
    return c.json({ error: '私有机器人只允许创建者使用' }, 403);
  }
  if (bot.visibility === 'public_invite' && bot.creator_id !== userId) {
    const { data: invite } = await supaService
      .from('bot_invites')
      .select('user_id')
      .eq('bot_id', bot.id)
      .eq('user_id', userId)
      .maybeSingle();
    if (!invite) {
      return c.json({ error: '没有权限和这个机器人聊天,可能已被取消邀请' }, 403);
    }
  }

  // Resolve effective provider pin for this turn. Tri-state body field
  // (see PostBody comment): when the body carries an opinion (defined,
  // even null), persist it onto the conv row so other devices see it on
  // their next conv-list fetch. Whichever value lands here is what gets
  // passed to LLMRouter as preferProvider.
  const persistedOverride = conv.provider_override ?? null;
  let effectiveProviderOverride: string | null = persistedOverride;
  if (parsed.providerOverride !== undefined) {
    const desired = parsed.providerOverride;
    effectiveProviderOverride = desired;
    if (desired !== persistedOverride) {
      await supaService
        .from('conversations')
        .update({ provider_override: desired })
        .eq('id', parsed.conversationId);
    }
  }

  // Self-chat: load the user's profile so the bot can wear their persona.
  // The bio + display_name get prepended to the system prompt as a
  // "play this person" instruction.
  let selfPersona: { displayName: string; bio: string } | null = null;
  if (conv.conversation_type === 'self') {
    const { data: u } = await supaService
      .from('users')
      .select('display_name, bio')
      .eq('id', userId)
      .maybeSingle();
    if (u) {
      selfPersona = {
        displayName: (u.display_name as string | null) || '你',
        bio: (u.bio as string | null) || '',
      };
    }
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
          bot: {
            id: bot.id,
            model_id: bot.model_id,
            // CHECK constraint guarantees one of these two; types can't see it.
            output_mode: bot.output_mode === 'bubble' ? 'bubble' : 'single',
          },
          selfPersona,
          recentContext: parsed.recentContext ?? [],
          newMessage: parsed.newMessage ?? '（系统注入：根据上一轮的查证笔记，自然继续上面的对话。不要提到这是自动触发的。）',
          activeLookbacks: parsed.activeLookbacks ?? [],
          providerOverride: effectiveProviderOverride,
          clientTz: parsed.clientTz,
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

          // Auto-rename: round 1 replaces the random place-name fallback
          // set at conv creation; thereafter regenerate every 3 rounds so
          // long-running convs whose topic drifted get a fresher title.
          // Self convs keep their `caller_name | 我自己` title.
          const rc = updatedConv?.round_count ?? 0;
          if (
            conv.conversation_type !== 'self' &&
            (rc === 1 || (rc > 0 && rc % 3 === 0))
          ) {
            c.executionCtx.waitUntil(
              runTitle({
                env: c.env,
                conversationId: parsed.conversationId,
                botModelId: bot.model_id as string,
              }),
            );
          }
        }
      } catch (err) {
        // runChatTurn handles its own errors and emits `event: error`,
        // but anything outside it (db update, lookback scheduling, ...)
        // would otherwise close the stream silently. Emit a visible error
        // so the iOS alert says what went wrong instead of an empty body.
        const message =
          err instanceof Error
            ? err.message || err.name || 'Error'
            : (() => {
                try { return JSON.stringify(err).slice(0, 500); }
                catch { return String(err) || 'unknown error'; }
              })();
        console.error('[messages] stream error after runChatTurn:', err);
        emit('error', { message });
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
