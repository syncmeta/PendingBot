import { randomUUID } from 'node:crypto';
import type {
  ChatCompletionMessageParam,
  ChatCompletionMessageToolCall,
  ChatCompletionTool,
} from 'openai/resources/chat/completions';
import type { Env } from '../types';
import { serviceClient } from './supabase';
import {
  FallbackError,
  recordAudit,
  type ResolvedRoute,
  type RouteTraceEntry,
  usageFromCompletion,
  withFallback,
} from '../llm/router';
import { buildMessages, type BuildMessagesInput } from '../llm/builder';
import { getBotMemory } from './memory';
import { braveSearch, firecrawlScrape } from './web';
import { bootstrapPython, createSandbox, runPython } from './sandbox';

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
// Truncate Firecrawl scrape results so tool replies don't blow past the
// model's context. Plenty for a typical article.
const READ_TRUNCATE_CHARS = 6000;

// Tools exposed to the chat bot. Bot may call any of them mid-reply; the
// runner executes the call, pushes the tool result back into history, and
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
  {
    type: 'function',
    function: {
      name: 'create_skill',
      description:
        '把一段可复用的做事方法保存成对方账号下的「技能」。一旦保存并订阅，下次系统提示词会带上正文。仅在用户明确想要沉淀复用一个流程/角色/写作模板时调用——平时聊天不要用。返回新技能 id。',
      parameters: {
        type: 'object',
        properties: {
          name: {
            type: 'string',
            description: '小写连字符标识，1–80 字符，例如 write-haiku 或 weekly-review-coach。',
          },
          description: {
            type: 'string',
            description: '一句话告诉机器人「什么时候用这个技能」，便于以后判断是否触发。≤ 2000 字符。',
          },
          body: {
            type: 'string',
            description: '技能正文 markdown，订阅后会拼进系统提示词。≤ 64 KiB。',
          },
        },
        required: ['name', 'description', 'body'],
      },
    },
  },
];

// Frontmatter name regex — must match the DB CHECK in 0026.
const SKILL_NAME_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const SKILL_NAME_MAX = 80;
const SKILL_DESC_MAX = 2000;
const SKILL_BODY_MAX = 65536;

