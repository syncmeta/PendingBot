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
import {
  estimateAssistantOutputTokens,
  estimateRequestInputTokens,
} from '../llm/token-estimate';
import { getBotMemory } from './memory';
import { queryUserRepresentation } from './honcho';
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
      // The result envelope is `{ results: [{ n, url, title, snippet }], hint }`.
      // `n` is a 1-based index, stable across this turn (subsequent calls reuse
      // the same n for already-seen urls). The bot is told to cite a result by
      // dropping `[N]` inline next to whatever fact came from it; iOS reads the
      // citations array stored alongside the message and renders tappable chips.
      description: '搜索互联网。返回最多 8 条结果，每条带 url+标题+摘要+一个 1 基的 `n`。需要事实查证或了解最新信息时使用。在回复里引用某条结果时，请紧跟相关说法加 `[N]` 行内标记（N 对应结果的 n，可以连续如 `[1][3]`），客户端会把它渲染成可点击的小角标。不引用的话不要写 `[N]`。',
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
      name: 'query_user_memory',
      // Honcho dialectic endpoint as a tool. The bot phrases a natural-
      // language question; Honcho's reasoning agent searches everything it's
      // observed about this user across sessions and returns a grounded
      // answer. Use sparingly — each call costs and adds latency. The bot's
      // system prompt already carries the standing user-card + private note,
      // so reach for this only when those leave a real gap.
      description:
        '问 Honcho 一个关于「这个用户」的具体问题，会跨历史会话做检索 + 推理后给出回答。仅在确实需要确认 ta 的偏好/背景/此前说过什么但当前上下文里没有时才用，不是每轮都调。例：「ta 喜欢什么风格的写作反馈？」「ta 之前提过自己的工作吗？」',
      parameters: {
        type: 'object',
        properties: {
          query: {
            type: 'string',
            description: '关于用户的自然语言问题，1–500 字。',
          },
        },
        required: ['query'],
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

// User-approval-gated code execution. Always-on. The bot calls this when
// it wants to run Python; the edge worker pauses the SSE turn, asks iOS
// to render a confirmation card (code preview + reason + ETA), and only
// runs the code once the user taps 跑吧. 算了 / timeout returns the
// decision to the model so it can pick a different approach.
const REQUEST_EXECUTE_CODE_TOOL: ChatCompletionTool = {
  type: 'function',
  function: {
    name: 'request_execute_code',
    description:
      '请求在沙箱里执行 Python 3 代码。**会先弹一张确认卡给用户**（带代码预览、原因、预估耗时），用户点「跑吧」才会真的跑；点「算了」或 120s 超时就不跑。回包里告诉你 approved/denied/timeout，approved 时再附带 stdout+exit_code。需要算数、数据处理、文件/文本变换、抓数据等场景都用它。沙箱按会话绑定，跨调用保留变量/import。除非已从专门技能里拿到了无人值守的 execute_code，跑代码统一走这条路。',
    parameters: {
      type: 'object',
      properties: {
        code: {
          type: 'string',
          description: 'Python 3 源码。沙箱预装 numpy/pandas/matplotlib/pillow/requests/httpx/python-dateutil。',
        },
        reason: {
          type: 'string',
          description: '一句话告诉用户「为什么需要跑这段代码」，会显示在确认卡上，让用户能快速判断要不要批准。中文。',
        },
        estimated_seconds: {
          type: 'integer',
          description: '预估执行耗时（秒）。给用户一个等待预期，普通脚本 1–10 秒就够；最大 600。',
        },
      },
      required: ['code', 'reason', 'estimated_seconds'],
    },
  },
};

// Sensitive tools — appended to the per-turn tools list only when the
// active skill set's frontmatter.allowed_tools opts the user in. The same
// gating model Anthropic Skills uses to keep code-exec out of every chat.
// This is the unsupervised path: kept around for power users who explicitly
// subscribe a skill that grants `allowed_tools: [execute_code]`. Default
// users only see request_execute_code (which gates on a per-call user tap).
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

// How often the request_execute_code tool re-checks the DB for an iOS
// decision, and how long we wait before giving up. 500ms keeps perceived
// latency tight; 120s is plenty for a human to read a card and decide.
const CODE_EXEC_POLL_INTERVAL_MS = 500;
const CODE_EXEC_DECISION_TIMEOUT_MS = 120_000;

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
  /// Per-conversation provider pin (slug from llm_providers.slug, e.g.
  /// 'worldrouter' / 'openrouter'). When set, passed to LLMRouter as
  /// preferProvider; the existing fallback chain still kicks in if the
  /// chosen provider 5xxs. NULL = follow the default routing.
  providerOverride?: string | null;
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
  // Local heuristic estimates, summed across tool-rounds. Sanity-check
  // signal alongside provider-reported usage; persisted to audit_log.
  const est = { input: 0, output: 0 };
  let generationId: string | undefined;

  // Per-turn web-search citations. Every search_web call appends new urls
  // (deduped by url, so `[N]` stays stable across rounds in the same turn).
  // Each emitted bubble row stores the snapshot at insert time — later bubbles
  // may carry a longer list, but earlier ones never reference an [N] beyond
  // their snapshot's bounds.
  const citations: Citation[] = [];

  const emitBubble = async (text: string) => {
    if (!text) return;
    bubbleIndex++;
    const bubbleId = randomUUID();
    const clientMessageId = randomUUID();
    const snapshot = citations.length > 0 ? citations.map((c) => ({ ...c })) : null;
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
      // Cast: schema.ts is regenerated lazily after `supabase db push`; the
      // citations column lands in 0035 but typed-client doesn't know yet.
      citations: snapshot,
    } as never);
    bubblesInserted++;
    emit('bubble', {
      id: bubbleId,
      index: bubbleIndex,
      bubble_group_id: bubbleGroupId,
      content: text,
      citations: snapshot,
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

  // Compose this turn's tool list. Always-on tools come from CHAT_TOOLS,
  // plus request_execute_code (user-approval-gated, safe by construction).
  // Skill-gated tools (currently: unsupervised execute_code) only appear
  // when at least one subscribed skill opts the user in via its
  // frontmatter.allowed_tools.
  const turnTools: ChatCompletionTool[] = [...CHAT_TOOLS, REQUEST_EXECUTE_CODE_TOOL];
  if (allowedTools.has('execute_code')) turnTools.push(EXECUTE_CODE_TOOL);

  try {
    // Outer agent loop. Each iteration is one LLM call. If the model emits
    // tool_calls, we execute them and re-iterate; otherwise we exit.
    for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
      if (ac.signal.aborted) break;

      // Estimate input tokens for this round before sending. messages
      // grows across rounds (we push assistant + tool results onto it),
      // so summing per round mirrors how providers bill cumulative
      // usage across the agentic loop.
      est.input += estimateRequestInputTokens({ messages, tools: turnTools });

      const roundOpen = await withFallback(
        supa,
        env,
        {
          modelSlug: bot.model_id,
          taskType: 'message_reply',
          preferProvider: input.providerOverride ?? undefined,
        },
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

      // Local estimate of what the model emitted this round — visible
      // assistant text plus any tool_call name/arguments JSON it
      // produced. Mirrors the provider-reported completion_tokens.
      est.output += estimateAssistantOutputTokens(assistantContent, toolCalls);

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
            citations,
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
      estInputTokens: est.input,
      estOutputTokens: est.output,
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
        estInputTokens: est.input,
        estOutputTokens: est.output,
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

/// Single web-search citation. Stored on each bubble row's `citations`
/// jsonb so iOS can resolve inline `[N]` markers to a tappable link.
export interface Citation {
  url: string;
  title: string;
  snippet?: string;
}

interface ToolCtx {
  signal: AbortSignal;
  emit: (event: string, data: unknown) => void;
  userId: string;
  botId: string;
  conversationId: string;
  /// Accumulator shared with runChatTurn — search_web pushes deduped hits
  /// here so the per-turn `[N]` numbering stays stable across rounds.
  citations: Citation[];
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
      // Dedupe by url against prior search calls in this same turn so the
      // model sees stable `n`s — once it learned the New York Times piece is
      // [3], that mapping survives a follow-up search that re-surfaces the
      // same article.
      const annotated = hits.slice(0, 8).map((h) => {
        const existing = ctx.citations.findIndex((c) => c.url === h.url);
        let n: number;
        if (existing >= 0) {
          n = existing + 1;
        } else {
          ctx.citations.push({ url: h.url, title: h.title, snippet: h.snippet });
          n = ctx.citations.length;
        }
        return { n, url: h.url, title: h.title, snippet: h.snippet };
      });
      ctx.emit('tool_result', { name: 'search_web', count: annotated.length });
      // Push the cumulative citations list so iOS can resolve `[N]` taps in
      // the live preview before the bubble row hits Realtime.
      ctx.emit('citations', { items: ctx.citations });
      return JSON.stringify({
        results: annotated,
        hint: '若回复里要引用上面某条结果，请在相关说法后跟上 `[N]`（N 对应该条结果的 n）。多个引用可以连写如 `[1][3]`。无须引用就不要写。',
      });
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
    if (name === 'query_user_memory') {
      const query = String(args.query ?? '').trim();
      if (!query) return JSON.stringify({ error: 'empty query' });
      if (query.length > 500) {
        return JSON.stringify({ error: 'query exceeds 500 chars' });
      }
      ctx.emit('tool_call', { name: 'query_user_memory', query });
      const answer = await queryUserRepresentation({
        env,
        userId: ctx.userId,
        conversationId: ctx.conversationId,
        query,
        signal: ctx.signal,
      });
      ctx.emit('tool_result', {
        name: 'query_user_memory',
        chars: answer?.length ?? 0,
      });
      return JSON.stringify({ answer: answer ?? '(no information yet)' });
    }
    if (name === 'create_skill') {
      return await createSkillTool(env, args, ctx);
    }
    if (name === 'execute_code') {
      return await executeCodeTool(env, args, ctx);
    }
    if (name === 'request_execute_code') {
      return await requestExecuteCodeTool(env, args, ctx);
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

// Get-or-create a bootstrapped Daytona sandbox for this conversation.
// First call lazily provisions + pip-installs the common data-stack;
// subsequent calls reuse the same VM. The cron sweep retires idle
// sandboxes — on retirement we'd lose interpreter state, but bootstrap
// is idempotent so the next call just re-provisions.
//
// Returns either { sandboxId } once the sandbox is ready, or
// { error, stderr } if bootstrap blew up (caller turns that into a tool
// error envelope so the model can recover).
async function getOrBootstrapSandbox(
  env: Env,
  conversationId: string,
): Promise<
  | { sandboxId: string }
  | { error: 'bootstrap_failed'; exitCode: number; stderr: string }
> {
  const supa = serviceClient(env);

  // bot_sandbox_sessions has a UNIQUE on conversation_id so the
  // get-or-create race resolves to a single row.
  const existing = await supa
    .from('bot_sandbox_sessions')
    .select('daytona_sandbox_id, bootstrapped')
    .eq('conversation_id', conversationId)
    .maybeSingle();

  let sandboxId: string;
  let bootstrapped: boolean;
  if (existing.data) {
    sandboxId = existing.data.daytona_sandbox_id;
    bootstrapped = existing.data.bootstrapped;
  } else {
    sandboxId = await createSandbox(env);
    await supa.from('bot_sandbox_sessions').insert({
      conversation_id: conversationId,
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
        .eq('conversation_id', conversationId);
    } else {
      // Keep the sandbox row so we don't churn through creates on every
      // retry; let the caller surface the failure to the model.
      return {
        error: 'bootstrap_failed',
        exitCode: boot.exitCode,
        stderr: boot.stdout.slice(-1000),
      };
    }
  }

  return { sandboxId };
}

// Run Python in this conversation's sandbox without user approval. Only
// reachable when a subscribed skill has opted in via allowed_tools.
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

  const sandbox = await getOrBootstrapSandbox(env, ctx.conversationId);
  if ('error' in sandbox) {
    ctx.emit('tool_result', {
      name: 'execute_code',
      error: 'sandbox bootstrap failed',
      exit_code: sandbox.exitCode,
    });
    return JSON.stringify({
      error: 'sandbox bootstrap failed',
      stderr: sandbox.stderr,
    });
  }

  const supa = serviceClient(env);
  const result = await runPython(env, sandbox.sandboxId, code);
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

// User-approval-gated counterpart to execute_code. Inserts a pending row
// into bot_code_exec_requests, emits a `code_exec_request` SSE event so
// iOS can render the confirmation card, then short-polls the row until
// the user taps a button (POST /v1/code-exec-requests/:id/respond
// flips status) or the 120s budget runs out. On `approved` it runs the
// code in this conversation's sandbox and returns combined results to
// the model; on `denied`/`timeout` it returns just the decision so the
// bot can pivot.
async function requestExecuteCodeTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const code = String(args.code ?? '');
  const reason = String(args.reason ?? '').trim();
  // estimated_seconds may arrive as number or stringified-number (some
  // models stringify ints in tool args). Coerce defensively.
  const rawEst = args.estimated_seconds;
  const estimated = typeof rawEst === 'number'
    ? Math.round(rawEst)
    : Math.round(Number(rawEst ?? 0));

  if (!code.trim()) return JSON.stringify({ error: 'code is required' });
  if (!reason) return JSON.stringify({ error: 'reason is required' });
  if (!Number.isFinite(estimated) || estimated < 0 || estimated > 600) {
    return JSON.stringify({ error: 'estimated_seconds must be 0..600' });
  }

  const supa = serviceClient(env);

  // Create the pending row first. iOS uses this row's id both as the
  // approval card's identifier and as the path param it POSTs back to.
  const insert = await supa
    .from('bot_code_exec_requests')
    .insert({
      conversation_id: ctx.conversationId,
      user_id: ctx.userId,
      bot_id: ctx.botId,
      code,
      reason,
      estimated_seconds: estimated,
    } as never)
    .select('id')
    .single();
  if (insert.error || !insert.data) {
    const msg = insert.error?.message ?? 'failed to create approval request';
    ctx.emit('tool_result', { name: 'request_execute_code', error: msg });
    return JSON.stringify({ error: msg });
  }
  const requestId = (insert.data as { id: string }).id;

  // Tell iOS to render the confirmation card. Includes the full code
  // (so user can preview), reason, ETA, and the request id (used both
  // for visual identity and to address the POST decision endpoint).
  ctx.emit('tool_call', {
    name: 'request_execute_code',
    request_id: requestId,
    code,
    reason,
    estimated_seconds: estimated,
  });

  // Poll for decision. The Worker happily holds the SSE response open
  // while we wait — no DOs needed. Caller's signal aborting (user
  // closed the chat tab) cuts us out of the wait promptly.
  const decision = await pollCodeExecDecision(env, requestId, ctx.signal);

  if (decision === 'denied') {
    ctx.emit('tool_result', {
      name: 'request_execute_code',
      request_id: requestId,
      decision: 'denied',
    });
    return JSON.stringify({
      approved: false,
      decision: 'denied',
      hint: '用户拒绝了这次代码执行。换个不需要跑代码的思路，或者在确认能解决问题后再问一次。',
    });
  }
  if (decision === 'timeout') {
    ctx.emit('tool_result', {
      name: 'request_execute_code',
      request_id: requestId,
      decision: 'timeout',
    });
    return JSON.stringify({
      approved: false,
      decision: 'timeout',
      hint: '120 秒内用户没有回应。可以先回复一句话提醒，或者换条不依赖执行代码的路径。',
    });
  }
  if (decision === 'aborted') {
    // Caller's AbortSignal fired (user closed the chat). Don't run code,
    // just bail. The audit/error path upstream already reflects abort.
    return JSON.stringify({ approved: false, decision: 'aborted' });
  }

  // approved → run the code.
  const sandbox = await getOrBootstrapSandbox(env, ctx.conversationId);
  if ('error' in sandbox) {
    ctx.emit('tool_result', {
      name: 'request_execute_code',
      request_id: requestId,
      decision: 'approved',
      error: 'sandbox bootstrap failed',
      exit_code: sandbox.exitCode,
    });
    return JSON.stringify({
      approved: true,
      decision: 'approved',
      error: 'sandbox bootstrap failed',
      stderr: sandbox.stderr,
    });
  }

  const result = await runPython(env, sandbox.sandboxId, code);
  await supa
    .from('bot_sandbox_sessions')
    .update({ last_used_at: new Date().toISOString() })
    .eq('conversation_id', ctx.conversationId);

  const stdoutTail = result.stdout
    .slice(-160)
    .replace(/\s+/g, ' ')
    .trim();
  ctx.emit('tool_result', {
    name: 'request_execute_code',
    request_id: requestId,
    decision: 'approved',
    exit_code: result.exitCode,
    truncated: result.truncated,
    stdout_tail: stdoutTail,
  });
  return JSON.stringify({
    approved: true,
    decision: 'approved',
    stdout: result.stdout,
    exit_code: result.exitCode,
    truncated: result.truncated,
  });
}

// Poll the bot_code_exec_requests row until status leaves 'pending', the
// caller's signal aborts, or our budget runs out. Returns a discriminator
// the caller maps to the model-facing response. On timeout we also flip
// the row to 'timeout' so a stale POST from iOS later finds it already
// resolved (no zombie cards).
async function pollCodeExecDecision(
  env: Env,
  requestId: string,
  signal: AbortSignal,
): Promise<'approved' | 'denied' | 'timeout' | 'aborted'> {
  const supa = serviceClient(env);
  const deadline = Date.now() + CODE_EXEC_DECISION_TIMEOUT_MS;

  while (true) {
    if (signal.aborted) return 'aborted';

    const { data } = await supa
      .from('bot_code_exec_requests')
      .select('status')
      .eq('id', requestId)
      .maybeSingle();
    const status = (data as { status?: string } | null)?.status;
    if (status === 'approved') return 'approved';
    if (status === 'denied') return 'denied';

    if (Date.now() >= deadline) {
      // Best-effort: stamp the row so a late POST from iOS sees a
      // resolved request and the card can dismiss itself. Race-safe via
      // status='pending' guard so we don't clobber a decision that
      // landed in the same tick.
      await supa
        .from('bot_code_exec_requests')
        .update({ status: 'timeout', responded_at: new Date().toISOString() } as never)
        .eq('id', requestId)
        .eq('status', 'pending');
      return 'timeout';
    }

    // Wait, but bail early if the caller aborts mid-sleep.
    await new Promise<void>((resolve) => {
      const t = setTimeout(() => {
        signal.removeEventListener('abort', onAbort);
        resolve();
      }, CODE_EXEC_POLL_INTERVAL_MS);
      const onAbort = () => {
        clearTimeout(t);
        resolve();
      };
      signal.addEventListener('abort', onAbort, { once: true });
    });
  }
}
