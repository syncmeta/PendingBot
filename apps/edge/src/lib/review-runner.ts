import { randomUUID } from 'node:crypto';
import type { Env } from '../types';
import { serviceClient } from './supabase';
import { recordAudit, resolveRoute, usageFromCompletion } from '../llm/router';
import { getPrompt } from '../llm/prompt-loader';
import { getBotMemory } from './memory';

// Review agent runner — implements the integrated-into-message-stream review
// per plan/03. Surfaces three families of log messages in the host conv:
//   review:step    — running/done indicators for each phase
//   review:card    — six cards (you|me × limit|grow|keep)
//   review:closing — final note ('pass' or 'note')
//
// The LLM call uses prompts/review.md as system, gets back a tagged response
// (<你-局限>... etc.), parses, and persists `me` reflections to bot_reflections
// for next-turn self section.
//
// Out of scope for this commit:
//   - search round (review's <搜索> block; needs web search tool — defer)
//   - delayed closing delivery (already moot per plan/03 — review lives in
//     the host conv, no separate channel to bridge)

const HISTORY_LIMIT = 30;

const CARD_LABELS: Record<'you' | 'me', Record<'limit' | 'grow' | 'keep', string>> = {
  you: { limit: '你的局限', grow: '你可以发扬的', keep: '你已经在保持的' },
  me: { limit: '我的局限', grow: '我可以发扬的', keep: '我要继续守住的' },
};

const CARD_ORDER: Array<{ side: 'you' | 'me'; bucket: 'limit' | 'grow' | 'keep' }> = [
  { side: 'you', bucket: 'limit' },
  { side: 'you', bucket: 'grow' },
  { side: 'you', bucket: 'keep' },
  { side: 'me', bucket: 'limit' },
  { side: 'me', bucket: 'grow' },
  { side: 'me', bucket: 'keep' },
];

interface ParsedReview {
  you: { limit: string[]; grow: string[]; keep: string[] };
  me: { limit: string[]; grow: string[]; keep: string[] };
  closing: string;
}

