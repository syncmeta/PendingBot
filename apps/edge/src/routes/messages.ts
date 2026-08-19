import { Hono, type Context } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { runChatTurn } from '../lib/bot-reply';
import { parseWebSearchConfig } from '../lib/bot-reply/tool-defs';
import { maybeRefreshMemory } from '../lib/memory';
import { runLookback } from '../lib/lookback-runner';
import { runTitle } from '../lib/title-runner';
import { requireBalance, InsufficientBalanceError } from '../lib/billing';
import { gateConversation } from '../billing/usage-gate';
import { resolveGroupMentions } from '../lib/group-mentions';
import { summarizeAttachments } from '../llm/vision';
import { getModelRole } from '../lib/model-roles';
import { UUID_RE } from '../lib/ids';
import { jsonError } from '../lib/http-error';
import type { Json } from '../db/schema';
import { deleteCachedAttachment, removeInventoryIds } from '../lib/attachment-cache';
import { resolveBot } from '../lib/bot-cache';
import { deleteCachedConv, resolveConv } from '../lib/conv-cache';
import { pickRandomModel } from '../llm/random-model';
import {
  chooseConversationMainModel,
  parseBlindBoxConfig,
  readConvModelStateRow,
  rerollConversationModel,
  type ConversationModelState,
} from '../lib/conversation-model';
import { safeWaitUntil } from '../lib/safe-wait-until';
import { trackEvent, AnalyticsEvent } from '../lib/track';
import { startSseKeepalive } from '../lib/sse-keepalive';
import { notifyConversationUsers, notifyUserMessage } from '../lib/push';
import {
  markConversationReadThroughLatest,
  notifyConversationUnreadState,
} from '../lib/unread-state';
import { patchConversationProjection } from '../lib/projection-writethrough';
import {
  authorizeAttachmentOwnership,
  authorizeBotUse,
  authorizeMessageDelete,
  authorizeMessageRecall,
  authorizeMessageSendConversation,
} from '../lib/route-authz';
import type { AppBindings } from '../types';

export const messageRoutes = new Hono<AppBindings>();
messageRoutes.use('*', requireSession());

const PostBody = z.object({
  conversationId: z.string().uuid(),
  clientMessageId: z.string().uuid(),         // UUID v7 from client (idempotency key)
  // newMessage is optional ONLY when autoLookback is true (the client is
  // auto-firing because a lookback note arrived and 30s of silence passed).
  newMessage: z.string().max(64_000).optional(),
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
  // IANA timezone of the client (e.g. "Asia/Shanghai" / "America/Los_Angeles").
  // Used to render the per-turn time hint we append to the user's message in
  // the LLM prompt, so the model sees the user's *local* clock — not UTC.
  clientTz: z.string().max(64).optional(),
});

