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
        '说明你的思考、想搜的关键词、想直接抓取的网页。协作者会回应——这是和协作者来回讨论方案的工具。如果 web_search / fetch_url 此刻被锁着（系统会暂停它们），就先用 propose_plan 把方向打磨清楚。',
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
      description: '用配置好的搜索服务商搜索 query，返回若干结果（标题/URL/摘要）。**搜索结果只在本轮可见——下一轮会被精简成占位符，值得记的请立刻用 take_note 记下，否则就忘了。**',
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
      description: '用配置好的爬虫服务商抓取一个网页的正文。**抓回的页面正文只在本轮可见——下一轮会被精简成占位符，值得记的请立刻用 take_note 记下，否则就忘了。**',
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
      description: '记录一条对朋友真正有冲击力的笔记。平庸常识不要记。**这是把短期信息搬到长期记忆的唯一方式：本轮的搜索/抓取结果下一轮就被精简了，note 不会丢。**',
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
      name: 'stop_exploring',
      description:
        '当你判断已经探索得足够、可以收笔时调用——这是结束探索阶段、立刻进入写作的唯一方式。调用后这一轮就是探索的最后一轮，写作模型会基于你目前的笔记和访问过的链接直接出文。只决定"是否停止探索"，不决定"写不写"——觉得不值得写就别停。',
      parameters: {
        type: 'object',
        properties: {
          reason: {
            type: 'string',
            description: '为什么此刻可以停下了。具体说，不要"差不多了"这种空话。',
          },
        },
        required: ['reason'],
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
  | 'stopped'       // model called stop_exploring — caller runs the writer phase next
  | 'no_tool_call'  // model returned no tool calls (anomaly; only stop_exploring can end exploration)
  | 'turn_cap'      // hit hardCapTurns without ever calling stop_exploring
  | 'wall_cap'      // hit maxWallMs without ever calling stop_exploring
  | 'cancelled'     // isCancelled() returned true
  | 'no_choice';    // openai returned an empty choices array

export interface UsageStats {
  input: number;
  output: number;
  total: number;
  cached: number;
}

export interface ResumeState {
  messages: ChatCompletionMessageParam[];
  progress: ProgressState;
  usage: UsageStats;
  collaboratorUsage?: UsageStats;
}

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
  // Polled before every web_search / fetch_url call. When provided
  // and returns falsy, the tool returns a "暂停" message instead of
  // executing. The panel uses this to gate research manually — flips
  // the flag in real time via /api/runs/:id/state. Worker-side
  // (no callback) leaves search/fetch always-on.
  isResearchUnlocked?: () => boolean | Promise<boolean>;
  // Optional: a separate model that plays a co-explorer chiming in
  // after each non-final turn. Receives the new messages produced this
  // turn (assistant + tool results); returns a string + (optional)
  // usage stats for that secondary call. Returned text is pushed as a
  // `role: 'user'` message before the next iteration. Skipped on:
  //   - stop_exploring turns (decision is final, no review needed)
  //   - turns whose tool calls include web_search / fetch_url
  //     (search/crawl results are deferred — explorer should take
  //     notes next turn first, THEN collaborator reviews the notes).
  simulateCollaboratorReply?: (input: {
    turn: number;
    // Loop's max budget — the server uses this with `turn` to decide
    // whether to surface a "you're on the last round" hint to the
    // collaborator (separate from the main model's hint).
    hardCapTurns: number;
    newMessages: ChatCompletionMessageParam[];
  }) => Promise<{
    text: string;
    usage?: UsageStats;
  }>;
  // When true, append a small system-style user message at the end of
  // each turn telling the model how many turns it has left. Only useful
  // for dev-side iteration — the worker leaves this off.
  showTurnsRemaining?: boolean;
  // For "继续一轮" — load saved messages / progress / usage and pick
  // up where a previous run left off. hardCapTurns then means "this
  // many additional turns from now", not from zero.
  resume?: ResumeState;
}

