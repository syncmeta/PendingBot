import { runChatTurn } from './bot-reply';
import { gateConversation } from '../billing/usage-gate';
import { parseWebSearchConfig } from './bot-reply/tool-defs';
import { serviceClient } from './supabase';
import { notifyConversationUnreadState } from './unread-state';
import type { Env } from '../types';

/// Pull the bot's default vision model (bots.config.visionModel) out of
/// the jsonb config blob. null = auto (use main model if vision-capable,
/// else the server's default vision model).
function botConfigVisionModel(config: unknown): string | null {
  if (!config || typeof config !== 'object' || Array.isArray(config)) return null;
  const v = (config as Record<string, unknown>).visionModel;
  return typeof v === 'string' && v.length > 0 ? v : null;
}

// Group-turn dispatch — wake one or more bots in a group conversation
// to take a turn. Called by:
//   - M4: GroupRouterDO after the small-model classifier returns a
//         non-empty wake list
//   - M5: messages.ts when @-mention parsing resolves to bot ids
//
// Two big things this layer adds on top of runChatTurn:
//
// 1) **Anti-loop continue-vote** — if the last 30s of the conversation
//    contains ONLY bot messages (no human said anything), we don't fire
//    runChatTurn yet. Instead we INSERT a `role='log',
//    log_kind='continue_request'` system bubble and a
//    group_continue_requests row, then return. Humans see the bubble in
//    Realtime, tap allow / deny, and that decision (a normal user
//    message + RPC call) is what re-kicks dispatchGroupTurn. See
//    `/v1/groups/:id/continue-decision` in routes/groups.ts.
//
// 2) **Serial bot turns** — if multiple bots were woken, we run them
//    one after another (not in parallel) so each successive bot sees
//    the previous bot's reply. Realtime streams each completed turn to
//    iOS as it lands.
//
// Billing is resolved in the audit layer from `conversationId`: group
// conversations split across eligible members there, so this dispatcher
// only needs a user id for legacy caller context and route metadata.

export interface DispatchGroupTurnInput {
  env: Env;
  /// Used for `c.executionCtx.waitUntil(...)` style fan-out so the
  /// caller can return its HTTP response while bot turns continue
  /// in the background. May be undefined when called from a context
  /// without a request-bound execution context (e.g. DO alarm).
  waitUntil?: (promise: Promise<unknown>) => void;
  conversationId: string;
  /// Bot ids the upstream router decided to wake. Order is preserved
  /// (router puts the most-relevant bot first; first to speak shapes
  /// the rest of the turn).
  wakeBotIds: string[];
  /// Reason the bots were woken — included in audit_log.tag for
  /// post-hoc analysis (router / mention / continue_resume).
  reason: 'router' | 'mention' | 'continue_resume';
  /// AbortSignal for the dispatch — when this fires, in-flight
  /// runChatTurn calls abort. DO alarms wire this to a 5min ceiling.
  signal?: AbortSignal;
}

export interface DispatchGroupTurnResult {
  status: 'dispatched' | 'continue_request_filed' | 'no_bots' | 'aborted' | 'no_balance';
  /// Number of bots that actually got to runChatTurn (some may be
  /// skipped because they were since removed from the group).
  bubblesPerBot: Array<{ bot_id: string; bubbles_inserted: number; final_status: string }>;
  /// Set when we filed a continue request instead of dispatching.
  continueRequestId?: string;
}

const CONTINUE_VOTE_WINDOW_MS = 30_000;
const CONTINUE_VOTE_MESSAGE =
  '机器人还有话想说,是否让它继续? 任一群成员回复 ✅ 让机器人继续 / ❌ 让机器人闭嘴。';