const ReadAckBody = z.object({
  conversationId: z.string().uuid(),
  messageId: z.string().uuid().optional(),
  messageSeq: z.number().int().nonnegative().optional(),
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
// running (persisting finished bubbles to messages) so a flaky network or a
// backgrounded app can pick up where it left off via the realtime hub when
// the user re-opens the conv. Explicit stop is a separate POST
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
  if (!parsed.autoLookback && !parsed.newMessage && !parsed.attachmentIds?.length) {
    return jsonError(c, 400, 'invalid_body', { message: 'newMessage or attachment required' });
  }

  const supaUser = userClient(c.env, userJwt);
  const supaService = serviceClient(c.env);

  // Phase 1 — resolve conv (KV with RLS-gated fallback) and attachment
  // ownership in parallel. Both must succeed before any state change.
  // The conv resolver does a local user_id check for single-owner conv
  // types and only round-trips Supabase for groups / cold reads.
  const convPromise = authorizeMessageSendConversation(
    c.env,
    userJwt,
    userId,
    parsed.conversationId,
    (p) => safeWaitUntil(c, p),
  );

  const hasAttachments = (parsed.attachmentIds?.length ?? 0) > 0;
  const attCheckPromise = hasAttachments
    ? authorizeAttachmentOwnership(c.env, userId, parsed.attachmentIds!, (p) =>
        safeWaitUntil(c, p),
      )
    : Promise.resolve({ ok: true as const, attachments: [] });

  const [convResolved, attRows] = await Promise.all([convPromise, attCheckPromise]);

  if (!convResolved.ok) {
    if (convResolved.code === 'database_error') {
      return jsonError(c, 500, 'database_error', { detail: convResolved.detail });
    }
    if (convResolved.code === 'gone') {
      return jsonError(c, 410, 'peer_account_deleted', { message: '对方账号已注销' });
    }
    return jsonError(c, 404, 'conversation_no_access');
  }
  const conv = convResolved.conversation;

  // Attachment ownership gate. attachmentIds rides in the body uncontrolled —
  // verify each row's user_id matches the sender so a caller can't pin
  // someone else's upload onto their own bubble. The row's conversation_id
  // is not an access boundary: an attachment belongs to the user and may be
  // re-sent in any of their conversations (per-user dedup deliberately
  // shares one row across convs). GET /v1/uploads/:id still gates reads via
  // message references + membership.
  if (hasAttachments) {
    if (!attRows.ok && attRows.code === 'not_found') {
      return jsonError(c, 403, 'attachment_not_found');
    }
    if (!attRows.ok) {
      return jsonError(c, 403, 'attachment_not_owned');
    }
  }

  // Analytics: the send is authorized and committed past this point. Only
  // structural properties — never message content. Fire-and-forget.
  trackEvent(c, AnalyticsEvent.MessageSent, {
    conversation_id: parsed.conversationId,
    conversation_type: conv.conversation_type,
    has_attachment: hasAttachments,
    has_text: (parsed.newMessage?.length ?? 0) > 0,
    auto_lookback: parsed.autoLookback ?? false,
  });

  // Pre-generate the user message id so we can return it to the client
  // and reference it as parent_message_id without waiting for the INSERT
  // to land. The actual write fires through waitUntil below — idempotent
  // on client_message_id, so a retry collapses server-side.
  const needsBotPath = conv.bot_id !== null && conv.conversation_type !== 'group';
  const userMessageId = !parsed.autoLookback ? crypto.randomUUID() : null;

  // Phase 2 — fire balance gate, bot lookup, autoLookback parent lookup
  // in parallel. INSERT runs detached (waitUntil) using the
  // pre-generated id, so the pre-stream path holds no write RTT.
  // 余额门禁:仅 1v1 bot 路径在此同步 gate(发消息即流式触发 bot 回复 = 当场产生成本)。
  // 群消息在本 handler 不同步触发 bot 回复(群 bot 回复异步另走),故不在此 gate 群;
  // 群的前置 gate 应落在群 bot 回复发起处(见 tech-debt:群 bot 回复前置门禁未接)。
  // gateConversation 对 1v1 解析为发起人钱包,与旧 requireMessageBalance 等价。
  const balancePromise: Promise<InsufficientBalanceError | null> = needsBotPath
    ? gateConversation(c.env, supaService, { userId, conversationId: parsed.conversationId })
    : Promise.resolve(null);

  const botPromise = needsBotPath
    ? resolveBot(c.env, supaService, conv.bot_id!, (p) => safeWaitUntil(c, p))
    : Promise.resolve(null);

  const parentLookupPromise: Promise<string | null> = parsed.autoLookback
    ? lookupLatestUserMessageId(supaService, parsed.conversationId)
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
              content: parsed.newMessage ?? '',
              status: 'done',
              attachments: parsed.attachmentIds ? { ids: parsed.attachmentIds } : null,
            },
            { onConflict: 'client_message_id', ignoreDuplicates: true },
          );
        if (error) console.error('[messages] user upsert failed', error.message);
        else await notifyConversationUnreadState(c.env, parsed.conversationId);
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
          // No per-conv vision pin — scheduleAttachmentSummary resolves the
          // bot's own default (bots.config.visionModel) then auto-fallback.
          visionOverride: null,
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
    return insufficientBalanceResponse(c, balanceErr);
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

      // Push the human's group message to the other participants. Bot
      // replies in groups dispatch from the GroupRouterDO and are not
      // pushed here yet — see the DO's dispatch path for that follow-up.
      // Sender display name is looked up inside waitUntil so the HTTP
      // response doesn't block on it; the lookup feeds the recipient's
      // notification_preview_mode renderer.
      c.executionCtx.waitUntil(
        (async () => {
          const { data: sender } = await supaService
            .from('users')
            .select('display_name')
            .eq('id', userId)
            .maybeSingle();
          await notifyConversationUsers({
            env: c.env,
            conversationId: parsed.conversationId,
            excludeUserId: userId,
            senderName: sender?.display_name ?? null,
            contentPreview: parsed.newMessage ?? null,
            threadId: parsed.conversationId,
            extra: { conversationId: parsed.conversationId, kind: 'group' },
            collapseId: parsed.conversationId,
          });
        })(),
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
    if (!parsed.autoLookback && conv.conversation_type === 'user_user') {
      c.executionCtx.waitUntil(
        (async () => {
          const { data: sender } = await supaService
            .from('users')
            .select('display_name')
            .eq('id', userId)
            .maybeSingle();
          await notifyConversationUsers({
            env: c.env,
            conversationId: parsed.conversationId,
            excludeUserId: userId,
            senderName: sender?.display_name ?? null,
            contentPreview: parsed.newMessage ?? null,
            threadId: parsed.conversationId,
            extra: { conversationId: parsed.conversationId, kind: 'dm' },
            collapseId: parsed.conversationId,
          });
        })(),
      );
    }
    return c.json({ message: { id: parentMessageId }, botReplyScheduled: false });
  }

  // botRes was awaited in Phase 2 (needsBotPath was true). Narrow + check.
  if (!botRes) {
    return jsonError(c, 500, 'database_error', { message: 'bot lookup failed' });
  }
  const bot = botRes;
  if (!bot.is_active) {
    return c.json({ message: { id: parentMessageId }, botReplyScheduled: false });
  }

  // Visibility gate: resolveConv can let the user keep reading an existing
  // conversation after the creator un-invites them from a public_invite bot.
  // Re-check bot use on every new paid turn.
  const botUse = await authorizeBotUse(c.env, bot, userId);
  if (!botUse.ok) {
    if (botUse.code === 'database_error') {
      return jsonError(c, 500, 'database_error', { detail: botUse.detail });
    }
    return jsonError(c, 403, 'forbidden', { message: '没有权限和这个机器人聊天,可能已被取消邀请' });
  }

  const turnRoute = await resolveMessageBotTurnRoute(c.env, {
    model_id: bot.model_id as string,
    model_provider: bot.model_provider,
    config: bot.config,
    conversationId: parsed.conversationId,
    conversation: conv,
  });

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

      // SSE keepalive: writes a `:\n\n` comment every 15s so long quiet
      // stretches (notably OpenAI's image_generation built-in tool, which
      // can sit silent for 30–90s while rendering) don't trip the client's
      // 60s inactivity timeout. Stopped in `finally`.
      const stopKeepalive = startSseKeepalive(controller, () => streamClosed);

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
              display_name: bot.display_name,
              model_id: turnRoute.modelId,
              // CHECK constraint guarantees one of these two; types can't see it.
              output_mode: bot.output_mode === 'bubble' ? 'bubble' : 'single',
              tz: bot.tz,
            },
            isSelfChat,
            recentContext: parsed.recentContext ?? [],
            newMessage: parsed.newMessage ?? '（系统注入：根据上一轮的查证笔记，自然继续上面的对话。不要提到这是自动触发的。）',
            currentAttachmentIds: parsed.attachmentIds,
            // Bot's own default vision model (bots.config.visionModel);
            // null = auto (use main model if vision-capable, else default).
            visionModelOverride: botConfigString(bot.config, 'visionModel'),
            webSearch: parseWebSearchConfig(bot.config),
            activeLookbacks: parsed.activeLookbacks ?? [],
            providerOverride: turnRoute.providerOverride,
            clientTz: parsed.clientTz,
            signal: detachedAbort.signal,
            emit,
          });

          if (result.finalStatus === 'done' && result.bubblesInserted > 0) {
            const turnUpdatedAt = new Date().toISOString();
            const { data: updatedConv } = await supaService
              .from('conversations')
              .update({
                round_count: (conv.round_count ?? 0) + 1,
                last_turn_status: 'done',
                updated_at: turnUpdatedAt,
              })
              .eq('id', parsed.conversationId)
              .select('round_count')
              .single();

            // conversations 没有 realtime_notify 触发器 —— 轮次/时间戳自己推
            // 进列表投影,否则列表的"最后活跃"会停在建行那一刻。
            c.executionCtx.waitUntil(
              patchConversationProjection(c.env, parsed.conversationId, {
                round_count: updatedConv?.round_count ?? null,
                updated_at: turnUpdatedAt,
              }),
            );

            // If the bot opted to drop the lookbacks (emitted [DROP_LOOKBACK]),
            // mark them inactive. runChatTurn returned the ids it dropped.
            if (result.droppedLookbackIds.length > 0) {
              await supaService
                .from('bot_lookbacks')
                .update({ active: false, updated_at: new Date().toISOString() })
                .in('id', result.droppedLookbackIds);
            }

            // Per-bot opt-in lookback cadence; defaults below mirror the old
            // auto-review knobs (every 10 rounds). Counter is per (bot, user)
            // so accumulation crosses individual conversations.
            maybeAutoLookback({
              env: c.env,
              ctx: c.executionCtx,
              conversationId: parsed.conversationId,
              botId: bot.id,
              userId,
              botConfig: bot.config as LookbackConfigEnvelope | null,
            });

            // Push the bot reply to the conversation owner's devices. The
            // owner is the requester (userId) — on a 1v1 user_bot conv the
            // sender of this reply is the bot, so the user always gets it.
            // Self chats never push (the user is talking to themselves).
            if (conv.conversation_type !== 'self') {
              c.executionCtx.waitUntil(
                notifyUserMessage({
                  env: c.env,
                  userId,
                  senderName: bot.display_name,
                  contentPreview: result.totalContent,
                  threadId: parsed.conversationId,
                  extra: { conversationId: parsed.conversationId, kind: 'bot_reply' },
                  collapseId: parsed.conversationId,
                }).then(() => undefined),
              );
            }

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
                }),
              );
            }

            if (!streamClosed && conv.conversation_type === 'user_bot') {
              await markConversationReadThroughLatest({
                env: c.env,
                userId,
                conversationId: parsed.conversationId,
              });
            } else {
              await notifyConversationUnreadState(c.env, parsed.conversationId, [userId]);
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
          stopKeepalive();
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
  // Optional: an attachment-only first turn (image with no caption) is
  // valid. The handler rejects the both-empty case below.
  newMessage: z.string().max(64_000).optional(),
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
  clientTz: z.string().max(64).optional(),
});