export interface ScrollTurnInfo {
  turn: number;
  progress: ProgressState;
  // Newly appended to the running messages array on this turn — typically
  // the assistant turn plus any role:'tool' replies (and, when wired,
  // an injected `role: 'user'` collaborator message).
  newMessages: ChatCompletionMessageParam[];
  // Per-turn usage delta + running totals. Lets the dev panel show where
  // tokens accumulate (e.g. fetch_url results inflating next-turn input).
  turnUsage: UsageStats;
  cumulativeUsage: UsageStats;
  // Per-turn / cumulative collaborator (co-explorer) usage; absent on
  // turns where no collaborator call was made.
  collaboratorTurnUsage?: UsageStats;
  cumulativeCollaboratorUsage?: UsageStats;
  generationId?: string;
}

export interface ScrollLoopResult {
  // The loop itself never produces an article — the writer phase
  // (caller-side, after reason==='stopped') is what fills body_md.
  // Kept for compatibility with telemetry; left empty by the loop.
  finalArticle: string;
  progress: ProgressState;
  usage: UsageStats;
  collaboratorUsage?: UsageStats;
  lastGenerationId?: string;
  reason: ScrollLoopExitReason;
  // Set whenever the model called stop_exploring — the reason it
  // gave. Useful for audit / panel display.
  stopReason?: string;
  // The text from the LAST assistant turn (typically the explorer's
  // final musing alongside its stop_exploring call). Surfaced in the
  // panel for inspection.
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

  // Initial state — fresh, or hydrated from a previous run when the
  // panel is "resuming" past a turn_cap exit.
  const progress: ProgressState = deps.resume
    ? {
        ...deps.resume.progress,
        // Pass-by-value so caller's struct can't be mutated mid-loop.
        notes: [...deps.resume.progress.notes],
        visited_urls: [...deps.resume.progress.visited_urls],
      }
    : { phase: 'plan', notes: [], visited_urls: [], plan_rounds: 0 };
  const usage: UsageStats = deps.resume
    ? { ...deps.resume.usage }
    : { input: 0, output: 0, total: 0, cached: 0 };
  const collaboratorUsage: UsageStats = deps.resume?.collaboratorUsage
    ? { ...deps.resume.collaboratorUsage }
    : { input: 0, output: 0, total: 0, cached: 0 };
  let lastGenerationId: string | undefined;

