import type {
  ChatCompletionCreateParamsNonStreaming,
  ChatCompletionMessageParam,
} from 'openai/resources/chat/completions';
import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import { uuidv7 } from '../../ids';
import {
  FallbackError,
  enqueueAudit,
  usageFromCompletion,
  withFallback,
} from '../../../llm/router';
import { openAnthropicStream } from '../../../llm/anthropic-adapter';
import { openGeminiStream } from '../../../llm/gemini-adapter';
import {
  chatMessagesToResponsesInput,
  openResponsesStream,
} from '../../../llm/responses-adapter';
import type { ToolCtx } from '../tool-runner';

// One specialist turn is bounded by this internal cap. The cap is
// generous because the parent bot's runChatTurn runs detached from the
// SSE response (see routes/messages.ts — `detachedAbort` rather than
// the client's signal), so a client disconnect mid-delegation doesn't
// stop the work. When the parent's final reply lands, notifyUserMessage
// already fires a push to the user's devices — that IS the wakeup. So
// "SSE detach + push wakeup" for long delegations is the existing
// architecture; we just need a sensible upper bound here.
//
// 5 min covers near every realistic specialist turn (Anthropic + Gemini
// + OpenAI's chat completions reliably return well under 2 min even on
// the heaviest reasoning models). AI Gateway will surface its own
// upstream timeout long before this fires if the provider hangs.
const SPECIALIST_TIMEOUT_MS = 300_000;
const PROMPT_MAX = 8_000;

interface BotRow {
  id: string;
  display_name: string;
  model_id: string;
  model_provider: string | null;
  config: Record<string, unknown> | null;
  is_active?: boolean;
}

export interface DelegateTarget {
  id: string;
  displayName: string;
  modelId: string;
  modelProvider: string | null;
}

interface ContactBotRow {
  bot: BotRow | null;
}

// Look up the user's bot contacts as delegate targets. Contacts already
// encode the app-level visibility gate (private owner, invitee, preset, or
// public-open), so the tool can offer any model-backed bot the user can
// actually chat with, not just a fixed provider trio.
export async function delegateTargetsForUser(
  env: Env,
  userId: string,
  callerBotId?: string | null,
): Promise<DelegateTarget[]> {
  const supa = serviceClient(env);
  const { data, error } = await supa
    .from('user_bot_contacts')
    .select(`
      bot:bots!user_bot_contacts_bot_id_fkey!inner(
        id,
        display_name,
        model_id,
        model_provider,
        config,
        is_active
      )
    `)
    .eq('user_id', userId)
    .order('added_at', { ascending: false });
  if (error) throw error;

  const out: DelegateTarget[] = [];
  const seen = new Set<string>();
  for (const row of (data ?? []) as unknown as ContactBotRow[]) {
    const bot = row.bot;
    if (!bot || bot.is_active === false || bot.id === callerBotId || seen.has(bot.id)) continue;
    seen.add(bot.id);
    out.push({
      id: bot.id,
      displayName: bot.display_name || bot.model_id,
      modelId: bot.model_id,
      modelProvider: bot.model_provider ?? null,
    });
  }
  return out;
}

async function resolveDelegateBot(
  env: Env,
  userId: string,
  targetBotId: string,
  callerBotId?: string | null,
): Promise<BotRow | null> {
  const supa = serviceClient(env);
  const { data, error } = await supa
    .from('user_bot_contacts')
    .select(`
      bot:bots!user_bot_contacts_bot_id_fkey!inner(
        id,
        display_name,
        model_id,
        model_provider,
        config,
        is_active
      )
    `)
    .eq('user_id', userId)
    .eq('bot_id', targetBotId)
    .maybeSingle();
  if (error) throw error;
  const bot = ((data as unknown as ContactBotRow | null)?.bot) ?? null;
  if (!bot || bot.is_active === false || bot.id === callerBotId) return null;
  return {
    id: bot.id,
    display_name: bot.display_name,
    model_id: bot.model_id,
    model_provider: bot.model_provider ?? null,
    config: bot.config ?? null,
  };
}

async function insertSubConversationParticipants(
  env: Env,
  subConvId: string,
  userId: string,
  specialistBotId: string,
): Promise<string | null> {
  const supa = serviceClient(env);
  const { error } = await supa.from('conversation_participants').insert([
    {
      conversation_id: subConvId,
      participant_type: 'user',
      participant_id: userId,
      role: 'owner',
    },
    {
      conversation_id: subConvId,
      participant_type: 'bot',
      participant_id: specialistBotId,
      role: 'member',
    },
  ]);
  if (error) {
    console.warn('[delegate] sub-conv participant insert failed:', error.message);
    return error.message;
  }
  return null;
}

