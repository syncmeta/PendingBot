import type {
  ChatCompletionCreateParamsNonStreaming,
  ChatCompletionMessageParam,
} from 'openai/resources/chat/completions';
import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import { uuidv7 } from '../../ids';
import {
  auditErrorFields,
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

// `delegate_to_specialist` — fire one self-contained completion against
// an arbitrary `model_slug` and hand the answer back to the parent bot.
//
// New (May 2026) semantics: it is NOT "ask another bot" anymore. The
// caller bot passes a model identifier (e.g. 'claude-opus-4.7',
// '~google/gemini-2.5-pro') and a prompt — we make one non-streaming
// call through the same withFallback router used for chat turns and
// return the text. No sub-conversation, no specialist bot row, no
// dependence on user_bot_contacts (so private bots can delegate too).
//
// Which model_slug to pass is left to the model — typically a subscribed
// skill's body says "for complex math, delegate_to_specialist(
// model='claude-opus-4.7', ...)". The tool itself is permissive about
// the slug; if the router can't resolve it, the upstream error comes
// back through the JSON envelope.

const SPECIALIST_TIMEOUT_MS = 300_000;
const PROMPT_MAX = 8_000;

export async function delegateToSpecialistTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  // Accept a few aliases for the model slug — the LLM is sloppy about
  // which key it picks across providers (`model`, `model_slug`,
  // `specialist`). All map to the same string.
  const pickStr = (...keys: string[]): string => {
    for (const k of keys) {
      const v = args[k];
      if (typeof v === 'string' && v.trim()) return v.trim();
    }
    return '';
  };
  const modelSlug = pickStr('model_slug', 'model', 'specialist');
  const prompt = typeof args.prompt === 'string' ? args.prompt.trim() : '';
  if (!modelSlug) return JSON.stringify({ error: 'empty model_slug' });
  if (!prompt) return JSON.stringify({ error: 'empty prompt' });
  if (prompt.length > PROMPT_MAX) {
    return JSON.stringify({ error: `prompt exceeds ${PROMPT_MAX} chars` });
  }

  ctx.emit('tool_call', {
    name: 'delegate_to_specialist',
    model_slug: modelSlug,
  });

  const supa = serviceClient(env);
  const turnId = uuidv7();
  const startedAt = Date.now();
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), SPECIALIST_TIMEOUT_MS);
  ctx.signal.addEventListener('abort', () => ac.abort(), { once: true });

  let answer = '';
  let bytesIn = 0;
  let bytesOut = 0;
  try {
    const fallback = await withFallback(
      supa,
      env,
      {
        modelSlug,
        taskType: 'delegate',
        metadata: {
          userId: ctx.userId,
          conversationId: ctx.conversationId,
          turnId,
        },
      },
      async (route) => {
        // The specialist sees one user-role turn carrying the parent
        // bot's prompt and nothing else. Parent history is NOT replayed
        // — the parent must put everything the specialist needs in
        // `prompt`. Specialist turns get no tools.
        const messages: ChatCompletionMessageParam[] = [
          { role: 'user' as const, content: prompt },
        ];
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
    await enqueueAudit(env, fallback.route, {
      userId: ctx.userId,
      conversationId: ctx.conversationId,
      taskType: 'delegate',
      auditId: turnId,
      startedAt,
      status: 'success',
      tag: modelSlug,
      inputTokens: bytesIn,
      outputTokens: bytesOut,
      metadata: {
        delegate_model_slug: modelSlug,
        caller_bot_id: ctx.botId,
        caller_conversation_id: ctx.conversationId,
      },
    });
  } catch (err) {
    clearTimeout(timer);
    const aborted = ac.signal.aborted && !ctx.signal.aborted;
    const audit = auditErrorFields(err);
    const errMsg =
      err instanceof FallbackError
        ? (err.lastError as Error | undefined)?.message ?? err.message
        : err instanceof Error
          ? err.message
          : String(err);
    // Delegated turns were the one withFallback call site that recorded
    // nothing on failure — a specialist call that never landed left no
    // row at all, so `select * from audit_log where task_type='delegate'`
    // only ever showed the ones that worked.
    await enqueueAudit(env, audit.route, {
      auditId: turnId,
      userId: ctx.userId,
      conversationId: ctx.conversationId,
      taskType: 'delegate',
      startedAt,
      status: 'error',
      errorClass: aborted ? 'timeout' : audit.errorClass,
      routeTrace: audit.routeTrace,
      metadata: {
        delegate_model_slug: modelSlug,
        caller_bot_id: ctx.botId,
        caller_conversation_id: ctx.conversationId,
        error_message: aborted ? 'specialist timeout' : audit.message,
      },
    });
    ctx.emit('tool_result', {
      name: 'delegate_to_specialist',
      model_slug: modelSlug,
      error: aborted ? 'specialist timeout' : errMsg,
    });
    return JSON.stringify({
      error: aborted
        ? `specialist timed out after ${Math.round(SPECIALIST_TIMEOUT_MS / 1000)}s`
        : errMsg,
    });
  } finally {
    clearTimeout(timer);
  }

  ctx.emit('tool_result', {
    name: 'delegate_to_specialist',
    model_slug: modelSlug,
    chars: answer.length,
  });

  return JSON.stringify({
    answer,
    model_slug: modelSlug,
  });
}