  const messages: ChatCompletionMessageParam[] = deps.resume
    ? [...deps.resume.messages]
    : [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: initialUserContent },
      ];

  let reason: ScrollLoopExitReason = 'turn_cap';
  let turn = 0;
  let lastAssistantText = '';
  // Research gate is now externally controlled via deps.isResearchUnlocked
  // (the panel flips it manually). No internal flag tracking needed —
  // the callback is polled per web_search / fetch_url invocation.
  // Mutated by execTool when the model calls stop_exploring.
  // When set, the loop persists this turn's tool replies + onTurn
  // hook, then breaks with reason='stopped' so the caller can run
  // the writer phase immediately.
  const decision: { stopped?: boolean; reason?: string } = {};

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
    // OpenAI / OpenRouter expose prompt-cache hits via
    // `prompt_tokens_details.cached_tokens`. Anthropic via OpenRouter
    // also fills it. Cast through `unknown` because it's not in the
    // strict type for older SDK versions.
    const promptDetails = (completion.usage as { prompt_tokens_details?: { cached_tokens?: number } } | undefined)
      ?.prompt_tokens_details;
    const turnUsage: UsageStats = {
      input: completion.usage?.prompt_tokens ?? 0,
      output: completion.usage?.completion_tokens ?? 0,
      total: completion.usage?.total_tokens ?? 0,
      cached: promptDetails?.cached_tokens ?? 0,
    };
    usage.input += turnUsage.input;
    usage.output += turnUsage.output;
    usage.total += turnUsage.total;
    usage.cached += turnUsage.cached;

    const msg = completion.choices[0]?.message;
    if (!msg) {
      reason = 'no_choice';
      break;
    }

    const toolCalls = (msg.tool_calls ?? []) as ChatCompletionMessageToolCall[];
    const assistantContent = msg.content ?? '';
    if (assistantContent.trim()) lastAssistantText = assistantContent;

    // DeepSeek thinking models (deepseek-reasoner / deepseek-v4-flash)
    // put chain-of-thought on `reasoning_content`. We display it in
    // the panel via newMessages but DO NOT echo it back to the API
    // (saves tokens, especially over many turns). Trade-off: those
    // models will reject subsequent turns with "must be passed back"
    // — switch to a non-thinking model if you hit that.
    const reasoningContent = (msg as { reasoning_content?: string }).reasoning_content;

    const assistantForApi: ChatCompletionMessageParam = {
      role: 'assistant',
      content: assistantContent,
      ...(toolCalls.length ? { tool_calls: toolCalls } : {}),
    };
    const assistantForDisplay: ChatCompletionMessageParam & { reasoning_content?: string } =
      reasoningContent ? { ...assistantForApi, reasoning_content: reasoningContent } : assistantForApi;

    // Two arrays diverge from here:
    //  - newMessages → panel + collectedTurns (immutable record)
    //  - messages    → next API call (mutated each turn for prune)
    const newMessages: ChatCompletionMessageParam[] = [assistantForDisplay];

    if (toolCalls.length === 0) {
      // Anomalous exit — the only valid way to end exploration is
      // stop_exploring. Bail with no_tool_call so the caller can
      // surface this as an error state rather than mistakenly
      // treating the assistant text as a finished article.
      messages.push(assistantForApi);
      reason = 'no_tool_call';
      if (onTurn) {
        await onTurn({
          turn,
          progress,
          newMessages,
          turnUsage,
          cumulativeUsage: { ...usage },
          cumulativeCollaboratorUsage: { ...collaboratorUsage },
          generationId: completion.id,
        });
      }
      break;
    }

    // Research gate — poll the manual switch from deps if provided.
    // No callback (worker) → research always allowed.
    const researchUnlocked = deps.isResearchUnlocked
      ? await deps.isResearchUnlocked()
      : true;
    const blockResearch = !researchUnlocked;

    const toolReplies = await Promise.all(
      toolCalls.map((tc) =>
        execTool(
          { webSearch: deps.webSearch, fetchUrl: deps.fetchUrl },
          tc,
          progress,
          decision,
          blockResearch,
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

    // Prune prior tool messages BEFORE pushing this turn's. We replace
    // each tool slot with a small placeholder object so the API still
    // sees a valid tool reply for every tool_call_id but past results
    // (often huge fetch_url bodies) don't keep ballooning input
    // tokens. Importantly we mutate the messages[] slot only; the
    // previous-turn newMessages we already streamed to the panel is
    // a separate array and untouched, so the trace + saved run JSON
    // still preserve the original content for inspection.
    const PRUNED_TOOL = '(已精简——本轮的搜索/抓取结果只在当时可见。如果当时没用 take_note 记下，就丢了。)';
    for (let i = 0; i < messages.length; i++) {
      const m = messages[i];
      if (m.role === 'tool' && m.content !== PRUNED_TOOL) {
        messages[i] = {
          role: 'tool',
          tool_call_id: (m as { tool_call_id: string }).tool_call_id,
          content: PRUNED_TOOL,
        };
      }
    }

    // Push this turn's API-bound view: stripped assistant + fresh
    // tool replies (these will get pruned next turn).
    messages.push(assistantForApi);
    for (let i = 0; i < toolCalls.length; i++) {
      messages.push({
        role: 'tool',
        tool_call_id: toolCalls[i].id,
        content: toolReplies[i],
      });
    }
    progress.phase = progress.notes.length > 0 ? 'compose' : 'research';

    // Collaborator chimes in. Skipped on:
    //  - stop_exploring turns (decision is final)
    //  - turns whose tool calls include web_search / fetch_url —
    //    the explorer should take notes from those results next
    //    turn first, and the collaborator reviews the notes (not
    //    the raw search/crawl payload).
    // Also skipped silently when the simulator throws or returns
    // empty so the loop still progresses. The injected user message
    // lands in newMessages so the panel sees it under the same turn.
    let collaboratorTurnUsage: UsageStats | undefined;
    const stopTurn = toolCalls.some((tc) => tc.function.name === 'stop_exploring');
    const researchTurn = toolCalls.some(
      (tc) => tc.function.name === 'web_search' || tc.function.name === 'fetch_url',
    );
    const skipCollaborator = stopTurn || researchTurn;
    if (deps.simulateCollaboratorReply && !skipCollaborator) {
      try {
        const out = await deps.simulateCollaboratorReply({
          turn,
          hardCapTurns: hardCap,
          newMessages: [...newMessages],
        });
        if (out.usage) {
          collaboratorTurnUsage = out.usage;
          collaboratorUsage.input += out.usage.input;
          collaboratorUsage.output += out.usage.output;
          collaboratorUsage.total += out.usage.total;
          collaboratorUsage.cached += out.usage.cached;
        }
        const trimmed = out.text.trim();
        if (trimmed) {
          const collaboratorMessage: ChatCompletionMessageParam = {
            role: 'user',
            content: trimmed,
          };
          messages.push(collaboratorMessage);
          newMessages.push(collaboratorMessage);
        }
      } catch (err) {
        const msg = String((err as Error)?.message ?? err);
        console.warn('[scroll-loop] collaborator failed:', msg);
        // Surface as an inline note so the panel trace shows the failure.
        const note: ChatCompletionMessageParam = {
          role: 'user',
          content: `（协作者出错，跳过本轮介入：${msg}）`,
        };
        messages.push(note);
        newMessages.push(note);
      }
    }

    // Optional budget hint — when enabled, append a `role:'user'`
    // system-style note telling the model how many turns it has left.
    // Wording escalates on the last upcoming turn: "this is the last
    // round, you must decide now". Skipped on stop turns (decision
    // already made) and after the very last turn (no next iteration).
    if (deps.showTurnsRemaining && !stopTurn && turn < hardCap - 1) {
      const remaining = hardCap - turn - 1; // turns including the upcoming one
      const total = hardCap;
      const hintText =
        remaining === 1
          ? `（系统提示：这是最后一轮（${total}/${total}）。本轮必须用 stop_exploring 收笔，否则会被 turn_cap 截断。）`
          : `（系统提示：还剩 ${remaining}/${total} 轮研究/工具调用机会。）`;
      const hint: ChatCompletionMessageParam = { role: 'user', content: hintText };
      messages.push(hint);
      newMessages.push(hint);
    }

    if (onTurn) {
      await onTurn({
        turn,
        progress,
        newMessages,
        turnUsage,
        cumulativeUsage: { ...usage },
        collaboratorTurnUsage,
        cumulativeCollaboratorUsage: { ...collaboratorUsage },
        generationId: completion.id,
      });
    }

    // Model called stop_exploring — exit immediately so the caller
    // can run the writer phase. The tool replies and onTurn for this
    // final exploration turn have already been emitted above; the
    // writer phase is owned by the caller (production runner reads
    // scroll-write.md; lab uses its own writePhasePrompt).
    if (decision.stopped) {
      reason = 'stopped';
      break;
    }
  }

  return {
    // Loop never produces an article on its own anymore; left empty
    // for callers that still read the field. They fill it from the
    // writer phase before persisting.
    finalArticle: '',
    progress,
    usage,
    collaboratorUsage:
      collaboratorUsage.total > 0 || collaboratorUsage.input > 0
        ? collaboratorUsage
        : undefined,
    lastGenerationId,
    reason,
    stopReason: decision.reason,
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
  decision?: { stopped?: boolean; reason?: string },
  blockResearch?: boolean,
): Promise<string> {
  const name = tc.function.name;
  const args = safeParse(tc.function.arguments);
  try {
    if (name === 'propose_plan') {
      progress.plan_rounds++;
      // No reply text. The collaborator (if configured) speaks for
      // itself in a separate `role: 'user'` message that the loop
      // injects after the tool results. When no collaborator is
      // wired, the model just sees an empty acknowledgement and
      // proceeds with its own plan. Empty string is safer than
      // `null` — some providers reject null content on tool roles.
      return '';
    }

    if (name === 'stop_exploring') {
      const reasonText = String(args.reason ?? '').trim() || '(no reason given)';
      if (decision) {
        decision.stopped = true;
        decision.reason = reasonText;
      }
      return `好的，停止探索。写作模型会基于你的笔记和访问过的链接出文。理由记录在案：${reasonText}`;
    }

    if (name === 'web_search') {
      if (blockResearch) {
        return '（搜索已被操作员暂停。继续用 propose_plan 讨论方案，等操作员开了搜索权限再调用。）';
      }
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
      if (blockResearch) {
        return '（抓取已被操作员暂停。继续用 propose_plan 讨论方案，等操作员开了抓取权限再调用。）';
      }
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
