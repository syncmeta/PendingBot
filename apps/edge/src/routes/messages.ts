import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { runChatTurn } from '../lib/bot-reply';
import { maybeRefreshMemory } from '../lib/memory';
import { runLookback } from '../lib/lookback-runner';
import { runTitle } from '../lib/title-runner';
import { requireBalance, InsufficientBalanceError } from '../lib/billing';
import { resolveGroupMentions } from '../lib/group-mentions';
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
// Client closing the connection no longer aborts the LLM — the turn keeps
// running (writing content_partial / final content to messages) so a flaky
// network or a backgrounded app can pick up where it left off via Realtime
// UPDATEs when the user re-opens the conv. Explicit stop is a separate POST
// (set messages.stop_requested) — TODO when that endpoint lands.
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

  // Attachment ownership gate. attachmentIds rides in the body uncontrolled —
  // verify each row's user_id matches the sender and (if already bound) its
  // conversation_id matches this conv, so a caller can't pin someone else's
  // upload onto their own bubble or recycle attachments across convs.
  if (parsed.attachmentIds && parsed.attachmentIds.length > 0) {
    const { data: rows, error: attErr } = await supaService
      .from('attachments')
      .select('id, user_id, conversation_id')
      .in('id', parsed.attachmentIds);
    if (attErr) return c.json({ error: 'database', detail: attErr.message }, 500);
    if (!rows || rows.length !== parsed.attachmentIds.length) {
      return c.json({ error: 'attachment not found' }, 403);
    }
    for (const r of rows) {
      if (r.user_id !== userId) {
        return c.json({ error: 'attachment not owned' }, 403);
      }
      if (r.conversation_id && r.conversation_id !== parsed.conversationId) {
        return c.json({ error: 'attachment bound to another conversation' }, 403);
      }
    }
  }

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

  // Group branch — wake decisions go to the GroupRouterDO. The DO
  // owns the 60s window + 8s debounce + per-group serialization, then
  // calls dispatchGroupTurn from its alarm handler.
  //
  // M5 layer: @-mention parsing. If the user message names a bot
  // nickname / display_name, we resolve the bot id(s) and send them
  // along with the signal — the DO bypasses debounce and dispatches
  // the mentioned bots immediately. Mentions of humans don't go to
  // the DO (they're just rendered in the bubble); only bot mentions
  // wake.
  if (conv.conversation_type === 'group') {
    if (!parsed.autoLookback) {
      const mentionedBotIds = parsed.newMessage
        ? await resolveGroupMentions(supaService, parsed.conversationId, parsed.newMessage)
        : [];

      const doId = c.env.GROUP_ROUTER.idFromName(parsed.conversationId);
      const stub = c.env.GROUP_ROUTER.get(doId);
      // Fire-and-forget — don't block the HTTP response on the DO RTT.
      c.executionCtx.waitUntil(
        stub
          .fetch('https://group-router.internal/signal', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              conversationId: parsed.conversationId,
              mentionedBotIds: mentionedBotIds.length > 0 ? mentionedBotIds : undefined,
            }),
          })
          .then((res) => {
            if (!res.ok) {
              console.warn('[messages] DO signal returned', res.status);
            }
          })
          .catch((err) => console.error('[messages] DO signal failed', err)),
      );
    }
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
  // Detached signal — passed to runChatTurn instead of c.req.raw.signal so a
  // client disconnect doesn't abort the LLM. The bot turn runs to completion
  // and Realtime UPDATEs deliver the rest when the user re-opens the conv.
  const detachedAbort = new AbortController();
  let streamClosed = false;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      const emit = (event: string, data: unknown) => {
        if (streamClosed) return;
        try {
          controller.enqueue(
            encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`),
          );
        } catch {
          /* controller may already be closed by the time we try to write */
        }
      };

      // The whole turn — LLM stream + post-turn DB updates — runs detached
      // from this response. waitUntil keeps the Worker alive past stream
      // cancel so partial UPDATEs continue to land in the DB and reach the
      // client through Realtime when they re-open the conv.
      const turnWork = (async () => {
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
            signal: detachedAbort.signal,
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
          streamClosed = true;
          try { controller.close(); } catch {}
        }
      })();
      c.executionCtx.waitUntil(turnWork);
    },
    cancel() {
      // Client closed the SSE — stop emitting. The detached turnWork keeps
      // running and persists everything via the DB; Realtime UPDATEs cover
      // the rest of the bot's reply when the user re-opens the conv.
      streamClosed = true;
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

// POST /v1/messages/start
//
// Lazy-cloud-conv first turn for a user_bot conversation. Body carries the
// botId (no convId yet) — the worker uses a SECURITY DEFINER RPC to check
// bot visibility, create the conv + participant rows, and insert the user
// message in one trip, then streams the bot reply via the same SSE format
// as /v1/messages. The first SSE frame is `event: meta` with the canonical
// conversationId + userMessageId so the client can rekey its optimistic
// local row before any token arrives.
//
// On any failure before the meta frame, the response is a JSON error and
// the client keeps the message local (no cloud conv was created). On
// failure during streaming, we emit `event: error` and the partial conv +
// user msg stay in the DB; the client can re-open the conv later to see
// what landed.
const StartBody = z.object({
  botId: z.string().uuid(),
  clientMessageId: z.string().uuid(),
  newMessage: z.string().min(1).max(64_000),
  attachmentIds: z.array(z.string().uuid()).optional(),
  recentContext: z
    .array(
      z.object({
        role: z.enum(['user', 'bot', 'human', 'log']),
        content: z.string().nullable().optional(),
        created_at: z.string(),
      }),
    )
    .max(50)
    .optional(),
  providerOverride: z.string().nullable().optional(),
  clientTz: z.string().max(64).optional(),
});

messageRoutes.post('/start', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

  let parsed: z.infer<typeof StartBody>;
  try {
    parsed = StartBody.parse(await c.req.json());
  } catch (err) {
    return c.json({ error: 'invalid body', detail: String(err) }, 400);
  }

  const supaUser = userClient(c.env, userJwt);
  const supaService = serviceClient(c.env);

  // Bot row needed for runChatTurn (model_id / output_mode / config).
  // Visibility is gated inside the SECURITY DEFINER RPC below — this read
  // just pulls the config we need to drive the turn.
  const { data: bot, error: botErr } = await supaService
    .from('bots')
    .select('id, model_id, output_mode, is_active, config, visibility, creator_id')
    .eq('id', parsed.botId)
    .single();
  if (botErr || !bot) return c.json({ error: 'bot not found' }, 404);
  if (!bot.is_active) return c.json({ error: 'bot inactive' }, 400);

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

  // Attachment ownership gate. First-turn uploads should not be bound to
  // any conv yet; reject anything that already is, and verify ownership.
  if (parsed.attachmentIds && parsed.attachmentIds.length > 0) {
    const { data: rows, error: attErr } = await supaService
      .from('attachments')
      .select('id, user_id, conversation_id')
      .in('id', parsed.attachmentIds);
    if (attErr) return c.json({ error: 'database', detail: attErr.message }, 500);
    if (!rows || rows.length !== parsed.attachmentIds.length) {
      return c.json({ error: 'attachment not found' }, 403);
    }
    for (const r of rows) {
      if (r.user_id !== userId) return c.json({ error: 'attachment not owned' }, 403);
      if (r.conversation_id) return c.json({ error: 'attachment bound to another conversation' }, 403);
    }
  }

  // Atomic conv + participants + user-msg insert. The RPC also gates bot
  // visibility (private creator match, public_invite invite check) using
  // auth.uid(), so failures come back as raised exceptions.
  //
  // Cast through `any` because schema.ts is regenerated lazily after each
  // migration — the new function may not be in the generated union yet.
  // Worker-edge tsc still catches misspelled arg names because we read the
  // returned shape below.
  const rpcResp = await (supaUser.rpc as any)('start_user_bot_turn', {
    p_bot_id: parsed.botId,
    p_client_message_id: parsed.clientMessageId,
    p_content: parsed.newMessage,
    p_attachment_ids: parsed.attachmentIds ?? null,
  });
  if (rpcResp.error) {
    const msg = rpcResp.error.message || 'start failed';
    if (/没有权限|inactive|not found|auth required/.test(msg)) {
      return c.json({ error: msg }, 403);
    }
    return c.json({ error: 'database', detail: msg }, 500);
  }
  const startInfo = rpcResp.data as { conv_id?: string; user_message_id?: string } | null;
  if (!startInfo?.conv_id || !startInfo?.user_message_id) {
    return c.json({ error: 'rpc returned malformed payload' }, 500);
  }
  const convId = startInfo.conv_id;
  const userMessageId = startInfo.user_message_id;

  let effectiveProviderOverride: string | null = null;
  if (parsed.providerOverride !== undefined) {
    effectiveProviderOverride = parsed.providerOverride;
    if (effectiveProviderOverride !== null) {
      await supaService
        .from('conversations')
        .update({ provider_override: effectiveProviderOverride })
        .eq('id', convId);
    }
  }

  const encoder = new TextEncoder();
  const detachedAbort = new AbortController();
  let streamClosed = false;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      const rawEmit = (event: string, data: unknown) => {
        if (streamClosed) return;
        try {
          controller.enqueue(
            encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`),
          );
        } catch {
          /* may already be cancelled */
        }
      };

      // Defer the `meta` frame until the bot actually produces something —
      // so a turn that errors before any LLM output never tells the client
      // about a conv id, and we can roll back the eagerly-created cloud row
      // (delete CASCADEs participants + user msg) on the way out. From the
      // user's POV: failed sends leave the optimistic bubble in pending /
      // failed state with no cloud trace; only a turn that produced at
      // least one token / bubble / tool call commits.
      let metaEmitted = false;
      const flushMeta = () => {
        if (metaEmitted) return;
        metaEmitted = true;
        rawEmit('meta', { conversationId: convId, userMessageId });
      };
      const emit = (event: string, data: unknown) => {
        if (
          !metaEmitted &&
          (event === 'token' || event === 'bubble' ||
            event === 'tool_call' || event === 'silent')
        ) {
          flushMeta();
        }
        rawEmit(event, data);
      };

      const turnWork = (async () => {
        let producedOutput = false;
        try {
          const result = await runChatTurn({
            env: c.env,
            conversationId: convId,
            userId,
            parentMessageId: userMessageId,
            bot: {
              id: bot.id,
              model_id: bot.model_id,
              output_mode: bot.output_mode === 'bubble' ? 'bubble' : 'single',
            },
            selfPersona: null,
            recentContext: parsed.recentContext ?? [],
            newMessage: parsed.newMessage,
            activeLookbacks: [],
            providerOverride: effectiveProviderOverride,
            clientTz: parsed.clientTz,
            signal: detachedAbort.signal,
            emit,
          });

          producedOutput = metaEmitted || result.bubblesInserted > 0;

          if (result.finalStatus === 'done' && result.bubblesInserted > 0) {
            await supaService
              .from('conversations')
              .update({
                round_count: 1,
                last_turn_status: 'done',
                updated_at: new Date().toISOString(),
              })
              .eq('id', convId);

            // Round 1 — kick off auto-title to replace the random place-name
            // fallback that start_user_bot_turn seeded.
            c.executionCtx.waitUntil(
              runTitle({
                env: c.env,
                conversationId: convId,
                botModelId: bot.model_id as string,
              }),
            );
          }
        } catch (err) {
          const message =
            err instanceof Error
              ? err.message || err.name || 'Error'
              : (() => {
                  try { return JSON.stringify(err).slice(0, 500); }
                  catch { return String(err) || 'unknown error'; }
                })();
          console.error('[messages/start] turn error:', err);
          rawEmit('error', { message });
        } finally {
          if (!producedOutput) {
            // Rollback: nothing the user can see ever made it out, so wipe
            // the cloud trace. CASCADE on conversations removes participants
            // and the user msg row that start_user_bot_turn inserted.
            try {
              await supaService.from('conversations').delete().eq('id', convId);
            } catch (delErr) {
              console.error('[messages/start] rollback delete failed', delErr);
            }
          }
          streamClosed = true;
          try { controller.close(); } catch {}
        }
      })();
      c.executionCtx.waitUntil(turnWork);
    },
    cancel() {
      streamClosed = true;
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
