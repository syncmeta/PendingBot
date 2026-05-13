import type { Env } from '../types';
import type { ChatCompletionCreateParamsNonStreaming } from 'openai/resources/chat/completions';
import { serviceClient } from './supabase';
import {
  captureModelCall,
  FallbackError,
  recordAudit,
  type RawModelCall,
  usageFromCompletion,
  withFallback,
} from '../llm/router';
import { ensurePromptOverridesLoaded, getPrompt } from '../llm/prompt-loader';

// Lookback runner — invisible to the user, written by the bot for its
// future self.
//
// Trigger cadence is the same as the old auto-review (every N rounds per
// `bot.config.lookback.{enabled,roundInterval}`) but the mechanism is
// totally different: the bot replays the transcript with a special
// instruction asking it to fact-check what either side has said, then
// writes a short note. The note is stored in pendingbot.bot_lookbacks
// (active=true). Realtime pushes the row to the client; the client adds
// the body to the next prompt's context, and ~30s later (if the user
// didn't send anything) auto-fires a normal /v1/messages request that
// uses the note. The bot may emit [DROP_LOOKBACK] in a future reply to
// retire the note; otherwise it stays.
//
// Output convention: the LLM either writes a short markdown note OR emits
// [SILENT] when there's nothing worth saying. [SILENT] yields no DB row.

const SILENT_TOKEN = '[SILENT]';
const HISTORY_LIMIT = 30;

const LOOKBACK_INSTRUCTION = `以上是你和对方刚刚的聊天记录。

现在系统让你回头看看：你或对方有没有传达过未经查证的信息？

注意：
- 你和对方都不一定是对的。不仅要查证自己说的话，也要看看对方说的是否正确。你们都有可能凭借不实印象信口开河。
- 这是系统自动让你做的回顾，对方不会看到你这次的输出原文。
- 你的输出只会被注入到「下一次回复对方时的你自己」的上下文里，让那时候的你知道这次查证的成果。
- 如果有可以查证的工具/能力，可以使用。
- 如果查证后发现没什么需要说明、更正的，或是没有查证必要的，直接输出 [SILENT] 一个 token 即可。
- 否则，写一段短笔记（控制在 200 字以内）—— 给"下次的你"看，提醒「上一轮里这点其实不太对/需要补正」。

直接开始你的笔记或者 [SILENT]，不要任何前言。`;

export interface RunLookbackInput {
  env: Env;
  conversationId: string;
  botId: string;
}

export async function runLookback(input: RunLookbackInput): Promise<void> {
  const { env, conversationId, botId } = input;
  const supa = serviceClient(env);
  await ensurePromptOverridesLoaded(supa);
  const startedAt = Date.now();
  const rawModelCalls: RawModelCall[] = [];

  try {
    // Pull bot config + recent transcript in parallel.
    const [botRes, msgsRes, activeLookbacksRes] = await Promise.all([
      supa.from('bots').select('model_id, display_name').eq('id', botId).single(),
      supa
        .from('messages')
        .select('role, content, created_at')
        .eq('conversation_id', conversationId)
        .neq('role', 'log')
        .order('created_at', { ascending: false })
        .limit(HISTORY_LIMIT),
      // Existing active lookbacks — surface them so the bot doesn't repeat
      // points it already raised in a still-live note.
      supa
        .from('bot_lookbacks')
        .select('body_md, created_at')
        .eq('conversation_id', conversationId)
        .eq('active', true)
        .order('created_at', { ascending: false })
        .limit(5),
    ]);
    if (botRes.error || !botRes.data) return;
    const recent = (msgsRes.data ?? []).reverse() as Array<{
      role: 'user' | 'bot' | 'human';
      content: string | null;
    }>;
    if (recent.length < 4) return; // not enough material

    const platform = getPrompt('system');
    const transcript = recent
      .filter((m) => m.content && m.content.trim())
      .map((m) => `${m.role === 'bot' ? '我' : '对方'}：${m.content}`)
      .join('\n');
    const prior = (activeLookbacksRes.data ?? [])
      .map((r) => `- ${r.body_md as string}`)
      .join('\n');

    const userMsg = [
      '## 最近的对话',
      transcript,
      prior ? '\n## 我之前已经记下的查证笔记（避免重复）\n' + prior : '',
      '\n## 任务',
      LOOKBACK_INSTRUCTION,
    ].filter(Boolean).join('\n');

    const { result: completion, route, routeTrace } = await withFallback(
      supa,
      env,
      { modelSlug: botRes.data.model_id as string, taskType: 'lookback' },
      (rt) => {
        const request = {
          model: rt.modelToCall,
          messages: [
            { role: 'system', content: platform },
            { role: 'user', content: userMsg },
          ],
        } as ChatCompletionCreateParamsNonStreaming;
        return captureModelCall(rawModelCalls, rt, { taskType: 'lookback', request }, () =>
          rt.client.chat.completions.create(request),
        );
      },
    );

    const text = (completion.choices[0]?.message?.content ?? '').trim();
    const usage = usageFromCompletion(completion.usage, completion);
    if (!text || text === SILENT_TOKEN) {
      await recordAudit(supa, route, {
        conversationId,
        taskType: 'lookback',
        startedAt,
        generationId: completion.id,
        status: 'success',
        routeTrace,
        rawModelCalls,
        metadata: { bot_id: botId, action: 'silent' },
        ...usage,
      });
      return;
    }

    await supa.from('bot_lookbacks').insert({
      conversation_id: conversationId,
      bot_id: botId,
      body_md: text,
      active: true,
    });

    await recordAudit(supa, route, {
      conversationId,
      taskType: 'lookback',
      startedAt,
      generationId: completion.id,
      status: 'success',
      routeTrace,
      rawModelCalls,
      metadata: { bot_id: botId, action: 'note' },
      ...usage,
    });
  } catch (err) {
    console.warn('[lookback]', err);
    if (err instanceof FallbackError) {
      await recordAudit(supa, err.lastRoute, {
        conversationId,
        taskType: 'lookback',
        startedAt,
        status: 'error',
        errorClass:
          err.routeTrace[err.routeTrace.length - 1]?.error_class ?? 'unknown',
        routeTrace: err.routeTrace,
        rawModelCalls,
        metadata: { bot_id: botId },
      });
    }
  }
}