// Sensitive tools — appended to the per-turn tools list only when the
// active skill set's frontmatter.allowed_tools opts the user in. The same
// gating model Anthropic Skills uses to keep code-exec out of every chat.
const EXECUTE_CODE_TOOL: ChatCompletionTool = {
  type: 'function',
  function: {
    name: 'execute_code',
    description:
      'Run Python 3 code in a sandboxed VM dedicated to this conversation. Stdout+stderr (combined) and the exit code come back. Useful for math, data wrangling with numpy/pandas, quick scrapes, file/text manipulation. Avoid pop-ups, GUIs, or long-running interactive scripts. The sandbox keeps state across calls in the same conversation, so vars/imports persist for short stretches.',
    parameters: {
      type: 'object',
      properties: {
        code: {
          type: 'string',
          description: 'Python source. Will be executed via Daytona\'s code-run; uses the system python with numpy/pandas/matplotlib/pillow/requests/httpx/python-dateutil pre-installed.',
        },
      },
      required: ['code'],
    },
  },
};

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
  /// Set when conv.conversation_type === 'self'. The bot adopts the
  /// user's display_name + bio as its persona — the conversation reads
  /// as the user talking to a mirror of themselves.
  selfPersona?: { displayName: string; bio: string } | null;
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
  type SkillRow = {
    frontmatter: {
      name?: string;
      description?: string;
      allowed_tools?: unknown;
    };
    body_md: string;
  };
  const skills: Array<{ name: string; description: string; body: string }> = [];
  // Aggregate allowed_tools across the active skill set. Sensitive tools
  // (currently: execute_code) are only exposed when at least one
  // subscribed skill explicitly opts the user in via this list.
  const allowedTools = new Set<string>();
  for (const row of skillsRes.data ?? []) {
    const joined = (row as { skills: SkillRow | SkillRow[] | null }).skills;
    const arr = Array.isArray(joined) ? joined : joined ? [joined] : [];
    for (const s of arr) {
      skills.push({
        name: s.frontmatter?.name ?? 'unnamed',
        description: s.frontmatter?.description ?? '',
        body: s.body_md,
      });
      const tools = s.frontmatter?.allowed_tools;
      if (Array.isArray(tools)) {
        for (const t of tools) if (typeof t === 'string') allowedTools.add(t);
      }
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
    selfPersona: input.selfPersona ?? null,
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
  const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
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

  // Each round inside the agent loop runs its own withFallback — when
  // one provider fails before-first-chunk, the router can re-resolve
  // and try the next-best alias for the same canonical model. Once a
  // stream has started yielding chunks (i.e. bytes have flown to the
  // iOS client), fallback is no longer safe; iteration errors below
  // surface as 'interrupted'/'error' status instead.
  let route: ResolvedRoute | null = null;
  const routeTrace: RouteTraceEntry[] = [];
  emit('typing', { state: 'thinking' });

  // Compose this turn's tool list. Always-on tools come from CHAT_TOOLS;
  // sensitive ones gate behind the subscribed skills' allowed_tools.
  const turnTools: ChatCompletionTool[] = [...CHAT_TOOLS];
  if (allowedTools.has('execute_code')) turnTools.push(EXECUTE_CODE_TOOL);

  try {
    // Outer agent loop. Each iteration is one LLM call. If the model emits
    // tool_calls, we execute them and re-iterate; otherwise we exit.
    for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
      if (ac.signal.aborted) break;

      const roundOpen = await withFallback(
        supa,
        env,
        { modelSlug: bot.model_id, taskType: 'message_reply' },
        (r) =>
          r.client.chat.completions.create(
            {
              model: r.modelToCall,
              messages,
              tools: turnTools,
              tool_choice: 'auto',
              stream: true,
              stream_options: { include_usage: true },
            },
            { signal: ac.signal },
          ),
      );
      const stream = roundOpen.result;
      route = roundOpen.route;
      routeTrace.push(...roundOpen.routeTrace);

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
          const u = usageFromCompletion(chunk.usage);
          usage.input += u.inputTokens ?? 0;
          usage.output += u.outputTokens ?? 0;
          usage.cacheRead += u.cacheReadTokens ?? 0;
          usage.cacheWrite += u.cacheWriteTokens ?? 0;
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
            userId,
            botId: bot.id,
            conversationId,
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

    await recordAudit(supa, route, {
      userId,
      conversationId,
      taskType: 'message_reply',
      startedAt,
      generationId,
      status: 'success',
      routeTrace,
      inputTokens: usage.input,
      outputTokens: usage.output,
      cacheReadTokens: usage.cacheRead,
      cacheWriteTokens: usage.cacheWrite,
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

    // Audit the failed turn so error rate / fallback metrics in the
    // panel see this. Two error paths:
    //   - FallbackError: every alias re-resolution attempt failed
    //     before any stream chunk arrived. lastRoute may be null.
    //     routeTrace shows the chain.
    //   - Anything else (mid-stream throw, tool error, etc.): we
    //     stayed on whatever route last opened a stream. Use the
    //     accumulated routeTrace from prior round successes.
    try {
      const fbErr = err instanceof FallbackError ? err : null;
      const auditRoute = fbErr ? fbErr.lastRoute : route;
      const auditTrace = fbErr ? fbErr.routeTrace : routeTrace;
      const errorClass = aborted
        ? null
        : fbErr
          ? fbErr.routeTrace[fbErr.routeTrace.length - 1]?.error_class ?? 'unknown'
          : err instanceof Error
            ? err.name
            : 'unknown';
      await recordAudit(supa, auditRoute, {
        userId,
        conversationId,
        taskType: 'message_reply',
        startedAt,
        generationId,
        status: aborted ? 'success' : 'error',
        errorClass,
        routeTrace: auditTrace,
        inputTokens: usage.input,
        outputTokens: usage.output,
        cacheReadTokens: usage.cacheRead,
        cacheWriteTokens: usage.cacheWrite,
        metadata: { bot_id: bot.id, status, message: message.slice(0, 200) },
      });
    } catch (auditErr) {
      console.warn('[bot-reply] audit on error failed:', auditErr);
    }

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
  userId: string;
  botId: string;
  conversationId: string;
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
      const hits = await braveSearch(env, query, ctx.signal);
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
      const page = await firecrawlScrape(env, url, ctx.signal);
      ctx.emit('tool_result', { name: 'read_url', title: page.title });
      return JSON.stringify({
        url: page.url,
        title: page.title,
        content: page.content.slice(0, READ_TRUNCATE_CHARS),
      });
    }
    if (name === 'create_skill') {
      return await createSkillTool(env, args, ctx);
    }
    if (name === 'execute_code') {
      return await executeCodeTool(env, args, ctx);
    }
    return JSON.stringify({ error: `unknown tool: ${name}` });
  } catch (err) {
    ctx.emit('tool_result', { name, error: String(err) });
    return JSON.stringify({ error: String(err) });
  }
}

// Inserts a user-owned skill row + auto-subscribes it for the current
// conversation, so the skill takes effect on the very next turn. The skill
// shows up in 我→技能 and the user can promote to global there if they like.
// Bot-private knowledge has its own path (memory.ts/refreshBotNote); this
// tool is exclusively for surfacing a reusable skill into the user's library.
async function createSkillTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const rawName = String(args.name ?? '').trim();
  const description = String(args.description ?? '').trim();
  const body = String(args.body ?? '');

  if (!rawName) return JSON.stringify({ error: 'name is required' });
  if (rawName.length > SKILL_NAME_MAX) {
    return JSON.stringify({ error: `name exceeds ${SKILL_NAME_MAX} chars` });
  }
  if (!SKILL_NAME_RE.test(rawName)) {
    return JSON.stringify({
      error: 'name must be lowercase kebab-case (a-z, 0-9, single hyphens)',
    });
  }
  if (description.length > SKILL_DESC_MAX) {
    return JSON.stringify({ error: `description exceeds ${SKILL_DESC_MAX} chars` });
  }
  if (!body.trim()) return JSON.stringify({ error: 'body is required' });
  if (body.length > SKILL_BODY_MAX) {
    return JSON.stringify({ error: `body exceeds ${SKILL_BODY_MAX} chars` });
  }

  ctx.emit('tool_call', { name: 'create_skill', skill_name: rawName });

  const supa = serviceClient(env);
  const frontmatter: Record<string, string> = { name: rawName, description };
  const { data, error } = await supa
    .from('skills')
    .insert({
      owner_id: ctx.userId,
      bot_id: null,
      user_id: null,
      visibility: 'private',
      frontmatter,
      body_md: body,
    })
    .select('id')
    .single();
  if (error || !data) {
    ctx.emit('tool_result', { name: 'create_skill', error: error?.message ?? 'insert failed' });
    return JSON.stringify({ error: error?.message ?? 'insert failed' });
  }

  // Auto-subscribe for the current conversation so the skill takes effect
  // on the very next turn here. The user can promote it to global from
  // 我→技能 if they like it. Ignore sub errors — the skill row is what
  // matters; the user can toggle on later if the auto-sub didn't land.
  await supa
    .from('skill_subscriptions')
    .insert({ user_id: ctx.userId, skill_id: data.id, conversation_id: ctx.conversationId });

  ctx.emit('tool_result', { name: 'create_skill', skill_id: data.id, skill_name: rawName });
  return JSON.stringify({ skill_id: data.id, name: rawName, subscribed: true });
}

// Run Python in this conversation's dedicated Daytona sandbox. First call
// for a conv lazily provisions a sandbox + pip-installs the common
// data-stack; subsequent calls reuse it. The cron sweep retires idle
// sandboxes; on retirement we'd lose interpreter state, but bootstrap is
// idempotent so the next call just re-provisions.
async function executeCodeTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const code = String(args.code ?? '');
  if (!code.trim()) return JSON.stringify({ error: 'code is required' });

  // First non-empty line of code, capped at 80 chars — gives the chat
  // trace something concrete to show ("import pandas as pd …") rather
  // than a bare byte count.
  const codePreview = code
    .split('\n')
    .map((l) => l.trim())
    .find((l) => l.length > 0)
    ?.slice(0, 80) ?? '';
  ctx.emit('tool_call', {
    name: 'execute_code',
    chars: code.length,
    code_preview: codePreview,
  });

  const supa = serviceClient(env);

  // Look up an existing sandbox for this conversation, or create one.
  // bot_sandbox_sessions has a UNIQUE on conversation_id so the
  // get-or-create race resolves to a single row.
  const existing = await supa
    .from('bot_sandbox_sessions')
    .select('daytona_sandbox_id, bootstrapped')
    .eq('conversation_id', ctx.conversationId)
    .maybeSingle();

  let sandboxId: string;
  let bootstrapped: boolean;
  if (existing.data) {
    sandboxId = existing.data.daytona_sandbox_id;
    bootstrapped = existing.data.bootstrapped;
  } else {
    sandboxId = await createSandbox(env);
    await supa.from('bot_sandbox_sessions').insert({
      conversation_id: ctx.conversationId,
      daytona_sandbox_id: sandboxId,
      bootstrapped: false,
    });
    bootstrapped = false;
  }

  if (!bootstrapped) {
    const boot = await bootstrapPython(env, sandboxId);
    if (boot.exitCode === 0) {
      await supa
        .from('bot_sandbox_sessions')
        .update({ bootstrapped: true, last_used_at: new Date().toISOString() })
        .eq('conversation_id', ctx.conversationId);
    } else {
      // Bootstrap failed — keep the sandbox row so we don't churn through
      // creates on every retry, but report the failure to the model so it
      // can pick a different approach.
      ctx.emit('tool_result', {
        name: 'execute_code',
        error: 'sandbox bootstrap failed',
        exit_code: boot.exitCode,
      });
      return JSON.stringify({
        error: 'sandbox bootstrap failed',
        stderr: boot.stdout.slice(-1000),
      });
    }
  }

  const result = await runPython(env, sandboxId, code);
  await supa
    .from('bot_sandbox_sessions')
    .update({ last_used_at: new Date().toISOString() })
    .eq('conversation_id', ctx.conversationId);

  // Tail of stdout (last ~160 chars, single-lined) so the expanded trace
  // shows what actually printed. Full stdout still goes back to the model
  // via the JSON return — this is purely a UI summary.
  const stdoutTail = result.stdout
    .slice(-160)
    .replace(/\s+/g, ' ')
    .trim();
  ctx.emit('tool_result', {
    name: 'execute_code',
    exit_code: result.exitCode,
    truncated: result.truncated,
    stdout_tail: stdoutTail,
  });
  return JSON.stringify({
    stdout: result.stdout,
    exit_code: result.exitCode,
    truncated: result.truncated,
  });
}