export async function dispatchGroupTurn(
  input: DispatchGroupTurnInput,
): Promise<DispatchGroupTurnResult> {
  const { env, conversationId, wakeBotIds, reason, signal } = input;

  if (wakeBotIds.length === 0) {
    return { status: 'no_bots', bubblesPerBot: [] };
  }

  const supa = serviceClient(env);

  // 0. 余额门禁(计费 P2 群钱包):群消费的责任主体 = 群池 + 认缴聚合。耗尽则
  //    不发起 bot 回合(否则跑完才事后扣、把群池/认缴扣穿)。读失败 fail-open。
  const gateErr = await gateConversation(env, supa, { conversationId });
  if (gateErr) {
    console.warn('[group-dispatch] group balance exhausted, skip bot turn', conversationId);
    return { status: 'no_balance', bubblesPerBot: [] };
  }

  // 1. Anti-loop check: did a human speak in the last 30s? If not,
  //    file a continue_request and let humans gate further bot output.
  //    `reason='continue_resume'` bypasses this gate — it's the path
  //    a human's allow vote takes back into the dispatcher, and we
  //    don't want to bounce them through another vote immediately.
  if (reason !== 'continue_resume') {
    const cutoff = new Date(Date.now() - CONTINUE_VOTE_WINDOW_MS).toISOString();
    const { data: recentMsgs, error: recentErr } = await supa
      .from('messages')
      .select('id, role')
      .eq('conversation_id', conversationId)
      .gt('created_at', cutoff)
      .order('created_at', { ascending: false })
      .limit(20);
    if (recentErr) {
      console.error('[group-dispatch] recent message read failed', recentErr);
    }

    const humanWindow = (recentMsgs ?? []).some((m) => m.role === 'user' || m.role === 'human');
    const hasAnyMessages = (recentMsgs ?? []).length > 0;

    // Only gate when there ARE recent messages AND none of them are
    // human. An empty 30s window means the conv is just quiet — let
    // bots speak freely (typical of router-triggered routine wakes).
    if (hasAnyMessages && !humanWindow) {
      return await fileContinueRequest(env, conversationId, wakeBotIds);
    }
  }

  // 2. Drop bots that are no longer participants (e.g. removed
  //    between router decision and this dispatch).
  const { data: still } = await supa
    .from('conversation_participants')
    .select('participant_id')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'bot')
    .in('participant_id', wakeBotIds);
  const stillIds = new Set((still ?? []).map((r) => r.participant_id as string));
  const filtered = wakeBotIds.filter((id) => stillIds.has(id));
  if (filtered.length === 0) return { status: 'no_bots', bubblesPerBot: [] };

  // 3. Resolve the conv creator for legacy caller context. Audit billing
  //    uses the conversation id and ignores this user id for group split.
  const { data: convRow } = await supa
    .from('conversations')
    .select('user_id, round_count')
    .eq('id', conversationId)
    .single();
  const placeholderUserId = convRow?.user_id ?? '';

  // 4. Serial dispatch. Each bot's runChatTurn writes its bubbles to
  //    `messages` directly; Realtime fans those out to iOS. We don't
  //    surface SSE here — the caller's HTTP response is already gone.
  const bubblesPerBot: DispatchGroupTurnResult['bubblesPerBot'] = [];
  for (const botId of filtered) {
    if (signal?.aborted) {
      return { status: 'aborted', bubblesPerBot };
    }

    const { data: bot } = await supa
      .from('bots')
      .select('id, display_name, model_id, model_provider, output_mode, is_active, tz, config')
      .eq('id', botId)
      .maybeSingle();
    if (!bot || !bot.is_active) continue;

    // Find the most recent user/human message as parent. If the
    // conversation is currently bot-heavy (router triggered after
    // a quiet stretch), parent is the last user row even if older.
    const { data: parent } = await supa
      .from('messages')
      .select('id')
      .eq('conversation_id', conversationId)
      .in('role', ['user', 'human'])
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    const parentMessageId = (parent?.id as string | undefined) ?? '';

    // Pull last ~20 messages so the bot has context.
    const { data: ctx } = await supa
      .from('messages')
      .select('role, content, created_at')
      .eq('conversation_id', conversationId)
      .in('role', ['user', 'bot', 'human', 'log'])
      .neq('status', 'deleted')  // recall: bot must not see recalled rows
      .order('created_at', { ascending: false })
      .limit(20);
    const recentContext = ((ctx ?? []) as Array<{
      role: 'user' | 'bot' | 'human' | 'log';
      content: string | null;
      created_at: string;
    }>)
      .reverse()
      .map((m) => ({
        role: m.role,
        content: m.content ?? '',
        created_at: m.created_at,
      }));

    // Synthesize a "newMessage" hook for runChatTurn — it expects a
    // user-side prompt to anchor the turn. In groups the bot reads
    // recentContext directly, so a thin nudge is enough; full prompt
    // engineering (group nickname map, per-bot description) lands in
    // M5 alongside @mention support.
    const nudge = '（群消息上下文已附,请按需回复或输出 [SILENT]。）';

    try {
      const result = await runChatTurn({
        env,
        conversationId,
        userId: placeholderUserId,
        parentMessageId,
        bot: {
          id: bot.id,
          display_name: (bot.display_name as string | null) ?? '',
          model_id: bot.model_id as string,
          output_mode: bot.output_mode === 'bubble' ? 'bubble' : 'single',
          // Public bots in groups always have tz set (migration backfill
          // + iOS create flow). The builder uses this as the time-hint tz
          // when clientTz is absent (which it always is here — group
          // dispatch has no live request body) and includes a self-tz
          // line in the system prompt.
          tz: (bot.tz as string | null) ?? null,
        },
        recentContext,
        newMessage: nudge,
        // Bot-level routing + vision defaults (no per-conv overrides).
        providerOverride: (bot.model_provider as string | null) ?? null,
        visionModelOverride: botConfigVisionModel(bot.config),
        webSearch: parseWebSearchConfig(bot.config),
        // Exposes set_my_group_nickname + set_bot_group_description
        // tools to this turn. The bot can call them mid-reply to
        // refine its group identity / "when to call me" doc.
        inGroup: true,
        signal: signal ?? new AbortController().signal,
        emit: () => {
          /* group dispatch doesn't surface SSE — Realtime carries bubbles */
        },
      });
      bubblesPerBot.push({
        bot_id: bot.id,
        bubbles_inserted: result.bubblesInserted,
        final_status: result.finalStatus,
      });
      if (result.finalStatus === 'done' && result.bubblesInserted > 0) {
        await notifyConversationUnreadState(env, conversationId);
      }
    } catch (err) {
      console.error('[group-dispatch] runChatTurn failed', botId, err);
      bubblesPerBot.push({
        bot_id: bot.id,
        bubbles_inserted: 0,
        final_status: 'error',
      });
    }
  }

  return { status: 'dispatched', bubblesPerBot };
}