// Dispatch one delegate call. Creates a sub-conversation pinned to the
// parent bot's message, runs a single non-streaming completion against
// the specialist, and returns the bot's response text. Errors from the
// specialist are returned as JSON envelopes (never thrown) so the
// parent bot's loop can keep going.
export async function delegateToSpecialistTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const targetBotId =
    typeof args.target_bot_id === 'string'
      ? args.target_bot_id.trim()
      : typeof args.bot_id === 'string'
        ? args.bot_id.trim()
        : typeof args.target === 'string'
          ? args.target.trim()
          : '';
  const prompt = typeof args.prompt === 'string' ? args.prompt.trim() : '';
  if (!targetBotId) return JSON.stringify({ error: 'empty target_bot_id' });
  if (!prompt) return JSON.stringify({ error: 'empty prompt' });
  if (prompt.length > PROMPT_MAX) {
    return JSON.stringify({ error: `prompt exceeds ${PROMPT_MAX} chars` });
  }

  const specialist = await resolveDelegateBot(env, ctx.userId, targetBotId, ctx.botId);
  if (!specialist) {
    return JSON.stringify({
      error: `target bot "${targetBotId}" is not one of your available bot contacts`,
    });
  }

  ctx.emit('tool_call', {
    name: 'delegate_to_specialist',
    target: specialist.display_name,
    specialist_bot_id: specialist.id,
    target_bot_id: specialist.id,
  });

  const supa = serviceClient(env);

  // 1. Create the sub-conversation. parent_message_id pins it to the
  //    user message that triggered this parent turn; spawner_bot_id
  //    attributes the delegation in the UI; bot_id is the specialist.
  const subConvId = uuidv7();
  const subUserMessageId = uuidv7();
  const subBotMessageId = uuidv7();
  const { error: convErr } = await supa.from('conversations').insert({
    id: subConvId,
    conversation_type: 'subagent',
    user_id: ctx.userId,
    bot_id: specialist.id,
    parent_message_id: ctx.parentMessageId || null,
    spawner_bot_id: ctx.botId,
    title: `delegate→${specialist.display_name}`,
  });
  if (convErr) {
    return JSON.stringify({ error: `sub-conv insert failed: ${convErr.message}` });
  }

  // 2. The specialist sees a fresh, two-message conversation: a single
  //    user-role turn carrying the parent bot's prompt, followed by the
  //    specialist's reply. The parent's history is NOT replayed — the
  //    parent bot is expected to put everything the specialist needs
  //    into `prompt`. This keeps cost predictable and lets the user
  //    audit exactly what was delegated.
  await supa.from('messages').insert({
    id: subUserMessageId,
    client_message_id: subUserMessageId,
    conversation_id: subConvId,
    user_id: ctx.userId,
    role: 'user',
    content: prompt,
    status: 'done',
  });

  // 3. Run the specialist completion. withFallback covers transient
  //    provider errors — the cap is one retry on a different attempt
  //    since the passthrough router has one path per provider.
  const turnId = uuidv7();
  const startedAt = Date.now();
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), SPECIALIST_TIMEOUT_MS);
  // The specialist's own AbortSignal still respects parent cancellation
  // (e.g. user-tapped stop) — combine via Promise.race below.
  ctx.signal.addEventListener('abort', () => ac.abort(), { once: true });

  let answer = '';
  let bytesIn = 0;
  let bytesOut = 0;
  try {
    const fallback = await withFallback(
      supa,
      env,
      {
        modelSlug: specialist.model_id,
        taskType: 'delegate',
        preferProvider: specialist.model_provider ?? undefined,
        metadata: {
          userId: ctx.userId,
          conversationId: subConvId,
          turnId,
        },
      },
      async (route) => {
        const systemPrompt = extractSystemPrompt(specialist.config);
        const messages: ChatCompletionMessageParam[] = [
          ...(systemPrompt
            ? [{ role: 'system' as const, content: systemPrompt }]
            : []),
          { role: 'user' as const, content: prompt },
        ];
        // Anthropic / Gemini specialists go through their native adapters
        // (raw fetch on the AI Gateway native passthrough). OpenAI-native
        // specialists use Responses. OpenRouter/default specialists use
        // Chat Completions. Delegate turns intentionally get no tools of
        // their own; the parent bot must ask a self-contained question.
        if (route.provider.apiStyle === 'anthropic' || route.provider.apiStyle === 'gemini') {
          const stream =
            route.provider.apiStyle === 'anthropic'
              ? await openAnthropicStream(
                  route.baseURL,
                  route.aigToken,
                  { model: route.modelToCall, messages, tools: [] },
                  ac.signal,
                )
              : await openGeminiStream(
                  route.baseURL,
                  route.aigToken,
                  { model: route.modelToCall, messages, tools: [] },
                  ac.signal,
                  route.byokAlias,
                );
          let text = '';
          for await (const chunk of stream) {
            const delta = chunk.choices?.[0]?.delta?.content;
            if (delta) text += delta;
            if (chunk.usage) {
              const usage = usageFromCompletion(chunk.usage);
              bytesIn = usage.inputTokens ?? 0;
              bytesOut = usage.outputTokens ?? 0;
            }
          }
          return { text };
        }
        if (route.provider.apiStyle === 'responses') {
          const { instructions, input } = chatMessagesToResponsesInput(messages);
          const stream = await openResponsesStream(
            route.client,
            {
              model: route.modelToCall,
              instructions,
              input,
              tools: [],
            },
            ac.signal,
          );
          let text = '';
          for await (const chunk of stream) {
            const delta = chunk.choices?.[0]?.delta?.content;
            if (delta) text += delta;
            if (chunk.usage) {
              const usage = usageFromCompletion(chunk.usage, chunk);
              bytesIn = usage.inputTokens ?? 0;
              bytesOut = usage.outputTokens ?? 0;
            }
          }
          return { text };
        }
        const req: ChatCompletionCreateParamsNonStreaming = {
          model: route.modelToCall,
          stream: false,
          messages,
        };
        const completion = await route.client.chat.completions.create(req, {
          signal: ac.signal,
        });
        const choice = completion.choices?.[0];
        const text = choice?.message?.content ?? '';
        const usage = usageFromCompletion(completion);
        bytesIn = usage.inputTokens ?? 0;
        bytesOut = usage.outputTokens ?? 0;
        return { text: typeof text === 'string' ? text : '' };
      },
    );

    answer = fallback.result.text.trim();
    // Audit the specialist turn separately so cost lands on its own row
    // tagged delegate→<provider>; the AI Gateway log correlates by turnId.
    await enqueueAudit(env, fallback.route, {
      userId: ctx.userId,
      conversationId: subConvId,
      taskType: 'delegate',
      auditId: turnId,
      startedAt,
      status: 'success',
      tag: specialist.display_name,
      inputTokens: bytesIn,
      outputTokens: bytesOut,
      metadata: {
        delegate_target_bot_id: specialist.id,
        delegate_target_name: specialist.display_name,
        spawner_bot_id: ctx.botId,
        parent_conversation_id: ctx.conversationId,
      },
    });
  } catch (err) {
    clearTimeout(timer);
    const aborted = ac.signal.aborted && !ctx.signal.aborted;
    const errMsg =
      err instanceof FallbackError
        ? (err.lastError as Error | undefined)?.message ?? err.message
        : err instanceof Error
          ? err.message
          : String(err);
    // Mark the bot message as error so iOS renders it as a failed turn.
    await supa.from('messages').insert({
      id: subBotMessageId,
      client_message_id: subBotMessageId,
      conversation_id: subConvId,
      sender_bot_id: specialist.id,
      role: 'bot',
      content: '',
      status: 'error',
    });
    const participantError = await insertSubConversationParticipants(
      env,
      subConvId,
      ctx.userId,
      specialist.id,
    );
    ctx.emit('tool_result', {
      name: 'delegate_to_specialist',
      target: specialist.display_name,
      sub_conversation_id: subConvId,
      target_bot_id: specialist.id,
      error: aborted ? 'specialist timeout' : errMsg,
    });
    return JSON.stringify({
      error: aborted
        ? `specialist timed out after ${Math.round(SPECIALIST_TIMEOUT_MS / 1000)}s`
        : errMsg,
      sub_conversation_id: subConvId,
      participant_error: participantError ?? undefined,
    });
  } finally {
    clearTimeout(timer);
  }

  // 4. Persist the specialist's reply as a single bot-role message. We
  //    don't bubble-split (delegate replies are read as a unit, not as
  //    a stream of bubbles) and we skip the chat_memo / lookback paths
  //    that the main runChatTurn maintains.
  await supa.from('messages').insert({
    id: subBotMessageId,
    client_message_id: subBotMessageId,
    conversation_id: subConvId,
    sender_bot_id: specialist.id,
    role: 'bot',
    content: answer,
    status: 'done',
  });
  const participantError = await insertSubConversationParticipants(
    env,
    subConvId,
    ctx.userId,
    specialist.id,
  );

  ctx.emit('tool_result', {
    name: 'delegate_to_specialist',
    target: specialist.display_name,
    sub_conversation_id: subConvId,
    target_bot_id: specialist.id,
    chars: answer.length,
    ...(participantError ? { warning: `sub-conversation participant insert failed: ${participantError}` } : {}),
  });

  // 5. Return the specialist's answer to the parent bot. Include the
  //    sub-conversation id so the UI can deep-link from the parent's
  //    tool-call bubble. The model only consumes `answer`; the id is
  //    metadata for the SSE consumer + iOS render.
  return JSON.stringify({
    answer,
    sub_conversation_id: subConvId,
    specialist: specialist.display_name,
    specialist_bot_id: specialist.id,
    participant_error: participantError ?? undefined,
  });
}

function extractSystemPrompt(config: Record<string, unknown> | null): string | null {
  if (!config) return null;
  const sp = config.system_prompt;
  return typeof sp === 'string' && sp.trim() ? sp : null;
}
