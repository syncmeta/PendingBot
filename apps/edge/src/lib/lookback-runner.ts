import type { Env } from '../types';
import type { ChatCompletionCreateParamsNonStreaming } from 'openai/resources/chat/completions';
import { serviceClient } from './supabase';
import {
  auditErrorFields,
  enqueueAudit,
  usageFromCompletion,
  withFallback,
} from '../llm/router';
import { ensurePromptOverridesLoaded, getPrompt } from '../llm/prompt-loader';
import { uuidv7 } from './ids';

// Lookback runner — invisible to the user, written by the bot for its
// future self.
//
// Trigger cadence is the same as the old auto-review (every N rounds per
// `bot.config.lookback.{enabled,roundInterval}`) but the mechanism is
// totally different: the bot replays the transcript with a special
// instruction asking it to fact-check what either side has said, then
// writes a short note. The note is stored in pendingbot.bot_lookbacks
// (active=true). The Cloudflare realtime hub pushes the row to the
// client (bot_lookbacks AFTER INSERT trigger →
// /v1/realtime-internal/notify → RealtimeHubDO WebSocket — see
// 20260516073714_realtime_webhooks.sql); the client adds the body to
// the next prompt's context, and ~30s later (if the user
// didn't send anything) auto-fires a normal /v1/messages request that
// uses the note. The bot may emit [DROP_LOOKBACK] in a future reply to
// retire the note; otherwise it stays.
//
// Output convention: the LLM either writes a short markdown note OR emits
// [SILENT] when there's nothing worth saying. [SILENT] yields no DB row.

const SILENT_TOKEN = '[SILENT]';
const HISTORY_LIMIT = 30;

export interface RunLookbackInput {
  env: Env;
  conversationId: string;
  botId: string;
}

export async function runLookback(input: RunLookbackInput): Promise<void> {
  const { env, conversationId, botId } = input;
  const supa = serviceClient(env);
  await ensurePromptOverridesLoaded(env);
  const startedAt = Date.now();
  const turnId = uuidv7();

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
      getPrompt('lookback-instruction'),
    ].filter(Boolean).join('\n');

    const { result: completion, route, routeTrace } = await withFallback(
      supa,
      env,
      { modelSlug: botRes.data.model_id as string, taskType: 'lookback', metadata: { turnId } },
      (rt) => {
        const request = {
          model: rt.modelToCall,
          messages: [
            { role: 'system', content: platform },
            { role: 'user', content: userMsg },
          ],
        } as ChatCompletionCreateParamsNonStreaming;
        return rt.client.chat.completions.create(request);
      },
    );

    const text = (completion.choices[0]?.message?.content ?? '').trim();
    const usage = usageFromCompletion(completion.usage, completion);
    if (!text || text === SILENT_TOKEN) {
      await enqueueAudit(env, route, {
        auditId: turnId,
        conversationId,
        taskType: 'lookback',
        startedAt,
        generationId: completion.id,
        status: 'success',
        routeTrace,
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

    await enqueueAudit(env, route, {
      auditId: turnId,
      conversationId,
      taskType: 'lookback',
      startedAt,
      generationId: completion.id,
      status: 'success',
      routeTrace,
      metadata: { bot_id: botId, action: 'note' },
      ...usage,
    });
  } catch (err) {
    console.warn('[lookback]', err);
    const audit = auditErrorFields(err);
    await enqueueAudit(env, audit.route, {
      auditId: turnId,
      conversationId,
      taskType: 'lookback',
      startedAt,
      status: 'error',
      errorClass: audit.errorClass,
      routeTrace: audit.routeTrace,
      metadata: { bot_id: botId, error_message: audit.message },
    });
  }
}
