import { randomUUID } from 'node:crypto';
import type { ChatCompletionMessageParam } from 'openai/resources/chat/completions';
import type { Env } from '../types';
import { serviceClient } from './supabase';
import { openrouterClient } from '../llm/client';
import { buildMessages, type BuildMessagesInput } from '../llm/builder';
import { getBotMemory } from './memory';

// Multi-bubble splitter — bot's reply may be one continuous block, or several
// short bubbles separated by `\n---\n`. We split server-side so that:
//   - the SSE caller can take the same stream and re-do the split locally
//     (with its own overflow rule for "show streaming after >60 chars")
//   - other devices read the conv from Supabase and get N pre-split message
//     rows (sharing bubble_group_id)
//
// Backend's job is just to persist the canonical shape; the live UI rule is
// in the client.
const BUBBLE_DELIMITER = '\n---\n';
// Magic number for reflection / metrics; the client uses the same threshold
// to decide when to give up waiting for a delimiter and start streaming.
export const BUBBLE_OVERFLOW_CHARS = 60;

export interface RunChatTurnInput {
  env: Env;
  conversationId: string;
  userId: string;
  parentMessageId: string;     // user's just-inserted message id
  bot: {
    id: string;
    model_id: string;
    output_mode: 'single' | 'bubble';
  };
  recentContext: BuildMessagesInput['recentContext'];
  newMessage: string;
  /// Caller-provided AbortSignal (typically `c.req.raw.signal`) — flips when
  /// the SSE client closes the connection.
  signal: AbortSignal;
  /// Stream sink — invoked with each SSE event to push to the caller.
  emit: (event: string, data: unknown) => void;
}

export interface RunChatTurnResult {
  finalStatus: 'done' | 'interrupted' | 'error';
  totalContent: string;
  bubblesInserted: number;
}