function extractTag(text: string, tag: string): string {
  const m = text.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`));
  return m?.[1]?.trim() ?? '';
}

function parseBulletList(raw: string): string[] {
  if (!raw || raw.trim() === '无') return [];
  const out: string[] = [];
  for (const line of raw.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    const stripped = t.replace(/^[-*•]\s+/, '').replace(/^\d+[.、)]\s*/, '').trim();
    if (stripped && stripped !== '无') out.push(stripped);
  }
  return out;
}

function parseReview(text: string): ParsedReview {
  return {
    you: {
      limit: parseBulletList(extractTag(text, '你-局限')),
      grow: parseBulletList(extractTag(text, '你-发扬')),
      keep: parseBulletList(extractTag(text, '你-保持')),
    },
    me: {
      limit: parseBulletList(extractTag(text, '我-局限')),
      grow: parseBulletList(extractTag(text, '我-发扬')),
      keep: parseBulletList(extractTag(text, '我-保持')),
    },
    closing: extractTag(text, '结语'),
  };
}

export interface RunReviewInput {
  env: Env;
  reviewRunId: string;
  conversationId: string;
  userId: string;
  botId: string;
}

async function emitLog(
  supa: ReturnType<typeof serviceClient>,
  conversationId: string,
  reviewRunId: string,
  log_kind: 'review:step' | 'review:card' | 'review:closing',
  payload: Record<string, unknown>,
): Promise<void> {
  await supa.from('messages').insert({
    client_message_id: randomUUID(),
    conversation_id: conversationId,
    role: 'log',
    status: 'done',
    log_kind,
    log_payload: { review_run_id: reviewRunId, ...payload },
  });
}

export async function runReview(input: RunReviewInput): Promise<void> {
  const { env, reviewRunId, conversationId, userId, botId } = input;
  const supa = serviceClient(env);
  const startedAt = Date.now();

  await supa
    .from('review_runs')
    .update({ started_at: new Date().toISOString() })
    .eq('id', reviewRunId);

  try {
    // Phase 1 — gather: pull history + bot model + prior reflections + memory.
    await emitLog(supa, conversationId, reviewRunId, 'review:step', {
      step: 'gather',
      label: '翻一翻最近的对话',
      status: 'running',
    });
    const [historyRes, botRes, reflectionsRes, botMemory] = await Promise.all([
      supa
        .from('messages')
        .select('role, content, created_at')
        .eq('conversation_id', conversationId)
        .neq('role', 'log')
        .order('created_at', { ascending: false })
        .limit(HISTORY_LIMIT),
      supa.from('bots').select('model_id').eq('id', botId).single(),
      supa
        .from('bot_reflections')
        .select('kind, content')
        .eq('bot_id', botId)
        .eq('user_id', userId)
        .order('created_at', { ascending: false })
        .limit(12),
      getBotMemory(env, botId),
    ]);
    const history = (historyRes.data ?? []).reverse() as Array<{
      role: 'user' | 'bot' | 'human';
      content: string | null;
      created_at: string;
    }>;
    if (history.length < 2) {
      await emitLog(supa, conversationId, reviewRunId, 'review:step', {
        step: 'gather',
        label: '翻一翻最近的对话',
        status: 'error',
        detail: '聊得还不够，下次再回头看',
      });
      await supa
        .from('review_runs')
        .update({ status: 'done', finished_at: new Date().toISOString() })
        .eq('id', reviewRunId);
      return;
    }
    await emitLog(supa, conversationId, reviewRunId, 'review:step', {
      step: 'gather',
      label: '翻一翻最近的对话',
      status: 'done',
      detail: `${history.length} 条消息`,
    });

    if (botRes.error || !botRes.data) {
      throw new Error(`bot lookup failed: ${botRes.error?.message}`);
    }
    const modelId = botRes.data.model_id as string;

    // Phase 2 — think: assemble lead-in (memory + prior reflections) and call LLM.
    await emitLog(supa, conversationId, reviewRunId, 'review:step', {
      step: 'thinking',
      label: '慢慢想一遍',
      status: 'running',
      detail: `用 ${modelId}`,
    });

    const reflections = (reflectionsRes.data ?? []) as Array<{
      kind: 'limit' | 'grow' | 'keep';
      content: string;
    }>;
    const leadInParts: string[] = [];
    if (botMemory && botMemory.representation.trim()) {
      leadInParts.push(`我对自己的观察（被动）：\n${botMemory.representation.trim()}`);
    }
    if (reflections.length > 0) {
      const grouped: Record<'limit' | 'grow' | 'keep', string[]> = { limit: [], grow: [], keep: [] };
      for (const r of reflections) grouped[r.kind].push(r.content);
      const lines: string[] = ['我（这个机器人）以前回顾时记下的心得：'];
      if (grouped.limit.length) lines.push('— 我的局限：', ...grouped.limit.map((c) => `  · ${c}`));
      if (grouped.grow.length) lines.push('— 我要发扬的：', ...grouped.grow.map((c) => `  · ${c}`));
      if (grouped.keep.length) lines.push('— 我要守住的：', ...grouped.keep.map((c) => `  · ${c}`));
      leadInParts.push(lines.join('\n'));
    }
    leadInParts.push('（以下是最近的对话历史）');
    const leadIn = leadInParts.join('\n\n');

    const llmHistory = history
      .filter((m) => m.content && m.content.trim().length > 0)
      .map((m) => ({
        role: (m.role === 'user' || m.role === 'human' ? 'user' : 'assistant') as
          | 'user'
          | 'assistant',
        content: m.content as string,
      }));

    const route = await resolveRoute(supa, env, {
      modelSlug: modelId,
      taskType: 'review',
    });
    const completion = await route.client.chat.completions.create({
      model: route.modelToCall,
      messages: [
        { role: 'system', content: getPrompt('review') },
        { role: 'user', content: leadIn },
        ...llmHistory,
        {
          role: 'user',
          content: '请按系统指令对你和对方两边都做一遍回顾，按要求的分段输出。',
        },
      ],
    });
    const rawText = completion.choices[0]?.message?.content?.trim() ?? '';
    const usage = completion.usage;

    await emitLog(supa, conversationId, reviewRunId, 'review:step', {
      step: 'thinking',
      label: '慢慢想一遍',
      status: 'done',
      detail: `${((Date.now() - startedAt) / 1000).toFixed(1)}s · ${usage?.total_tokens ?? 0} tokens`,
    });

    // Phase 3 — parse + emit cards.
    const parsed = parseReview(rawText);
    for (const o of CARD_ORDER) {
      const items = parsed[o.side][o.bucket];
      await emitLog(supa, conversationId, reviewRunId, 'review:card', {
        side: o.side,
        bucket: o.bucket,
        label: CARD_LABELS[o.side][o.bucket],
        items,
      });
    }

    // Phase 4 — persist `me` reflections so the bot accumulates self-knowledge.
    let savedCount = 0;
    const reflectionRows: Array<{
      bot_id: string;
      user_id: string;
      review_run_id: string;
      kind: 'limit' | 'grow' | 'keep';
      content: string;
    }> = [];
    for (const bucket of ['limit', 'grow', 'keep'] as const) {
      for (const item of parsed.me[bucket]) {
        reflectionRows.push({
          bot_id: botId,
          user_id: userId,
          review_run_id: reviewRunId,
          kind: bucket,
          content: item,
        });
      }
    }
    if (reflectionRows.length > 0) {
      const { error: refErr } = await supa.from('bot_reflections').insert(reflectionRows);
      if (refErr) console.warn('[review-runner] reflection insert failed', refErr);
      else savedCount = reflectionRows.length;
    }
    await emitLog(supa, conversationId, reviewRunId, 'review:step', {
      step: 'save',
      label: '把这次的自己记下来',
      status: 'done',
      detail: `${savedCount} 条心得已存`,
    });

    // Phase 5 — closing line (pass or free-form note).
    const closingRaw = parsed.closing.trim();
    const isPass =
      !closingRaw ||
      closingRaw === '[PASS]' ||
      closingRaw === '[OK]' ||
      closingRaw === '[PENDING]';
    await emitLog(supa, conversationId, reviewRunId, 'review:closing', {
      mode: isPass ? 'pass' : 'note',
      content: isPass ? '' : closingRaw,
    });

    // Audit + finalize.
    await recordAudit(supa, route, {
      userId,
      conversationId,
      taskType: 'review',
      startedAt,
      generationId: completion.id,
      status: 'success',
      metadata: { review_run_id: reviewRunId, bot_id: botId },
      ...usageFromCompletion(usage),
    });
    await supa
      .from('review_runs')
      .update({ status: 'done', finished_at: new Date().toISOString() })
      .eq('id', reviewRunId);
  } catch (err) {
    console.error('[review-runner]', err);
    await supa
      .from('review_runs')
      .update({ status: 'error', finished_at: new Date().toISOString() })
      .eq('id', reviewRunId);
  }
}
