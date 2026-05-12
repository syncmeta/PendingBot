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
import { summarizeAttachments, DEFAULT_VISION_MODEL } from '../llm/vision';
import { UUID_RE } from '../lib/ids';
import { jsonError } from '../lib/http-error';
import { deleteCachedAttachment, removeInventoryIds, resolveAttachmentOwnership } from '../lib/attachment-cache';
import { safeWaitUntil } from '../lib/safe-wait-until';
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
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  // Body shape varies by mode:
  //   normal     newMessage required, INSERT user row, parent = that row
  //   autoLookback newMessage absent, no user row written, parent = last
  //                user row in conv (best effort) or null
  if (!parsed.autoLookback && !parsed.newMessage) {
    return jsonError(c, 400, 'invalid_body', { message: 'newMessage required' });
  }

  const supaUser = userClient(c.env, userJwt);
  const supaService = serviceClient(c.env);

  // Phase 1 — fire conv lookup (RLS gate + routing/config) and attachment
  // ownership check in parallel. Both must succeed before any state
  // change. The conv read uses the user JWT so RLS confirms membership;
  // the attachment check reads from the per-attachment KV cache and only
  // falls back to Supabase on miss (cold attachments — older uploads not
  // yet warmed).
  const convPromise = supaUser
    .from('conversations')
    .select('id, conversation_type, bot_id, round_count, provider_override, model_slug_override, vision_model_override')
    .eq('id', parsed.conversationId)
    .maybeSingle();

  const hasAttachments = (parsed.attachmentIds?.length ?? 0) > 0;
  const attCheckPromise = hasAttachments
    ? resolveAttachmentOwnership(c.env, supaService, parsed.attachmentIds!, (p) =>
        safeWaitUntil(c, p),
      )
    : Promise.resolve([] as Array<{ id: string; user_id: string; conversation_id: string | null }>);

  const [convRes, attRows] = await Promise.all([convPromise, attCheckPromise]);

  if (convRes.error) return jsonError(c, 500, 'database_error', { detail: convRes.error.message });
  // Narrow the conversation_type literal — schema.ts types it as the full
  // set the CHECK constraint allows; this route only handles the message
  // surface, so we treat the others (discuss/surf/portrait) the same as
  // user_bot for routing purposes.
  const conv = convRes.data as {
    id: string;
    conversation_type: 'user_bot' | 'self' | 'group' | 'user_user';
    bot_id: string | null;
    round_count: number | null;
    provider_override: string | null;
    model_slug_override: string | null;
    vision_model_override: string | null;
  } | null;
  if (!conv) return jsonError(c, 404, 'conversation_no_access');

  // Attachment ownership gate. attachmentIds rides in the body uncontrolled —
  // verify each row's user_id matches the sender and (if already bound) its
  // conversation_id matches this conv, so a caller can't pin someone else's
  // upload onto their own bubble or recycle attachments across convs.
  if (hasAttachments) {
    if (!attRows) {
      return jsonError(c, 403, 'attachment_not_found');
    }
    for (const r of attRows) {
      if (r.user_id !== userId) {
        return jsonError(c, 403, 'attachment_not_owned');
      }
      if (r.conversation_id && r.conversation_id !== parsed.conversationId) {
        return jsonError(c, 403, 'attachment_conversation_mismatch');
      }
    }
  }

  // Pre-generate the user message id so we can return it to the client
  // and reference it as parent_message_id without waiting for the INSERT
  // to land. The actual write fires through waitUntil below — idempotent
  // on client_message_id, so a retry collapses server-side.
  const needsBotPath = conv.bot_id !== null && conv.conversation_type !== 'group';
  const userMessageId = !parsed.autoLookback ? crypto.randomUUID() : null;

  // Phase 2 — fire balance gate, bot lookup, autoLookback parent lookup
  // in parallel. INSERT runs detached (waitUntil) using the
  // pre-generated id, so the pre-stream path holds no write RTT.
  const balancePromise: Promise<InsufficientBalanceError | null> = needsBotPath
    ? requireBalance(c.env, supaUser, userId)
        .then(() => null)
        .catch((err) => {
          if (err instanceof InsufficientBalanceError) return err;
          throw err;
        })
    : Promise.resolve(null);

  const botPromise = needsBotPath
    ? supaService
        .from('bots')
        .select('id, model_id, output_mode, is_active, config, visibility, creator_id')
        .eq('id', conv.bot_id!)
        .single()
    : Promise.resolve(null);

  const parentLookupPromise: Promise<string | null> = parsed.autoLookback
    ? (async () => {
        const { data } = await supaService
          .from('messages')
          .select('id')
          .eq('conversation_id', parsed.conversationId)
          .eq('role', 'user')
          .order('created_at', { ascending: false })
          .limit(1)
          .maybeSingle();
        return (data?.id as string | undefined) ?? null;
      })()
    : Promise.resolve(userMessageId);

  // Detached user-message INSERT. Idempotent on client_message_id, so a
  // client retry de-dupes. Errors go to console.error — operations can
  // chase, but the user gets a 200 OK either way (Realtime will reflect
  // the row once it lands; if it never does, the client's next send
  // with the same client_message_id triggers the same upsert).
  if (!parsed.autoLookback && userMessageId) {
    c.executionCtx.waitUntil(
      (async () => {
        const { error } = await supaService
          .from('messages')
          .upsert(
            {
              id: userMessageId,
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
        if (error) console.error('[messages] user upsert failed', error.message);
      })(),
    );

    // Attachment summarization runs independently of the bot reply path
    // so groups / no-bot convs / user_user also get image summaries.
    if (hasAttachments) {
      c.executionCtx.waitUntil(
        scheduleAttachmentSummary({
          env: c.env,
          conversationId: parsed.conversationId,
          userId,
          attachmentIds: parsed.attachmentIds!,
          botId: conv.bot_id ?? null,
          visionOverride: conv.vision_model_override ?? null,
        }),
      );
    }
  }

  const [balanceErr, botRes, parentMessageId] = await Promise.all([
    balancePromise,
    botPromise,
    parentLookupPromise,
  ]);

  if (balanceErr) {
    return c.json(
      {
        error: 'insufficient_balance',
        balance_credits: balanceErr.balance,
        min_threshold: balanceErr.threshold,
      },
      402,
    );
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

  // botRes was awaited in Phase 2 (needsBotPath was true). Narrow + check.
  if (!botRes || botRes.error || !botRes.data) {
    return jsonError(c, 500, 'database_error', { message: 'bot lookup failed', detail: botRes?.error?.message });
  }
  const bot = botRes.data;
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
    return jsonError(c, 403, 'forbidden', { message: '私有机器人只允许创建者使用' });
  }
  if (bot.visibility === 'public_invite' && bot.creator_id !== userId) {
    const { data: invite } = await supaService
      .from('bot_invites')
      .select('user_id')
      .eq('bot_id', bot.id)
      .eq('user_id', userId)
      .maybeSingle();
    if (!invite) {
      return jsonError(c, 403, 'forbidden', { message: '没有权限和这个机器人聊天,可能已被取消邀请' });
    }
  }

  // Resolve effective provider pin for this turn. Tri-state body field
  // (see PostBody comment): when the body carries an opinion (defined,
  // even null), persist it onto the conv row so other devices see it on
  // their next conv-list fetch. Whichever value lands here is what gets
  // passed to LLMRouter as preferProvider. Persistence is fire-and-forget
  // so the SSE stream doesn't wait on it.
  const persistedOverride = conv.provider_override ?? null;
  let effectiveProviderOverride: string | null = persistedOverride;
  if (parsed.providerOverride !== undefined) {
    const desired = parsed.providerOverride;
    effectiveProviderOverride = desired;
    if (desired !== persistedOverride) {
      c.executionCtx.waitUntil(
        (async () => {
          const { error } = await supaService
            .from('conversations')
            .update({ provider_override: desired })
            .eq('id', parsed.conversationId);
          if (error) console.error('[messages] provider_override persist failed', error.message);
        })(),
      );
    }
  }

  // Per-conv model pin. NULL → fall back to bot.model_id. Set via
  // PATCH /v1/conversations/:id (only on convs whose bot is private and
  // owned by the user).
  const effectiveModelId: string =
    conv.model_slug_override && conv.model_slug_override.length > 0
      ? conv.model_slug_override
      : (bot.model_id as string);

  const isSelfChat = conv.conversation_type === 'self';

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
              model_id: effectiveModelId,
              // CHECK constraint guarantees one of these two; types can't see it.
              output_mode: bot.output_mode === 'bubble' ? 'bubble' : 'single',
            },
            isSelfChat,
            recentContext: parsed.recentContext ?? [],
            newMessage: parsed.newMessage ?? '（系统注入：根据上一轮的查证笔记，自然继续上面的对话。不要提到这是自动触发的。）',
            currentAttachmentIds: parsed.attachmentIds,
            visionModelOverride: conv.vision_model_override,
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
                  botModelId: effectiveModelId,
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
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
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
  if (botErr || !bot) return jsonError(c, 404, 'not_found', { message: 'bot not found' });
  if (!bot.is_active) return jsonError(c, 400, 'forbidden', { message: 'bot inactive' });

  try {
    await requireBalance(c.env, supaUser, userId);
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
    if (attErr) return jsonError(c, 500, 'database_error', { detail: attErr.message });
    if (!rows || rows.length !== parsed.attachmentIds.length) {
      return jsonError(c, 403, 'attachment_not_found');
    }
    for (const r of rows) {
      if (r.user_id !== userId) return jsonError(c, 403, 'attachment_not_owned');
      if (r.conversation_id) return jsonError(c, 403, 'attachment_conversation_mismatch');
    }
  }

  // Atomic conv + participants + user-msg insert. The RPC also gates bot
  // visibility (private creator match, public_invite invite check) using
  // auth.uid(), so failures come back as raised exceptions.
  const rpcResp = await supaUser.rpc('start_user_bot_turn', {
    p_bot_id: parsed.botId,
    p_client_message_id: parsed.clientMessageId,
    p_content: parsed.newMessage,
    p_attachment_ids: parsed.attachmentIds,
  });
  if (rpcResp.error) {
    const msg = rpcResp.error.message || 'start failed';
    if (/没有权限|inactive|not found|auth required/.test(msg)) {
      return jsonError(c, 403, 'forbidden', { message: msg });
    }
    return jsonError(c, 500, 'database_error', { detail: msg });
  }
  const startInfo = rpcResp.data as { conv_id?: string; user_message_id?: string } | null;
  if (!startInfo?.conv_id || !startInfo?.user_message_id) {
    return jsonError(c, 500, 'internal_error', { message: 'rpc returned malformed payload' });
  }
  const convId = startInfo.conv_id;
  const userMessageId = startInfo.user_message_id;

  // Detached attachment summarization for the just-created conv. New convs
  // can't have vision_model_override set yet (form doesn't expose it on
  // first turn), so we pass null — scheduleAttachmentSummary falls back to
  // bot.model_id-vs-vision check, then DEFAULT_VISION_MODEL.
  if (parsed.attachmentIds && parsed.attachmentIds.length > 0) {
    c.executionCtx.waitUntil(
      scheduleAttachmentSummary({
        env: c.env,
        conversationId: convId,
        userId,
        attachmentIds: parsed.attachmentIds,
        botId: bot.id,
        visionOverride: null,
      }),
    );
  }

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
            isSelfChat: false,
            recentContext: parsed.recentContext ?? [],
            newMessage: parsed.newMessage,
            currentAttachmentIds: parsed.attachmentIds,
            // Brand-new conv from /start — no override possible yet.
            visionModelOverride: null,
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

// POST /v1/messages/:id/recall
//
// Sender-initiated recall. Two modes, picked by conversation_type:
//
//   • user_user (human ↔ human) — soft-delete the original (status='deleted',
//     blank content/attachments) and INSERT a log row marking the recall
//     so peers see "我撤回了 X 的一条消息" in their conversation. Mirrors
//     the WeChat UX, with no time limit per product spec.
//
//   • user_bot / group / self — soft-delete the original and PURGE its
//     attachments (DB rows + R2 objects) so quota / storage are
//     reclaimed and the bot's future context can no longer see them.
//     No tombstone log row — the message just disappears from view.
//
// LLM context queries filter on `.neq('status', 'deleted')` so the model
// never sees the original message after recall, regardless of mode.
//
// Allowed only when caller authored the message. (Conversation-owner
// deletion of arbitrary messages is the separate DELETE /:id below.)
messageRoutes.post('/:id/recall', async (c) => {
  const userId = c.var.userId!;
  const id = c.req.param('id');
  if (!UUID_RE.test(id)) {
    return jsonError(c, 400, 'invalid_id');
  }

  const supa = serviceClient(c.env);

  const { data: msg, error: fetchErr } = await supa
    .schema('pendingbot')
    .from('messages')
    .select('id, user_id, sender_bot_id, conversation_id, status, attachments, created_at')
    .eq('id', id)
    .maybeSingle();
  if (fetchErr) return jsonError(c, 500, 'database_error', { detail: fetchErr.message });
  if (!msg) return jsonError(c, 404, 'not_found');

  // Only the original sender may recall. Bot rows have user_id=null /
  // sender_bot_id set; they cannot be recalled by anyone via this path.
  if (msg.user_id !== userId) return jsonError(c, 403, 'forbidden');

  // Idempotent: already recalled → ok.
  if (msg.status === 'deleted') return c.json({ ok: true, already: true });

  const { data: conv, error: convErr } = await supa
    .schema('pendingbot')
    .from('conversations')
    .select('conversation_type')
    .eq('id', msg.conversation_id)
    .maybeSingle();
  if (convErr) return jsonError(c, 500, 'database_error', { detail: convErr.message });
  const convType = (conv as { conversation_type?: string } | null)?.conversation_type ?? 'user_bot';

  // Collect attachment ids before we clear the column so we can purge
  // them after. Shape: attachments = { ids: [uuid, ...] }
  const attIds: string[] = (() => {
    const a = msg.attachments as { ids?: unknown } | null;
    if (!a || !Array.isArray(a.ids)) return [];
    return a.ids.filter((x): x is string => typeof x === 'string');
  })();

  // 1) Soft-delete the original. Clearing content + attachments makes
  //    the row useless for both display and any backfill query.
  const { error: updErr } = await supa
    .schema('pendingbot')
    .from('messages')
    .update({
      status: 'deleted',
      content: null,
      content_partial: null,
      attachments: null,
    })
    .eq('id', id);
  if (updErr) return jsonError(c, 500, 'database_error', { detail: updErr.message });

  // 2) Purge attachment rows + R2 objects.
  //
  //    Per-row safety: an R2 object's lifetime is "as long as ANY
  //    attachments row still references it via r2_key". With the
  //    dedup work in migration 20260512052048 a single user upload
  //    of the same bytes already collapses to one row, but a
  //    cross-user upload (different users uploading the same image)
  //    still produces two rows with the same r2_key. Delete the R2
  //    object only when this user's row was the last one pointing
  //    at it — otherwise we'd 404 the other user's view.
  //
  //    Done unconditionally — even in user_user the original
  //    message's images shouldn't survive a recall. Failures are
  //    logged but don't roll back the recall itself; the daily R2
  //    orphan-sweep cron will catch any leaks.
  if (attIds.length > 0) {
    const { data: attRows } = await supa
      .schema('pendingbot')
      .from('attachments')
      .select('id, r2_key')
      .in('id', attIds)
      .eq('user_id', userId);
    const rows = (attRows ?? []) as Array<{ id: string; r2_key: string }>;

    if (rows.length > 0) {
      const { error: delAttErr } = await supa
        .schema('pendingbot')
        .from('attachments')
        .delete()
        .in('id', rows.map((r) => r.id))
        .eq('user_id', userId);
      if (delAttErr) {
        console.warn('[messages/recall] attachments delete failed', delAttErr.message);
      }
      // Invalidate KV: per-attachment metadata + the conv's inventory
      // list. Detached — a stale entry is acceptable (the row is gone
      // from Supabase, so any future check that falls through to DB
      // will get attachment_not_found anyway).
      safeWaitUntil(
        c,
        Promise.all([
          ...rows.map((r) => deleteCachedAttachment(c.env, r.id)),
          removeInventoryIds(c.env, msg.conversation_id, rows.map((r) => r.id)),
        ]).then(() => undefined),
      );
    }

    // For each r2_key the recaller used to own, check whether any
    // other attachments row still references it. If yes, leave the
    // R2 object alone (someone else still has a valid claim). If
    // no, delete the object.
    await Promise.all(
      rows.map(async ({ r2_key: key }) => {
        if (!key) return;
        const { count } = await supa
          .schema('pendingbot')
          .from('attachments')
          .select('id', { count: 'exact', head: true })
          .eq('r2_key', key);
        if ((count ?? 0) > 0) return;
        await c.env.UPLOADS.delete(key).catch((err) => {
          console.warn('[messages/recall] R2 delete failed', { key, err });
        });
      }),
    );
  }

  // 3) For user_user only, drop a tombstone log row so the peer sees a
  //    "我撤回了 X 的一条消息" line. iOS renders the relative time from
  //    original_created_at using its existing formatter. Other conv
  //    types don't surface a tombstone (per product spec).
  if (convType === 'user_user') {
    const { error: logErr } = await supa
      .schema('pendingbot')
      .from('messages')
      .insert({
        client_message_id: crypto.randomUUID(),
        conversation_id: msg.conversation_id,
        user_id: userId,
        role: 'log',
        status: 'done',
        log_kind: 'recall',
        log_payload: {
          original_message_id: id,
          original_created_at: msg.created_at,
          recaller_user_id: userId,
        },
      });
    if (logErr) {
      console.warn('[messages/recall] tombstone log insert failed', logErr.message);
    }
  }

  return c.json({ ok: true });
});

// DELETE /v1/messages/:id
//
// Removes a single message. Allowed when the caller authored the message OR
// owns the enclosing conversation (covers deleting bot replies in your own
// user_bot conv, but not other people's messages in groups). No soft-delete
// column on `messages`, so this is a hard DELETE — UI already removes the
// row optimistically once we return 200.
messageRoutes.delete('/:id', async (c) => {
  const userId = c.var.userId!;
  const id = c.req.param('id');
  if (!UUID_RE.test(id)) {
    return jsonError(c, 400, 'invalid_id');
  }

  const supa = serviceClient(c.env);

  const { data: msg, error: fetchErr } = await supa
    .schema('pendingbot')
    .from('messages')
    .select('id, user_id, conversation_id')
    .eq('id', id)
    .maybeSingle();
  if (fetchErr) return jsonError(c, 500, 'database_error', { detail: fetchErr.message });
  if (!msg) return jsonError(c, 404, 'not_found');

  let allowed = msg.user_id === userId;
  if (!allowed) {
    const { data: conv, error: convErr } = await supa
      .schema('pendingbot')
      .from('conversations')
      .select('user_id')
      .eq('id', msg.conversation_id)
      .maybeSingle();
    if (convErr) return jsonError(c, 500, 'database_error', { detail: convErr.message });
    allowed = !!conv && conv.user_id === userId;
  }
  if (!allowed) return jsonError(c, 403, 'forbidden');

  const { error: delErr } = await supa
    .schema('pendingbot')
    .from('messages')
    .delete()
    .eq('id', id);
  if (delErr) return jsonError(c, 500, 'database_error', { detail: delErr.message });

  return c.json({ ok: true });
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

// Resolves the conversation's main model (bot.model_id, falling back to
// DEFAULT_VISION_MODEL when the conv has no bot pinned), then kicks off
// summarizeAttachments for the just-uploaded image set. Self-contained so
// the route can fire it via waitUntil without holding up the response.
async function scheduleAttachmentSummary(input: {
  env: AppBindings['Bindings'];
  conversationId: string;
  userId: string;
  attachmentIds: string[];
  /// May be null for user_user / no-bot self convs — those use
  /// DEFAULT_VISION_MODEL directly since there's no main model to align
  /// with.
  botId: string | null;
  visionOverride: string | null;
}): Promise<void> {
  try {
    const supa = serviceClient(input.env);
    let mainModelSlug: string = DEFAULT_VISION_MODEL;
    if (input.botId) {
      const { data: bot } = await supa
        .from('bots')
        .select('model_id')
        .eq('id', input.botId)
        .maybeSingle();
      const botModelId = (bot as { model_id?: string } | null)?.model_id;
      if (botModelId && botModelId.length > 0) {
        mainModelSlug = botModelId;
      }
    }
    await summarizeAttachments(
      {
        supa,
        env: input.env,
        conversationId: input.conversationId,
        userId: input.userId,
        mainModelSlug,
        visionOverride: input.visionOverride,
      },
      input.attachmentIds,
    );
  } catch (err) {
    console.warn('[messages] scheduleAttachmentSummary failed', err);
  }
}