// Insert the system "may we continue?" bubble + the matching
// group_continue_requests row. Returns the request id so callers
// can hand it back for diagnostics.
async function fileContinueRequest(
  env: Env,
  conversationId: string,
  wakeBotIds: string[],
): Promise<DispatchGroupTurnResult> {
  const supa = serviceClient(env);

  const { data: promptMsg, error: promptErr } = await supa
    .from('messages')
    .insert({
      client_message_id: crypto.randomUUID(),
      conversation_id: conversationId,
      role: 'log',
      log_kind: 'continue_request',
      content: CONTINUE_VOTE_MESSAGE,
      log_payload: { pending_bot_ids: wakeBotIds },
      status: 'done',
    })
    .select('id')
    .single();
  if (promptErr || !promptMsg) {
    console.error('[group-dispatch] failed to insert continue prompt', promptErr);
    return { status: 'no_bots', bubblesPerBot: [] };
  }

  const { data: req, error: reqErr } = await supa
    .from('group_continue_requests')
    .insert({
      conversation_id: conversationId,
      pending_bot_ids: wakeBotIds,
      prompt_message_id: promptMsg.id,
    })
    .select('id')
    .single();
  if (reqErr || !req) {
    console.error('[group-dispatch] failed to insert continue request', reqErr);
    return { status: 'no_bots', bubblesPerBot: [] };
  }

  return {
    status: 'continue_request_filed',
    bubblesPerBot: [],
    continueRequestId: req.id as string,
  };
}
