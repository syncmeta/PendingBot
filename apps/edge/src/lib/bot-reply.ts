import { randomUUID } from 'node:crypto';
import type {
  ChatCompletionMessageParam,
  ChatCompletionMessageToolCall,
  ChatCompletionTool,
} from 'openai/resources/chat/completions';
import type { Env } from '../types';
import { serviceClient } from './supabase';
import { openrouterClient } from '../llm/client';
import { buildMessages, type BuildMessagesInput } from '../llm/builder';
import { getBotMemory } from './memory';
import { jinaSearch, jinaRead } from './jina';

// How many bot_reflections rows to read for the self section. The schema's
// idx_reflections_bot_user_time covers this exact (bot_id, user_id, created_at)
// access pattern. 12 follows plan/02 and keeps prompt size bounded.
const REFLECTIONS_LIMIT = 12;

// Multi-bubble splitter — bot's reply may be one continuous block, or several
// short bubbles separated by `\n---\n`.
const BUBBLE_DELIMITER = '\n---\n';
export const BUBBLE_OVERFLOW_CHARS = 60;

// Bot's "I have nothing to say" control token (system.md). Dropped if the
// final reply trims to exactly this — no DB row, no bubble event.
const SILENT_TOKEN = '[SILENT]';

// Marker the bot can emit anywhere in its reply (typically the end) to
// flag the active lookback notes as no longer relevant. Stripped from the
// user-visible content; route handler then UPDATEs bot_lookbacks.active=false
// for whichever ids the runner reports.
const DROP_LOOKBACK_TOKEN = '[DROP_LOOKBACK]';

function couldStillBeSilent(s: string): boolean {
  if (s.length === 0) return true;
  if (s.length > SILENT_TOKEN.length) return false;
  return SILENT_TOKEN.startsWith(s);
}

// Maximum agent-loop iterations (one LLM call + tool execution per iteration).
// Bounds runaway tool spam if the model keeps calling tools indefinitely.
const MAX_TOOL_ROUNDS = 6;
// Truncate Jina reader results so tool replies don't blow past the model's
// context. Plenty for a typical article.
const READ_TRUNCATE_CHARS = 6000;

