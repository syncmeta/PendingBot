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
        '在执行任何搜索/抓取之前，先用这个工具说明你的思考、想先问朋友的问题、想搜的关键词、想直接抓取的网页。用户会确认或给反馈。',
      parameters: {
        type: 'object',
        properties: {
          thoughts: { type: 'string', description: '你围绕朋友的需要、盲区、转向方向等的自由思考' },
          questions_for_user: {
            type: 'array',
            items: { type: 'string' },
            description: '想先问朋友的问题；没有就空数组',
          },
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
        required: ['thoughts', 'questions_for_user', 'queries', 'urls'],
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

    const newMessages: ChatCompletionMessageParam[] = [
      {
        role: 'assistant',
        content: assistantContent,
        ...(toolCalls.length ? { tool_calls: toolCalls } : {}),
      },
    ];

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
      toolCalls.map((tc) => execTool({ webSearch: deps.webSearch, fetchUrl: deps.fetchUrl }, tc, progress)),
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
  }

  return {
    finalArticle,
    progress,
    usage,
    lastGenerationId,
    reason,
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
): Promise<string> {
  const name = tc.function.name;
  const args = safeParse(tc.function.arguments);
  try {
    if (name === 'propose_plan') {
      progress.plan_rounds++;
      // No human in the loop on the server. Auto-confirm so the agent
      // proceeds to research with whatever it just proposed.
      return '用户：继续，按你的计划执行。';
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
