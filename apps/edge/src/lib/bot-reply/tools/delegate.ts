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
import type { ToolCtx } from '../tool-runner';

// Specialist registry — fixed enum the parent bot picks from. We keep
// the surface narrow (claude / openai / gemini) so the bot doesn't have
// to learn arbitrary bot ids. At dispatch time we resolve each key to
// the user's first bot using that native provider.
const SPECIALIST_PROVIDERS: Record<SpecialistKey, string> = {
  claude: 'anthropic',
  openai: 'openai',
  gemini: 'google-ai-studio',
};

export type SpecialistKey = 'claude' | 'openai' | 'gemini';

const SPECIALIST_KEYS = new Set<string>(Object.keys(SPECIALIST_PROVIDERS));

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
}

// Look up the user's native-API bots, keyed by provider slug. Each user
// can register at most one bot per provider for delegation; if they have
// several the first by creation order wins (most users will only have
// one of each anyway).
async function listSpecialists(
  env: Env,
  userId: string,
): Promise<Record<string, BotRow | undefined>> {
  const supa = serviceClient(env);
  const { data } = await supa
    .from('bots')
    .select('id, display_name, model_id, model_provider, config, created_at')
    .eq('is_active', true)
    .eq('creator_id', userId)
    .in('model_provider', Object.values(SPECIALIST_PROVIDERS))
    .order('created_at', { ascending: true });
  const out: Record<string, BotRow | undefined> = {};
  for (const row of (data ?? []) as Array<BotRow & { created_at: string }>) {
    const provider = row.model_provider;
    if (!provider) continue;
    if (out[provider]) continue;
    out[provider] = {
      id: row.id,
      display_name: row.display_name,
      model_id: row.model_id,
      model_provider: provider,
      config: row.config ?? null,
    };
  }
  return out;
}

// Public: which specialist providers does this user have a bot for?
// Drives whether `delegate_to_specialist` shows up on the turn's tool
// list, and which enum values its `target` parameter accepts.
export async function specialistTargetsForUser(
  env: Env,
  userId: string,
): Promise<SpecialistKey[]> {
  const map = await listSpecialists(env, userId);
  const targets: SpecialistKey[] = [];
  for (const key of Object.keys(SPECIALIST_PROVIDERS) as SpecialistKey[]) {
    if (map[SPECIALIST_PROVIDERS[key]]) targets.push(key);
  }
  return targets;
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
  const target = typeof args.target === 'string' ? args.target.trim() : '';
  const prompt = typeof args.prompt === 'string' ? args.prompt.trim() : '';
  if (!SPECIALIST_KEYS.has(target)) {
    return JSON.stringify({
      error: `unknown specialist target "${target}". allowed: claude / openai / gemini`,
    });
  }
  if (!prompt) return JSON.stringify({ error: 'empty prompt' });
  if (prompt.length > PROMPT_MAX) {
    return JSON.stringify({ error: `prompt exceeds ${PROMPT_MAX} chars` });
  }

  const specialists = await listSpecialists(env, ctx.userId);
  const providerSlug = SPECIALIST_PROVIDERS[target as SpecialistKey];
  const specialist = specialists[providerSlug];
  if (!specialist) {
    return JSON.stringify({
      error: `you do not have a "${target}" specialist bot registered. ` +
        `create a bot with model_provider="${providerSlug}" first.`,
    });
  }

  ctx.emit('tool_call', {
    name: 'delegate_to_specialist',
    target,
    specialist_bot_id: specialist.id,
  });

  const supa = serviceClient(env);

  // 1. Create the sub-conversation. parent_message_id pins it to the
  //    parent bot's just-emitted message; spawner_bot_id attributes the
  //    delegation in the UI; bot_id is the specialist being called.
  const subConvId = uuidv7();
  const subUserMessageId = uuidv7();
  const subBotMessageId = uuidv7();
  const { error: convErr } = await supa.from('conversations').insert({
    id: subConvId,
    conversation_type: 'subagent',
    user_id: ctx.userId,
    bot_id: specialist.id,
    parent_message_id: ctx.parentMessageId ?? null,
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
        // (raw fetch on the AI Gateway native passthrough). The adapters
        // return a single-burst async iterable; collect text + usage from
        // it. OpenAI specialists use the Chat Completions endpoint on the
        // openai passthrough (also fine on Unified Billing).
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
      tag: target,
      inputTokens: bytesIn,
      outputTokens: bytesOut,
      metadata: {
        delegate_target: target,
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
    ctx.emit('tool_result', {
      name: 'delegate_to_specialist',
      target,
      sub_conversation_id: subConvId,
      error: aborted ? 'specialist timeout' : errMsg,
    });
    return JSON.stringify({
      error: aborted
        ? `specialist timed out after ${Math.round(SPECIALIST_TIMEOUT_MS / 1000)}s`
        : errMsg,
      sub_conversation_id: subConvId,
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

  ctx.emit('tool_result', {
    name: 'delegate_to_specialist',
    target,
    sub_conversation_id: subConvId,
    chars: answer.length,
  });

  // 5. Return the specialist's answer to the parent bot. Include the
  //    sub-conversation id so the UI can deep-link from the parent's
  //    tool-call bubble. The model only consumes `answer`; the id is
  //    metadata for the SSE consumer + iOS render.
  return JSON.stringify({
    answer,
    sub_conversation_id: subConvId,
    specialist: target,
  });
}

function extractSystemPrompt(config: Record<string, unknown> | null): string | null {
  if (!config) return null;
  const sp = config.system_prompt;
  return typeof sp === 'string' && sp.trim() ? sp : null;
}
