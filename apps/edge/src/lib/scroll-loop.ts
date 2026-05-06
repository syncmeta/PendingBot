import type OpenAI from 'openai';
import type {
  ChatCompletionMessageParam,
  ChatCompletionMessageToolCall,
  ChatCompletionTool,
} from 'openai/resources/chat/completions';
import type { WebReadResult, WebSearchResult } from './web-types';

// Pure agent-loop core for the 奏折 (scroll) feature. Lives here, not in
// scroll-runner.ts, so the offline replay harness can import it from
// plain Node/Bun without dragging in `prompt-loader` (which uses
// wrangler's `.md`-as-text loader) or the `Env`-typed worker bindings.

export const HISTORY_LIMIT = 30;
export const HARD_CAP_TURNS = 30;            // safety net against runaway loops
export const MAX_WALL_MS = 4 * 60 * 1000;    // Worker hard cap is ~5min, leave margin
export const READ_TRUNCATE_CHARS = 8000;     // keep tool replies bounded
export const SILENT_TOKEN = '[SILENT]';

export const TOOLS: ChatCompletionTool[] = [
  {
    type: 'function',
    function: {
      name: 'propose_plan',
      description:
        '在执行任何搜索/抓取之前，先用这个工具说明你的思考、想搜的关键词、想直接抓取的网页。用户会确认或给反馈。',
      parameters: {
        type: 'object',
        properties: {
          thoughts: { type: 'string', description: '你围绕朋友的需要、盲区、转向方向等的自由思考' },
          queries: {
            type: 'array',
            items: {
              type: 'object',
              properties: { q: { type: 'string' }, reason: { type: 'string' } },
              required: ['q'],
            },
          },
          urls: {
            type: 'array',
            items: {
              type: 'object',
              properties: { url: { type: 'string' }, reason: { type: 'string' } },
              required: ['url'],
            },
          },
        },
        required: ['thoughts', 'queries', 'urls'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'web_search',
      description: '用配置好的搜索服务商搜索 query，返回若干结果（标题/URL/摘要）。',
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
      name: 'fetch_url',
      description: '用配置好的爬虫服务商抓取一个网页的正文。',
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
      name: 'take_note',
      description: '记录一条对朋友真正有冲击力的笔记。平庸常识不要记。',
      parameters: {
        type: 'object',
        properties: {
          text: { type: 'string' },
          source: { type: 'string', description: '来源 URL，可选' },
        },
        required: ['text'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'decide_write_article',
      description:
        '当你研究够了、要做最终决定时调用此工具：本次到底写不写文章——这是一个二选一。write=true 表示决定写（继续后续流程，由你/写文章模型产出正文）；write=false 表示决定不写（本次结束，不再产出文章）。不写比写一篇平庸的更好。',
      parameters: {
        type: 'object',
        properties: {
          write: {
            type: 'boolean',
            description: 'true = 决定写一篇文章；false = 决定本次不写。',
          },
          reason: {
            type: 'string',
            description: '为什么这么决定。具体说，不要"暂时没想好"这种空话。',
          },
        },
        required: ['write', 'reason'],
      },
    },
  },
];

export interface NoteEntry {
  text: string;
  source?: string;
  t: number;
}

export interface ProgressState {
  phase: 'gather' | 'plan' | 'research' | 'compose' | 'done' | 'error';
  notes: NoteEntry[];
  visited_urls: string[];
  plan_rounds: number;
}

export type ScrollLoopExitReason =
  | 'final'         // model returned an assistant turn with no tool calls
  | 'declined'      // model called decline_to_write — finalArticle empty; reason on result
  | 'turn_cap'      // hit hardCapTurns without a final
  | 'wall_cap'      // hit maxWallMs without a final
  | 'cancelled'     // isCancelled() returned true
  | 'no_choice';    // openai returned an empty choices array

export interface ScrollLoopDeps {
  openai: OpenAI;
  modelId: string;
  systemPrompt: string;
  initialUserContent: string;
  webSearch: (query: string) => Promise<WebSearchResult[]>;
  fetchUrl: (url: string) => Promise<WebReadResult>;
  // Fires after each turn (model call + any tool calls). Use it for
  // progress persistence (worker) or stdout logging (replay script).
  onTurn?: (info: ScrollTurnInfo) => Promise<void> | void;
  // Polled at the top of each iteration. Return true to abort cleanly.
  isCancelled?: () => Promise<boolean>;
  hardCapTurns?: number;
  maxWallMs?: number;
  // Optional: produce the friend-style reply to a propose_plan call.
  // Receives the raw JSON arguments string the model passed; returns
  // the message text fed back as the tool result. When absent, the
  // tool replies with the static "用户：继续，按你的计划执行。"
  simulateUserReply?: (planArgs: string) => Promise<string>;
}

export interface ScrollTurnInfo {
  turn: number;
  progress: ProgressState;
  // Newly appended to the running messages array on this turn — typically
  // the assistant turn plus any role:'tool' replies.
  newMessages: ChatCompletionMessageParam[];
  // Per-turn usage delta + running totals. Lets the dev panel show where
  // tokens accumulate (e.g. fetch_url results inflating next-turn input).
  turnUsage: { input: number; output: number; total: number };
  cumulativeUsage: { input: number; output: number; total: number };
  generationId?: string;
}

export interface ScrollLoopResult {
  finalArticle: string;
  progress: ProgressState;
  usage: { input: number; output: number; total: number };
  lastGenerationId?: string;
  reason: ScrollLoopExitReason;
  // Set when reason === 'declined' — the string the model passed to
  // decline_to_write({ reason }). Surface it to the operator so "空
  // 奏折" isn't ambiguous between error / silent / deliberate decline.
  declineReason?: string;
  // The text from the LAST assistant turn, even when `finalArticle`
  // was rejected as too short / empty. Lets the panel show whatever
  // the model said before it stopped, instead of a blank "(空)".
  lastAssistantText?: string;
  // Full conversation as fed to / produced by the model. Useful for
  // fixtures, debugging, and the replay script.
  messages: ChatCompletionMessageParam[];
  turns: number;
}

export interface ScrollToolDeps {
  webSearch: ScrollLoopDeps['webSearch'];
  fetchUrl: ScrollLoopDeps['fetchUrl'];
}

function safeParse(s: string): Record<string, unknown> {
  try {
    return JSON.parse(s) as Record<string, unknown>;
  } catch {
    return {};
  }
}

export function formatTranscript(
  msgs: Array<{ role: 'user' | 'bot' | 'human'; content: string | null }>,
): string {
  return msgs
    .filter((m) => m.content && m.content.trim())
    .map((m) => `[${m.role === 'bot' ? 'assistant' : 'user'}] ${m.content}`)
    .join('\n');
}

// Title heuristic: prefer the first markdown heading (## Foo / # Foo);
// fall back to the first non-empty line, capped at 30 chars. Returns
// null if neither yields anything.
export function extractTitle(body: string): string | null {
  const lines = body.split('\n').map((l) => l.trim()).filter(Boolean);
  for (const line of lines) {
    const m = line.match(/^#{1,3}\s+(.+)$/);
    if (m) return m[1].trim().slice(0, 30);
  }
  return lines[0] ? lines[0].slice(0, 30) : null;
}

// Summary heuristic: first paragraph (until blank line), markdown stripped,
// capped at 100 chars. Skips a title-like first line if present.
export function extractSummary(body: string): string | null {
  const blocks = body.split(/\n\s*\n/).map((b) => b.trim()).filter(Boolean);
  let first = blocks[0] ?? '';
  if (/^#{1,3}\s+/.test(first) && !first.includes('\n')) first = blocks[1] ?? '';
  if (!first) return null;
  const stripped = first
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/\*([^*]+)\*/g, '$1')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();
  return stripped ? stripped.slice(0, 100) : null;
}

// Build the user-side opener that frames the conversation: bot's long-term
// observation (if any) + recent transcript + the injected directive prompt.
// Same shape used by the worker and the replay harness so they stay aligned.
export function buildScrollInitialUserContent(input: {
  history: Array<{ role: 'user' | 'bot' | 'human'; content: string | null }>;
  memoryRepresentation?: string | null;
  injectedPrompt: string;
}): string {
  const memoryBlock =
    input.memoryRepresentation && input.memoryRepresentation.trim()
      ? `## 我对这位朋友的长期观察\n${input.memoryRepresentation.trim()}\n\n`
      : '';
  const transcript = formatTranscript(input.history);
  return [
    memoryBlock + '## 朋友的聊天记录\n\n' + transcript,
    '---',
    input.injectedPrompt,
    '（请按工具说明的工作节奏推进。）',
  ].join('\n\n');
}

// Pure agent loop — no Supabase, no audit, no row mutation. Both the
// production worker (runScroll in scroll-runner.ts) and the offline
// replay harness (scripts/scroll-replay.ts) call this with their own deps.
export async function runScrollLoop(deps: ScrollLoopDeps): Promise<ScrollLoopResult> {
  const {
    openai,
    modelId,
    systemPrompt,
    initialUserContent,
    onTurn,
    isCancelled,
  } = deps;
  const hardCap = deps.hardCapTurns ?? HARD_CAP_TURNS;
  const wallCap = deps.maxWallMs ?? MAX_WALL_MS;
  const startedAt = Date.now();

  const progress: ProgressState = {
    phase: 'plan',
    notes: [],
    visited_urls: [],
    plan_rounds: 0,
  };
  const usage = { input: 0, output: 0, total: 0 };
  let lastGenerationId: string | undefined;

  const messages: ChatCompletionMessageParam[] = [
    { role: 'system', content: systemPrompt },
    { role: 'user', content: initialUserContent },
  ];

  let finalArticle = '';
  let reason: ScrollLoopExitReason = 'turn_cap';
  let turn = 0;
  let lastAssistantText = '';
  // Mutated by execTool when the model calls decide_write_article.
  //   write === false  → break with reason='declined' (no article)
  //   write === true   → record the decision but keep looping; the
  //     model will then produce its no-tool turn (article in single-
  //     phase, or thinking summary in two-phase) and the loop exits
  //     naturally with reason='final'.
  const decision: { write?: boolean; reason?: string } = {};

  for (turn = 0; turn < hardCap; turn++) {
    if (Date.now() - startedAt > wallCap) {
      reason = 'wall_cap';
      break;
    }
    if (isCancelled && (await isCancelled())) {
      reason = 'cancelled';
      break;
    }

    const completion = await openai.chat.completions.create({
      model: modelId,
      messages,
      tools: TOOLS,
      tool_choice: 'auto',
      parallel_tool_calls: true,
    });
    lastGenerationId = completion.id;
    const turnUsage = {
      input: completion.usage?.prompt_tokens ?? 0,
      output: completion.usage?.completion_tokens ?? 0,
      total: completion.usage?.total_tokens ?? 0,
    };
    usage.input += turnUsage.input;
    usage.output += turnUsage.output;
    usage.total += turnUsage.total;

    const msg = completion.choices[0]?.message;
    if (!msg) {
      reason = 'no_choice';
      break;
    }

    const toolCalls = (msg.tool_calls ?? []) as ChatCompletionMessageToolCall[];
    const assistantContent = msg.content ?? '';
    if (assistantContent.trim()) lastAssistantText = assistantContent;

    // DeepSeek thinking models (deepseek-reasoner / deepseek-v4-flash) put
    // their chain-of-thought on `reasoning_content` and require it to be
    // echoed back on subsequent turns or the API errors with
    // "The reasoning_content in the thinking mode must be passed back".
    // Other providers don't return this field, so the conditional copy is
    // a no-op for them.
    const reasoningContent = (msg as { reasoning_content?: string }).reasoning_content;

    const assistantMsg: ChatCompletionMessageParam & { reasoning_content?: string } = {
      role: 'assistant',
      content: assistantContent,
      ...(toolCalls.length ? { tool_calls: toolCalls } : {}),
    };
    if (reasoningContent) assistantMsg.reasoning_content = reasoningContent;

    const newMessages: ChatCompletionMessageParam[] = [assistantMsg];

    if (toolCalls.length === 0) {
      messages.push(...newMessages);
      finalArticle = assistantContent.trim();
      reason = 'final';
      if (onTurn) {
        await onTurn({
          turn,
          progress,
          newMessages,
          turnUsage,
          cumulativeUsage: { ...usage },
          generationId: completion.id,
        });
      }
      break;
    }

    const toolReplies = await Promise.all(
      toolCalls.map((tc) =>
        execTool(
          { webSearch: deps.webSearch, fetchUrl: deps.fetchUrl },
          tc,
          progress,
          deps.simulateUserReply,
          decision,
        ),
      ),
    );
    for (let i = 0; i < toolCalls.length; i++) {
      newMessages.push({
        role: 'tool',
        tool_call_id: toolCalls[i].id,
        content: toolReplies[i],
      });
    }

    messages.push(...newMessages);
    progress.phase = progress.notes.length > 0 ? 'compose' : 'research';
    if (onTurn) {
      await onTurn({
        turn,
        progress,
        newMessages,
        turnUsage,
        cumulativeUsage: { ...usage },
        generationId: completion.id,
      });
    }

    // Model declined to write — exit cleanly. write=true is recorded
    // but doesn't break: the model still has to produce its final
    // assistant turn (article or thinking) on the next no-tool call.
    if (decision.write === false) {
      reason = 'declined';
      break;
    }
  }

  return {
    finalArticle,
    progress,
    usage,
    lastGenerationId,
    reason,
    // Set whenever decide_write_article was called — `declineReason`
    // continues to carry the model's stated reason regardless of which
    // branch it chose, so the panel can show "decided to write because
    // …" too. The reason='declined' exit only fires on write=false.
    declineReason: decision.reason,
    lastAssistantText: lastAssistantText || undefined,
    messages,
    turns: turn + (reason === 'turn_cap' ? 0 : 1),
  };
}

// Execute a single tool call. Side effects (notes / visited urls) are
// recorded onto `progress` so the runner can persist them. The return
// value is the string content the model sees back.
async function execTool(
  tools: ScrollToolDeps,
  tc: ChatCompletionMessageToolCall,
  progress: ProgressState,
  simulateUserReply?: (planArgs: string) => Promise<string>,
  decision?: { write?: boolean; reason?: string },
): Promise<string> {
  const name = tc.function.name;
  const args = safeParse(tc.function.arguments);
  try {
    if (name === 'propose_plan') {
      progress.plan_rounds++;
      if (simulateUserReply) {
        try {
          const reply = await simulateUserReply(tc.function.arguments);
          const trimmed = reply.trim();
          if (trimmed) return trimmed;
          // Simulator was configured but produced nothing — surface
          // that explicitly so the operator doesn't think the static
          // fallback is intended behavior.
          return '用户：（朋友模型返回空内容，已退回静态回复）继续，按你的计划执行。';
        } catch (err) {
          const msg = String((err as Error)?.message ?? err);
          console.warn('[scroll-loop] simulateUserReply failed:', msg);
          return `用户：（朋友模型出错：${msg}）继续，按你的计划执行。`;
        }
      }
      // No simulator wired (production worker, or panel left blank).
      return '用户：继续，按你的计划执行。';
    }

    if (name === 'decide_write_article') {
      const writeFlag = args.write === true;
      const reasonText = String(args.reason ?? '').trim() || '(no reason given)';
      if (decision) {
        decision.write = writeFlag;
        decision.reason = reasonText;
      }
      return writeFlag
        ? `好的，本次值得写。请按 system prompt 的要求把文章写出来。理由记录在案：${reasonText}`
        : `好的，本次不写——理由：${reasonText}`;
    }

    if (name === 'web_search') {
      const query = String(args.query ?? '').trim();
      if (!query) return JSON.stringify({ error: 'empty query' });
      const hits = await tools.webSearch(query);
      return JSON.stringify({
        query,
        total: hits.length,
        results: hits.slice(0, 8).map((h, i) => ({
          i,
          title: h.title,
          url: h.url,
          snippet: (h.snippet ?? '').slice(0, 300),
          already_fetched: progress.visited_urls.includes(h.url) || undefined,
        })),
      });
    }

    if (name === 'fetch_url') {
      const url = String(args.url ?? '').trim();
      if (!url) return JSON.stringify({ error: 'empty url' });
      if (progress.visited_urls.includes(url)) {
        return '(此 URL 之前已抓取过)';
      }
      progress.visited_urls.push(url);
      const page = await tools.fetchUrl(url);
      const trimmed = (page.content ?? '').slice(0, READ_TRUNCATE_CHARS);
      return trimmed || '(空)';
    }

    if (name === 'take_note') {
      const text = String(args.text ?? '').trim();
      if (!text) return JSON.stringify({ error: 'empty note' });
      const source = typeof args.source === 'string' ? (args.source as string) : undefined;
      const dup = progress.notes.some((n) => n.text === text);
      if (dup) return '(已经记过同样的笔记了，跳过)';
      progress.notes.push({ text, source, t: Date.now() });
      return '已记录';
    }

    return JSON.stringify({ error: `unknown tool: ${name}` });
  } catch (err) {
    return JSON.stringify({ error: String(err) });
  }
}