messageRoutes.post('/start', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const supaUser = userClient(c.env, userJwt);

  let parsed: z.infer<typeof StartBody>;
  try {
    parsed = StartBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  if (!parsed.newMessage && !parsed.attachmentIds?.length) {
    return jsonError(c, 400, 'invalid_body', { message: 'newMessage or attachment required' });
  }

  const supaService = serviceClient(c.env);

  // Bot row needed for runChatTurn (model_id / output_mode / config).
  // Visibility is gated inside the SECURITY DEFINER RPC below — this read
  // just pulls the config we need to drive the turn. KV cache with 1h
  // TTL bounds staleness for iOS-direct bot edits.
  const botRaw = await resolveBot(c.env, supaService, parsed.botId, (p) => safeWaitUntil(c, p));
  if (!botRaw) return jsonError(c, 404, 'not_found', { message: 'bot not found' });
  if (!botRaw.is_active) return jsonError(c, 400, 'forbidden', { message: 'bot inactive' });
  if (!botRaw.model_id) return jsonError(c, 500, 'database_error', { message: 'bot has no model pinned' });
  const bot = { ...botRaw, model_id: botRaw.model_id };

  try {
    await requireBalance(c.env, supaUser, userId);
  } catch (err) {
    if (err instanceof InsufficientBalanceError) {
      return insufficientBalanceResponse(c, err);
    }
    throw err;
  }

  // Attachment ownership gate — verify each row belongs to the caller. The
  // row's conversation_id is not checked: an attachment belongs to the user,
  // not a conversation, and per-user dedup deliberately shares one row across
  // convs, so a first turn legitimately reuses an attachment already bound
  // to an earlier conv.
  if (parsed.attachmentIds && parsed.attachmentIds.length > 0) {
    const attAuthz = await authorizeAttachmentOwnership(c.env, userId, parsed.attachmentIds, (p) =>
      safeWaitUntil(c, p),
    );
    if (!attAuthz.ok && attAuthz.code === 'database_error') {
      return jsonError(c, 500, 'database_error', { detail: attAuthz.detail });
    }
    if (!attAuthz.ok && attAuthz.code === 'not_found') {
      return jsonError(c, 403, 'attachment_not_found');
    }
    if (!attAuthz.ok) {
      return jsonError(c, 403, 'attachment_not_owned');
    }
  }

  // Atomic conv + participants + user-msg insert. The RPC also gates bot
  // visibility (private creator match, public_invite invite check) using
  // auth.uid(), so failures come back as raised exceptions.
  const rpcResp = await supaUser.rpc('start_user_bot_turn', {
    p_bot_id: parsed.botId,
    p_client_message_id: parsed.clientMessageId,
    p_content: parsed.newMessage ?? '',
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

  // Detached attachment summarization for the just-created conv.
  // scheduleAttachmentSummary resolves the bot's own default vision model
  // (bots.config.visionModel), then the bot.model_id-vs-vision check, then
  // the 'vision' model-role default.
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

  const turnRoute = await resolveMessageBotTurnRoute(c.env, {
    ...bot,
    conversationId: convId,
  });

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

      // See /v1/messages above — same reasoning. Keepalive starts
      // immediately (before `meta`) because the gap from request-receipt to
      // first-token can itself exceed 60s on a cold OpenAI tool call.
      const stopKeepalive = startSseKeepalive(controller, () => streamClosed);

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
              display_name: bot.display_name,
              model_id: turnRoute.modelId,
              output_mode: bot.output_mode === 'bubble' ? 'bubble' : 'single',
              tz: bot.tz,
            },
            isSelfChat: false,
            recentContext: parsed.recentContext ?? [],
            newMessage: parsed.newMessage ?? '',
            currentAttachmentIds: parsed.attachmentIds,
            // Bot's own default vision model (bots.config.visionModel).
            visionModelOverride: botConfigString(bot.config, 'visionModel'),
            webSearch: parseWebSearchConfig(bot.config),
            activeLookbacks: [],
            providerOverride: turnRoute.providerOverride,
            clientTz: parsed.clientTz,
            signal: detachedAbort.signal,
            emit,
          });

          producedOutput = metaEmitted || result.bubblesInserted > 0;

          if (result.finalStatus === 'done' && result.bubblesInserted > 0) {
            const firstTurnUpdatedAt = new Date().toISOString();
            await supaService
              .from('conversations')
              .update({
                round_count: 1,
                last_turn_status: 'done',
                updated_at: firstTurnUpdatedAt,
              })
              .eq('id', convId);

            // 新会话第一轮 —— 这一步同时是投影里这条会话行的"补齐"时机:
            // participants webhook 可能还没落地,patch 落空会自动回落一次
            // 完整 sync(补读 conversations 行),不会留占位行。
            await patchConversationProjection(c.env, convId, {
              round_count: 1,
              updated_at: firstTurnUpdatedAt,
            });

            // Round 1 — kick off auto-title to replace the random place-name
            // fallback that start_user_bot_turn seeded.
            c.executionCtx.waitUntil(
              runTitle({
                env: c.env,
                conversationId: convId,
              }),
            );

            if (!streamClosed) {
              await markConversationReadThroughLatest({
                env: c.env,
                userId,
                conversationId: convId,
              });
            } else {
              await notifyConversationUnreadState(c.env, convId, [userId]);
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
          stopKeepalive();
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

messageRoutes.post('/read-ack', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;

  let parsed: z.infer<typeof ReadAckBody>;
  try {
    parsed = ReadAckBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supaUser = userClient(c.env, userJwt);
  const conv = await resolveConv(c.env, supaUser, parsed.conversationId, userId, (p) =>
    safeWaitUntil(c, p),
  ).catch((err: { message?: string }) => ({ __error: err.message ?? 'database_error' }));
  if (conv && typeof conv === 'object' && '__error' in conv) {
    return jsonError(c, 500, 'database_error', { detail: conv.__error });
  }
  if (!conv) return jsonError(c, 404, 'conversation_no_access');

  const result = await markConversationReadThroughLatest({
    env: c.env,
    userId,
    conversationId: parsed.conversationId,
    messageId: parsed.messageId,
    messageSeq: parsed.messageSeq,
  });
  return c.json({ ok: true, messageSeq: result.messageSeq });
});

// POST /v1/messages/:id/regenerate
//
// "再生成一个回答": produce ANOTHER bot answer to the same user prompt
// (`:id` = the parent user message), so the client can show blind variants.
// The new answer shares the parent_message_id with the existing one(s) —
// that's how variants of one prompt group — but gets its own bubble_group_id.
//
// Model: draw a candidate from the bot model pool without changing the
// conversation main model. Choosing an answer later switches the conversation
// main model to that answer's model. Does NOT bump round_count or auto-rename.
const RegenBody = z.object({
  conversationId: z.string().uuid(),
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
  clientTz: z.string().max(64).optional(),
});

messageRoutes.post('/:id/regenerate', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const parentId = c.req.param('id');
  if (!UUID_RE.test(parentId)) return jsonError(c, 400, 'invalid_id');

  let parsed: z.infer<typeof RegenBody>;
  try {
    parsed = RegenBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }

  const supaUser = userClient(c.env, userJwt);
  const supaService = serviceClient(c.env);

  const convResolved = await resolveConv(c.env, supaUser, parsed.conversationId, userId, (p) =>
    safeWaitUntil(c, p),
  ).catch((err: { message?: string }) => ({ __error: err.message ?? 'database_error' }));
  if (convResolved && typeof convResolved === 'object' && '__error' in convResolved) {
    return jsonError(c, 500, 'database_error', { detail: convResolved.__error });
  }
  const conv = convResolved as {
    id: string;
    conversation_type: 'user_bot' | 'self' | 'group' | 'user_user';
    bot_id: string | null;
  } | null;
  if (!conv) return jsonError(c, 404, 'conversation_no_access');
  if (!conv.bot_id || conv.conversation_type === 'group') {
    return jsonError(c, 400, 'conversation_has_no_bot');
  }

  const { data: parent, error: parentErr } = await supaService
    .from('messages')
    .select('id, conversation_id, role, content, attachments')
    .eq('id', parentId)
    .maybeSingle();
  if (parentErr) return jsonError(c, 500, 'database_error', { detail: parentErr.message });
  if (!parent || parent.conversation_id !== parsed.conversationId || parent.role !== 'user') {
    return jsonError(c, 404, 'not_found', { message: 'parent prompt not found' });
  }
  const parentAttachmentIds: string[] | undefined = (() => {
    const a = parent.attachments as { ids?: unknown } | null;
    if (!a || !Array.isArray(a.ids)) return undefined;
    const ids = a.ids.filter((x): x is string => typeof x === 'string');
    return ids.length > 0 ? ids : undefined;
  })();

  const bot = await resolveBot(c.env, supaService, conv.bot_id, (p) => safeWaitUntil(c, p));
  if (!bot) return jsonError(c, 500, 'database_error', { message: 'bot lookup failed' });
  if (!bot.is_active) return jsonError(c, 400, 'forbidden', { message: 'bot inactive' });
  if (!bot.model_id) return jsonError(c, 500, 'database_error', { message: 'bot has no model pinned' });
  const botUse = await authorizeBotUse(c.env, bot, userId);
  if (!botUse.ok) {
    if (botUse.code === 'database_error') {
      return jsonError(c, 500, 'database_error', { detail: botUse.detail });
    }
    return jsonError(c, 403, 'forbidden', { message: '没有权限和这个机器人聊天,可能已被取消邀请' });
  }

  // 群感知门禁:群按池+认缴聚合,1v1 按发起人(计费 P2)。
  const gateErr = await gateConversation(c.env, supaService, {
    userId,
    conversationId: parsed.conversationId,
  });
  if (gateErr) return insufficientBalanceResponse(c, gateErr);

  const blindBox = parseBlindBoxConfig(bot.config);
  let turnRoute: { modelId: string; providerOverride: string | null };
  if (blindBox.regenReroll) {
    // 盲盒:手动重抽 → 重新抽主模型并持久化,reveal 重置;新模型此后成为会话模型。
    const current = await readConvModelStateRow(c.env, parsed.conversationId);
    const rolled = await rerollConversationModel(
      c.env,
      parsed.conversationId,
      { model_id: bot.model_id, model_provider: bot.model_provider, config: bot.config },
      current?.current_model_slug ?? null,
    );
    turnRoute = rolled
      ? { modelId: rolled.slug, providerOverride: rolled.provider }
      : // No pool → keep current (or bot default), don't reset reveal.
        await resolveMessageBotTurnRoute(c.env, {
          model_id: bot.model_id,
          model_provider: bot.model_provider,
          config: bot.config,
          conversationId: parsed.conversationId,
        });
  } else {
    // 保持当前会话模型(不重抽,不动 reveal)。
    turnRoute = await resolveMessageBotTurnRoute(c.env, {
      model_id: bot.model_id,
      model_provider: bot.model_provider,
      config: bot.config,
      conversationId: parsed.conversationId,
    });
  }

  const isSelfChat = conv.conversation_type === 'self';
  const encoder = new TextEncoder();
  const detachedAbort = new AbortController();
  let streamClosed = false;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      const emit = (event: string, data: unknown) => {
        if (streamClosed) return;
        try {
          controller.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
        } catch {
          /* controller may already be closed */
        }
      };
      const stopKeepalive = startSseKeepalive(controller, () => streamClosed);
      const turnWork = (async () => {
        try {
          const result = await runChatTurn({
            env: c.env,
            conversationId: parsed.conversationId,
            userId,
            parentMessageId: parentId,
            bot: {
              id: bot.id,
              display_name: bot.display_name,
              model_id: turnRoute.modelId,
              output_mode: bot.output_mode === 'bubble' ? 'bubble' : 'single',
              tz: bot.tz,
            },
            isSelfChat,
            recentContext: parsed.recentContext ?? [],
            newMessage: parent.content ?? '',
            currentAttachmentIds: parentAttachmentIds,
            visionModelOverride: botConfigString(bot.config, 'visionModel'),
            webSearch: parseWebSearchConfig(bot.config),
            providerOverride: turnRoute.providerOverride,
            clientTz: parsed.clientTz,
            signal: detachedAbort.signal,
            emit,
          });
          if (result.finalStatus === 'done' && result.bubblesInserted > 0) {
            if (!streamClosed && conv.conversation_type === 'user_bot') {
              await markConversationReadThroughLatest({
                env: c.env,
                userId,
                conversationId: parsed.conversationId,
              });
            } else {
              await notifyConversationUnreadState(c.env, parsed.conversationId, [userId]);
            }
          }
        } catch (err) {
          const message = err instanceof Error ? err.message || err.name || 'Error' : String(err);
          console.error('[messages/regenerate] turn error:', err);
          emit('error', { message });
        } finally {
          stopKeepalive();
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

  const authz = await authorizeMessageRecall(c.env, id, userId);
  if (!authz.ok) {
    if (authz.code === 'database_error') {
      return jsonError(c, 500, 'database_error', { detail: authz.detail });
    }
    if (authz.code === 'not_found') return jsonError(c, 404, 'not_found');
    return jsonError(c, 403, 'forbidden');
  }
  const msg = authz.target;

  // Idempotent: already recalled → ok.
  if (msg.alreadyDeleted) return c.json({ ok: true, already: true });
  const convType = msg.conversationType ?? 'user_bot';

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
      attachments: null,
    })
    .eq('id', msg.messageId);
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
          removeInventoryIds(c.env, msg.conversationId, rows.map((r) => r.id)),
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
        conversation_id: msg.conversationId,
        user_id: userId,
        role: 'log',
        status: 'done',
        log_kind: 'recall',
        log_payload: {
          original_message_id: id,
          original_created_at: msg.createdAt,
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

  const authz = await authorizeMessageDelete(c.env, id, userId);
  if (!authz.ok) {
    if (authz.code === 'database_error') {
      return jsonError(c, 500, 'database_error', { detail: authz.detail });
    }
    if (authz.code === 'not_found') return jsonError(c, 404, 'not_found');
    return jsonError(c, 403, 'forbidden');
  }

  const { error: delErr } = await supa
    .schema('pendingbot')
    .from('messages')
    .delete()
    .eq('id', id);
  if (delErr) return jsonError(c, 500, 'database_error', { detail: delErr.message });

  return c.json({ ok: true });
});

// POST /v1/messages/:id/lookback — manual lookback trigger.
//
// `:id` is a conversation id (mirroring the recall + delete shape). User
// must be a participant of the conv, and the conv must have a bot. The
// runner fires detached via waitUntil; we also reset the (bot, user)
// counter so manual triggers don't double up with the auto cadence right
// after.
messageRoutes.post('/:id/lookback', async (c) => {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const convId = c.req.param('id');
  if (!UUID_RE.test(convId)) {
    return jsonError(c, 400, 'invalid_id');
  }

  const supaUser = userClient(c.env, userJwt);
  const supaService = serviceClient(c.env);

  // Visibility + bot lookup in one trip. resolveConv enforces participant
  // access via the user-JWT client.
  let conv: { id: string; bot_id: string | null } | null;
  try {
    const resolved = await resolveConv(c.env, supaUser, convId, userId, (p) =>
      safeWaitUntil(c, p),
    );
    conv = resolved as { id: string; bot_id: string | null } | null;
  } catch (err) {
    return jsonError(c, 500, 'database_error', {
      detail: (err as { message?: string }).message ?? 'resolveConv failed',
    });
  }
  if (!conv) return jsonError(c, 404, 'conversation_no_access');
  if (!conv.bot_id) return jsonError(c, 400, 'conversation_has_no_bot');
  const botId = conv.bot_id;

  // Reset the per-(bot,user) counter so a manual trigger doesn't double up
  // with the auto cadence on the very next turn. Best-effort — the runner
  // still fires even if this update fails.
  await supaService
    .from('bot_user_lookback_counter')
    .upsert(
      { bot_id: botId, user_id: userId, rounds_since_last: 0, updated_at: new Date().toISOString() },
      { onConflict: 'bot_id,user_id' },
    );

  c.executionCtx.waitUntil(
    runLookback({ env: c.env, conversationId: convId, botId }),
  );

  return c.json({ ok: true });
});

// Per-bot lookback config. Lives in `bots.config` jsonb. Defaults:
// enabled, every 10 rounds.
interface LookbackConfigEnvelope {
  lookback?: { enabled?: boolean; roundInterval?: number };
}

// Pull a non-empty string key out of the `bots.config` jsonb blob.
// Returns null for a missing / empty / non-string value so callers can
// `?? fallback` cleanly. Used to read the bot-level vision model
// default that a conversation without its own pin falls back to.
function botConfigString(config: unknown, key: string): string | null {
  if (!config || typeof config !== 'object') return null;
  const v = (config as Record<string, unknown>)[key];
  return typeof v === 'string' && v.length > 0 ? v : null;
}


function insufficientBalanceResponse(
  c: Context<AppBindings>,
  err: InsufficientBalanceError,
): Response {
  return c.json(
    {
      error: 'insufficient_balance',
      balance_credits: err.balance,
      min_threshold: err.threshold,
    },
    402,
  );
}

async function lookupLatestUserMessageId(
  supa: ReturnType<typeof serviceClient>,
  conversationId: string,
): Promise<string | null> {
  const { data } = await supa
    .from('messages')
    .select('id')
    .eq('conversation_id', conversationId)
    .eq('role', 'user')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  return (data?.id as string | undefined) ?? null;
}

async function resolveMessageBotTurnRoute(
  env: AppBindings['Bindings'],
  bot: {
    model_id: string;
    model_provider: string | null;
    config: unknown;
    conversationId?: string;
    conversation?: ConversationModelState | null;
  },
): Promise<{ modelId: string; providerOverride: string | null }> {
  let conversation = bot.conversation ?? null;
  if (!conversation && bot.conversationId) {
    conversation = await readConversationModelState(env, bot.conversationId);
  }
  const chosen = await chooseConversationMainModel({
    bot,
    conversation,
    pickFromPool: (cfg, pickOpts) => pickRandomModel(env, cfg, pickOpts),
  });
  if (chosen.shouldPersist && bot.conversationId) {
    await persistConversationMainModel(
      env,
      bot.conversationId,
      chosen.modelId,
      chosen.providerOverride,
    );
  }
  return {
    modelId: chosen.modelId,
    providerOverride: chosen.providerOverride,
  };
}

async function readConversationModelState(
  env: AppBindings['Bindings'],
  conversationId: string,
): Promise<ConversationModelState | null> {
  const { data } = await serviceClient(env)
    .from('conversations')
    .select('current_model_slug, current_model_provider')
    .eq('id', conversationId)
    .maybeSingle();
  if (!data) return null;
  return {
    current_model_slug: (data.current_model_slug ?? null) as string | null,
    current_model_provider: (data.current_model_provider ?? null) as string | null,
  };
}

async function persistConversationMainModel(
  env: AppBindings['Bindings'],
  conversationId: string,
  modelId: string,
  providerOverride: string | null,
): Promise<void> {
  const { error } = await serviceClient(env)
    .from('conversations')
    .update({
      current_model_slug: modelId,
      current_model_provider: providerOverride,
    })
    .eq('id', conversationId);
  if (error) {
    console.warn('[messages] persist conversation model failed', error.message);
    return;
  }
  await deleteCachedConv(env, conversationId).catch(() => undefined);
}

// Lookback cadence is keyed off a per (bot, user) counter that crosses
// conversations — `bump_lookback_counter` returns true when the running
// tally reaches `interval`, and atomically resets it to 0. The fired
// runLookback still scopes to the current conv (that's where the freshest
// transcript lives).
function maybeAutoLookback(input: {
  env: AppBindings['Bindings'];
  ctx: ExecutionContext;
  conversationId: string;
  botId: string;
  userId: string;
  botConfig: LookbackConfigEnvelope | null;
}) {
  const cfg = input.botConfig?.lookback ?? {};
  if (cfg.enabled === false) return;
  const interval = Math.max(1, cfg.roundInterval ?? 10);

  input.ctx.waitUntil((async () => {
    const supa = serviceClient(input.env);
    const { data: shouldFire, error } = await supa.rpc('bump_lookback_counter', {
      p_bot: input.botId,
      p_user: input.userId,
      p_interval: interval,
    });
    if (error) {
      console.warn('[lookback] bump_lookback_counter failed', error);
      return;
    }
    if (!shouldFire) return;
    await runLookback({
      env: input.env,
      conversationId: input.conversationId,
      botId: input.botId,
    });
  })());
}

// Resolves the conversation's main model (bot.model_id, falling back to
// the 'vision' model-role default when the conv has no bot pinned), then kicks off
// summarizeAttachments for the just-uploaded image set. Self-contained so
// the route can fire it via waitUntil without holding up the response.
async function scheduleAttachmentSummary(input: {
  env: AppBindings['Bindings'];
  conversationId: string;
  userId: string;
  attachmentIds: string[];
  /// May be null for user_user / no-bot self convs — those use
  /// the 'vision' model-role default directly since there's no main model to align
  /// with.
  botId: string | null;
  visionOverride: string | null;
}): Promise<void> {
  try {
    const supa = serviceClient(input.env);
    let mainModelSlug: string = await getModelRole(input.env, 'vision');
    // Conversation pin wins; otherwise the bot's own default vision
    // model (bots.config.visionModel) fills in before pickVisionModel's
    // auto path takes over.
    let visionOverride: string | null = input.visionOverride;
    if (input.botId) {
      const { data: bot } = await supa
        .from('bots')
        .select('model_id, config')
        .eq('id', input.botId)
        .maybeSingle();
      const botModelId = (bot as { model_id?: string } | null)?.model_id;
      if (botModelId && botModelId.length > 0) {
        mainModelSlug = botModelId;
      }
      if (!visionOverride) {
        visionOverride = botConfigString(
          (bot as { config?: unknown } | null)?.config,
          'visionModel',
        );
      }
    }
    await summarizeAttachments(
      {
        supa,
        env: input.env,
        conversationId: input.conversationId,
        userId: input.userId,
        mainModelSlug,
        visionOverride,
      },
      input.attachmentIds,
    );
  } catch (err) {
    console.warn('[messages] scheduleAttachmentSummary failed', err);
  }
}