// Tools exposed to the chat bot. Bot may call any of them mid-reply; the
// runner executes via Jina, pushes the tool result back into history, and
// re-invokes the model so it can incorporate findings into the visible reply.
const CHAT_TOOLS: ChatCompletionTool[] = [
  {
    type: 'function',
    function: {
      name: 'search_web',
      description: '搜索互联网。返回最多 8 条 url+标题+摘要。需要事实查证或者了解最新信息时使用。',
      parameters: {
        type: 'object',
        properties: { query: { type: 'string' } },
        required: ['query'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'read_url',
      description: '抓某个网页正文，返回干净 markdown（截断在 6000 字符）。一般在 search_web 看到有钩子的链接后用。',
      parameters: {
        type: 'object',
        properties: { url: { type: 'string' } },
        required: ['url'],
      },
    },
  },
];

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
  /// Lookback notes the client cached. Each is fed into the prompt as a
  /// private context block; the bot decides per turn whether to keep them.
  activeLookbacks?: Array<{ id: string; body_md: string }>;
  signal: AbortSignal;
  emit: (event: string, data: unknown) => void;
}

export interface RunChatTurnResult {
  finalStatus: 'done' | 'interrupted' | 'error';
  totalContent: string;
  bubblesInserted: number;
  /// IDs of lookback notes the bot decided to retire this turn (because
  /// it emitted [DROP_LOOKBACK]). Caller flips active=false for them.
  droppedLookbackIds: string[];
}

export async function runChatTurn(input: RunChatTurnInput): Promise<RunChatTurnResult> {
  const {
    env, conversationId, userId, parentMessageId,
    bot, recentContext, newMessage, signal, emit,
  } = input;
  const activeLookbacks = input.activeLookbacks ?? [];
  const supa = serviceClient(env);
  const startedAt = Date.now();

  // 1. Look up self section + skills + bot-authored note in parallel.
  const [botMemory, reflectionsRes, skillsRes, botNoteRes] = await Promise.all([
    getBotMemory(env, bot.id),
    supa
      .from('bot_reflections')
      .select('kind, content')
      .eq('bot_id', bot.id)
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(REFLECTIONS_LIMIT),
    supa
      .from('skill_subscriptions')
      .select('skills(frontmatter, body_md)')
      .eq('user_id', userId)
      .or(`conversation_id.eq.${conversationId},conversation_id.is.null`),
    supa
      .from('skills')
      .select('body_md')
      .eq('bot_id', bot.id)
      .eq('user_id', userId)
      .maybeSingle(),
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
  const botNote = (botNoteRes.data?.body_md as string | undefined) ?? null;

  // 2. Build prompt. The builder marks the cache breakpoint per plan/02
  // (every 4 rounds; see llm/builder.ts). activeLookbacks become an
  // additional system block so the bot sees its prior fact-check notes.
  const messages: ChatCompletionMessageParam[] = buildMessages({
    bot, botMemory, reflections, skills, botNote,
    lookbacks: activeLookbacks,
    recentContext, newMessage,
  });

  // AbortSignal propagation: caller's signal aborts the upstream openai fetch.
  const ac = new AbortController();
  const onCallerAbort = () => ac.abort();
  signal.addEventListener('abort', onCallerAbort, { once: true });

  // Bubble grouping: every visible message in this turn shares one bubble_group_id.
  const bubbleGroupId = randomUUID();
  let bubbleIndex = 0;
  let pending = '';
  let totalContent = '';
  let emittedLen = 0;
  let bubblesInserted = 0;
  const usage: { input: number; output: number; total: number } = { input: 0, output: 0, total: 0 };
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

  const openai = openrouterClient(env);
  emit('typing', { state: 'thinking' });

  try {
    // Outer agent loop. Each iteration is one LLM call. If the model emits
    // tool_calls, we execute them and re-iterate; otherwise we exit.
    for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
      if (ac.signal.aborted) break;

      const stream = await openai.chat.completions.create(
        {
          model: bot.model_id,
          messages,
          tools: CHAT_TOOLS,
          tool_choice: 'auto',
          stream: true,
          stream_options: { include_usage: true },
        },
        { signal: ac.signal },
      );

      // Per-call accumulators.
      let assistantContent = '';
      const toolCalls: ChatCompletionMessageToolCall[] = [];

      for await (const chunk of stream) {
        if (ac.signal.aborted) break;
        const id = (chunk as { id?: string }).id;
        if (id && !generationId) generationId = id;

        const delta = chunk.choices?.[0]?.delta;

        // Visible content delta.
        const contentDelta = delta?.content ?? '';
        if (contentDelta) {
          pending += contentDelta;
          totalContent += contentDelta;
          assistantContent += contentDelta;

          // Hold token emissions while the cumulative reply could still be
          // the [SILENT] control token. Once the prefix breaks, flush.
          if (!couldStillBeSilent(totalContent.trimStart())) {
            const toEmit = totalContent.slice(emittedLen);
            if (toEmit) emit('token', { delta: toEmit });
            emittedLen = totalContent.length;
          }

          // Drain complete bubbles from pending.
          // eslint-disable-next-line no-constant-condition
          while (true) {
            const idx = pending.indexOf(BUBBLE_DELIMITER);
            if (idx === -1) break;
            const bubble = pending.slice(0, idx).trim();
            pending = pending.slice(idx + BUBBLE_DELIMITER.length);
            if (bubble) await emitBubble(bubble);
          }
        }

        // Tool call streaming. OpenAI emits tool_calls in chunks; merge by
        // index so we end up with one entry per call.
        const tcDeltas = delta?.tool_calls;
        if (tcDeltas) {
          for (const tc of tcDeltas) {
            const i = tc.index;
            if (!toolCalls[i]) {
              toolCalls[i] = {
                id: tc.id ?? '',
                type: 'function',
                function: { name: '', arguments: '' },
              };
            }
            if (tc.id) toolCalls[i].id = tc.id;
            if (tc.function?.name) toolCalls[i].function.name = tc.function.name;
            if (tc.function?.arguments) {
              toolCalls[i].function.arguments += tc.function.arguments;
            }
          }
        }

        if (chunk.usage) {
          usage.input += chunk.usage.prompt_tokens ?? 0;
          usage.output += chunk.usage.completion_tokens ?? 0;
          usage.total += chunk.usage.total_tokens ?? 0;
        }
      }

      // Push the assistant turn (with any tool_calls) into running history
      // so the next iteration sees its own decision.
      if (toolCalls.length > 0) {
        messages.push({
          role: 'assistant',
          content: assistantContent || null,
          tool_calls: toolCalls,
        });
        // Execute tools. Each result becomes a tool message in history.
        for (const tc of toolCalls) {
          const args = safeParseArgs(tc.function.arguments);
          const result = await runTool(env, tc.function.name, args, {
            signal: ac.signal,
            emit,
          });
          messages.push({ role: 'tool', tool_call_id: tc.id, content: result });
        }
        // Loop: the model may want to call more tools or finally produce
        // user-visible content. Carry on.
        continue;
      }

      // No tool calls — this iteration's assistant text IS the final reply.
      messages.push({
        role: 'assistant',
        content: assistantContent || null,
      });
      break;
    }

    // Strip any [DROP_LOOKBACK] marker before emitting the tail bubble
    // OR running the silent check — the marker is a control token, not
    // user-visible content.
    let droppedLookbackIds: string[] = [];
    if (pending.includes(DROP_LOOKBACK_TOKEN) || totalContent.includes(DROP_LOOKBACK_TOKEN)) {
      pending = pending.split(DROP_LOOKBACK_TOKEN).join('').trim();
      totalContent = totalContent.split(DROP_LOOKBACK_TOKEN).join('').trim();
      droppedLookbackIds = activeLookbacks.map((l) => l.id);
    }

    const trimmed = totalContent.trim();
    if (trimmed === SILENT_TOKEN || trimmed === '') {
      emit('silent', { bubble_group_id: bubbleGroupId });
      bubblesInserted = 0;
      pending = '';
    } else if (pending.trim()) {
      await emitBubble(pending.trim());
      pending = '';
    }

    const finalStatus: RunChatTurnResult['finalStatus'] = ac.signal.aborted ? 'interrupted' : 'done';
    if (trimmed !== SILENT_TOKEN) {
      emit(finalStatus, { bubble_group_id: bubbleGroupId, total_content: totalContent });
    }

    await supa.from('audit_log').insert({
      user_id: userId,
      conversation_id: conversationId,
      task_type: 'message_reply',
      model_id: bot.model_id,
      input_tokens: usage.input,
      output_tokens: usage.output,
      total_tokens: usage.total,
      generation_id: generationId,
      latency_ms: Date.now() - startedAt,
      metadata: {
        bot_id: bot.id,
        status: finalStatus,
        bubble_group_id: bubbleGroupId,
        bubbles: bubblesInserted,
      },
    });

    return { finalStatus, totalContent, bubblesInserted, droppedLookbackIds };
  } catch (err) {
    const aborted = ac.signal.aborted;
    if (pending.trim()) {
      try { await emitBubble(pending.trim()); } catch {}
    }
    const status: RunChatTurnResult['finalStatus'] = aborted ? 'interrupted' : 'error';
    // String(err) drops to "" / "[object Object]" for thrown plain objects;
    // dig into common error shapes so the iOS alert shows something useful.
    const message = aborted
      ? 'aborted'
      : (() => {
          if (err instanceof Error) {
            const head = err.message || err.name || 'Error';
            return err.stack ? `${head}\n${err.stack.split('\n').slice(0, 4).join('\n')}` : head;
          }
          if (err && typeof err === 'object') {
            try {
              return JSON.stringify(err).slice(0, 500);
            } catch {
              return Object.prototype.toString.call(err);
            }
          }
          return String(err) || 'unknown error';
        })();
    console.error('[bot-reply] runChatTurn failed:', err);
    emit(status, { message });
    return { finalStatus: status, totalContent, bubblesInserted, droppedLookbackIds: [] };
  } finally {
    signal.removeEventListener('abort', onCallerAbort);
  }
}

// MARK: - Tool execution

function safeParseArgs(s: string): Record<string, unknown> {
  try {
    return JSON.parse(s) as Record<string, unknown>;
  } catch {
    return {};
  }
}

interface ToolCtx {
  signal: AbortSignal;
  emit: (event: string, data: unknown) => void;
}

async function runTool(
  env: Env,
  name: string,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  try {
    if (name === 'search_web') {
      const query = String(args.query ?? '').trim();
      if (!query) return JSON.stringify({ error: 'empty query' });
      ctx.emit('tool_call', { name: 'search_web', query });
      const hits = await jinaSearch(env, query, ctx.signal);
      ctx.emit('tool_result', { name: 'search_web', count: hits.length });
      return JSON.stringify(
        hits.slice(0, 8).map((h) => ({
          url: h.url,
          title: h.title,
          snippet: h.snippet,
        })),
      );
    }
    if (name === 'read_url') {
      const url = String(args.url ?? '').trim();
      if (!url) return JSON.stringify({ error: 'empty url' });
      ctx.emit('tool_call', { name: 'read_url', url });
      const page = await jinaRead(env, url, ctx.signal);
      ctx.emit('tool_result', { name: 'read_url', title: page.title });
      return JSON.stringify({
        url: page.url,
        title: page.title,
        content: page.content.slice(0, READ_TRUNCATE_CHARS),
      });
    }
    return JSON.stringify({ error: `unknown tool: ${name}` });
  } catch (err) {
    ctx.emit('tool_result', { name, error: String(err) });
    return JSON.stringify({ error: String(err) });
  }
}