// Drives one user→bot turn end to end. Caller wraps a Hono Response around
// a ReadableStream; this function pulls LLM tokens, splits bubbles, persists
// rows, and emits SSE events. Returns when the LLM stream ends (naturally
// or via abort) so the caller can close the response.
export async function runChatTurn(input: RunChatTurnInput): Promise<RunChatTurnResult> {
  const {
    env, conversationId, userId, parentMessageId,
    bot, recentContext, newMessage, signal, emit,
  } = input;
  const supa = serviceClient(env);
  const startedAt = Date.now();

  // 1. Look up self section + skills in parallel. Same shape as B7.3.
  const [botMemory, reflectionsRes, skillsRes] = await Promise.all([
    getBotMemory(env, bot.id),
    supa
      .from('bot_reflections')
      .select('kind, content')
      .eq('bot_id', bot.id)
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(12),
    supa
      .from('skill_subscriptions')
      .select('skills(frontmatter, body_md)')
      .eq('user_id', userId)
      .or(`conversation_id.eq.${conversationId},conversation_id.is.null`),
  ]);
  const reflections = (reflectionsRes.data ?? []) as Array<{
    kind: 'limit' | 'grow' | 'keep';
    content: string;
  }>;
  type SkillRow = { frontmatter: { name?: string; description?: string }; body_md: string };
  const skills: Array<{ name: string; description: string; body: string }> = [];
  for (const row of skillsRes.data ?? []) {
    const joined = (row as { skills: SkillRow | SkillRow[] | null }).skills;
    const arr = Array.isArray(joined) ? joined : joined ? [joined] : [];
    for (const s of arr) {
      skills.push({
        name: s.frontmatter?.name ?? 'unnamed',
        description: s.frontmatter?.description ?? '',
        body: s.body_md,
      });
    }
  }

  // 2. Build prompt. The builder marks the cache breakpoint per plan/02
  // (every 4 rounds; see llm/builder.ts).
  const messages = buildMessages({
    bot, botMemory, reflections, skills, recentContext, newMessage,
  });

  // 3. Stream LLM. AbortSignal propagation: when the client disconnects,
  // signal aborts → openai sdk aborts the upstream fetch.
  const ac = new AbortController();
  const onCallerAbort = () => ac.abort();
  signal.addEventListener('abort', onCallerAbort, { once: true });

  // Bubble grouping: every message in this turn shares one bubble_group_id
  // so the client can group them visually under "this turn's reply".
  const bubbleGroupId = randomUUID();
  let bubbleIndex = 0;
  let pending = '';
  let totalContent = '';
  let bubblesInserted = 0;
  let usage: { input?: number; output?: number; total?: number } = {};
  let generationId: string | undefined;

  const emitBubble = async (text: string) => {
    if (!text) return;
    bubbleIndex++;
    const bubbleId = randomUUID();
    const clientMessageId = randomUUID();
    await supa.from('messages').insert({
      id: bubbleId,
      client_message_id: clientMessageId,
      conversation_id: conversationId,
      sender_bot_id: bot.id,
      role: 'bot',
      status: 'done',
      content: text,
      parent_message_id: parentMessageId,
      bubble_group_id: bubbleGroupId,
    });
    bubblesInserted++;
    emit('bubble', {
      id: bubbleId,
      index: bubbleIndex,
      bubble_group_id: bubbleGroupId,
      content: text,
    });
  };

  try {
    const openai = openrouterClient(env);
    emit('typing', { state: 'thinking' });
    const stream = await openai.chat.completions.create(
      {
        model: bot.model_id,
        messages,
        stream: true,
        stream_options: { include_usage: true },
      },
      { signal: ac.signal },
    );

    for await (const chunk of stream) {
      if (ac.signal.aborted) break;
      const id = (chunk as { id?: string }).id;
      if (id && !generationId) generationId = id;

      const delta = chunk.choices?.[0]?.delta?.content ?? '';
      if (delta) {
        pending += delta;
        totalContent += delta;
        emit('token', { delta });

        // Drain every complete bubble in `pending`. Since the delimiter is
        // multi-char, it may straddle chunks — indexOf handles that.
        // eslint-disable-next-line no-constant-condition
        while (true) {
          const idx = pending.indexOf(BUBBLE_DELIMITER);
          if (idx === -1) break;
          const bubble = pending.slice(0, idx).trim();
          pending = pending.slice(idx + BUBBLE_DELIMITER.length);
          if (bubble) await emitBubble(bubble);
        }
      }

      if (chunk.usage) {
        usage = {
          input: chunk.usage.prompt_tokens,
          output: chunk.usage.completion_tokens,
          total: chunk.usage.total_tokens,
        };
      }
    }

    // Final tail (whatever survived without a trailing delimiter).
    if (pending.trim()) {
      await emitBubble(pending.trim());
      pending = '';
    }

    const finalStatus: RunChatTurnResult['finalStatus'] = ac.signal.aborted ? 'interrupted' : 'done';
    emit(finalStatus, {
      bubble_group_id: bubbleGroupId,
      total_content: totalContent,
    });

    // Audit row (best-effort).
    await supa.from('audit_log').insert({
      user_id: userId,
      conversation_id: conversationId,
      task_type: 'message_reply',
      model_id: bot.model_id,
      input_tokens: usage.input ?? 0,
      output_tokens: usage.output ?? 0,
      total_tokens: usage.total ?? 0,
      generation_id: generationId,
      latency_ms: Date.now() - startedAt,
      metadata: {
        bot_id: bot.id,
        status: finalStatus,
        bubble_group_id: bubbleGroupId,
        bubbles: bubblesInserted,
      },
    });

    return { finalStatus, totalContent, bubblesInserted };
  } catch (err) {
    const aborted = ac.signal.aborted;
    // If pending has anything, save it as the last (interrupted) bubble.
    if (pending.trim()) {
      try { await emitBubble(pending.trim()); } catch {}
    }
    const status: RunChatTurnResult['finalStatus'] = aborted ? 'interrupted' : 'error';
    emit(status, { message: aborted ? 'aborted' : String(err) });
    return { finalStatus: status, totalContent, bubblesInserted };
  } finally {
    signal.removeEventListener('abort', onCallerAbort);
  }
}
