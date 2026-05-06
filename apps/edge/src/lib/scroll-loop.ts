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
        '在你和协作者**充分讨论**研究方向时使用。说明你的思考、想搜的关键词、想直接抓取的网页。每次调用后协作者会回应——这是来回讨论的工具。**搜索/抓取在 confirm_plan 调用前一直被禁用**，所以先用 propose_plan 反复打磨方案，等双方意见统一了再用 confirm_plan 锁定。',
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
      name: 'confirm_plan',
      description:
        '当你认为方案已经讨论清楚、可以开始研究时调用。注意：这只是你这一方的确认，协作者也必须用它自己的 confirm_plan 工具确认才能解锁 web_search / fetch_url。如果协作者继续给反馈而不确认，请用 propose_plan 接着讨论。',
      parameters: {
        type: 'object',
        properties: {
          summary: {
            type: 'string',
            description: '一两句话总结你和协作者最终敲定的研究方案。',
          },
        },
        required: ['summary'],
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
  // Optional: a separate model that plays a co-explorer chiming in
  // after each non-final turn. Receives the new messages produced this
  // turn (assistant + tool results); returns a string + (optional)
  // usage stats for that secondary call. Returned text is pushed as a
  // `role: 'user'` message before the next iteration. Skipped on
  // decide_write_article turns so the decision executes cleanly, and
  // not invoked when the model produced no tool calls (loop exiting).
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
    // True when the collaborator chose to call its own confirm_plan
    // tool — required (in addition to the main model's confirm_plan)
    // before the loop opens the research gate.
    confirmed?: boolean;
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
  finalArticle: string;
  progress: ProgressState;
  usage: UsageStats;
  collaboratorUsage?: UsageStats;
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

  let finalArticle = '';
  let reason: ScrollLoopExitReason = 'turn_cap';
  let turn = 0;
  let lastAssistantText = '';
  // Research gate. Both sides have to confirm before web_search /
  // fetch_url unblock — the main model via its own confirm_plan tool
  // call, and the collaborator via the confirm_plan tool we hand to
  // it server-side. Until both flips are true, every research call
  // returns a "暂停" message and the discussion continues.
  // Resumed runs detect prior confirmations from saved messages:
  //   - main:   any saved assistant turn with a confirm_plan tool_call
  //   - collab: any saved user message containing the agreement marker
  const COLLAB_CONFIRMED_MARKER = '[协作者同意锁定方案]';
  let mainConfirmed =
    deps.resume?.messages?.some(
      (m) =>
        m.role === 'assistant' &&
        Array.isArray((m as { tool_calls?: Array<{ function: { name: string } }> }).tool_calls) &&
        (m as { tool_calls: Array<{ function: { name: string } }> }).tool_calls.some(
          (tc) => tc.function.name === 'confirm_plan',
        ),
    ) ?? false;
  let collaboratorConfirmed =
    deps.resume?.messages?.some(
      (m) =>
        m.role === 'user' &&
        typeof m.content === 'string' &&
        m.content.includes(COLLAB_CONFIRMED_MARKER),
    ) ?? false;
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
          cumulativeCollaboratorUsage: { ...collaboratorUsage },
          generationId: completion.id,
        });
      }
      break;
    }

    // Gate research tools — when a collaborator is configured, block
    // web_search / fetch_url until BOTH the main model and the
    // collaborator have called confirm_plan. Same-turn parallel
    // confirm_plan + web_search by the main model alone won't open
    // the gate this turn (the collaborator hasn't seen the plan yet);
    // it'll open once the collab also confirms in its response. After
    // both flips, the gate stays open. Worker-side (no collaborator)
    // skips gating entirely.
    const collabConfigured = !!deps.simulateCollaboratorReply;
    const planConfirmThisTurn = toolCalls.some((tc) => tc.function.name === 'confirm_plan');
    if (planConfirmThisTurn) mainConfirmed = true;
    const blockResearch = collabConfigured && !(mainConfirmed && collaboratorConfirmed);

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

    messages.push(...newMessages);
    progress.phase = progress.notes.length > 0 ? 'compose' : 'research';

    // Collaborator chimes in. Skipped on decide_write_article turns so
    // the model's go/no-go executes cleanly; also skipped silently
    // when the simulator throws or returns empty so the loop still
    // progresses. The injected user message lands in newMessages so
    // the panel sees it under the same turn.
    let collaboratorTurnUsage: UsageStats | undefined;
    const decideTurn = toolCalls.some((tc) => tc.function.name === 'decide_write_article');
    if (deps.simulateCollaboratorReply && !decideTurn) {
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
        if (out.confirmed) collaboratorConfirmed = true;
        let bodyText = out.text.trim();
        // Marker is appended to the user message so the trace, the
        // model, and resume detection all see the confirmation.
        if (out.confirmed) {
          bodyText = bodyText
            ? `${bodyText}\n\n${COLLAB_CONFIRMED_MARKER}`
            : COLLAB_CONFIRMED_MARKER;
        }
        if (bodyText) {
          const collaboratorMessage: ChatCompletionMessageParam = {
            role: 'user',
            content: bodyText,
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
    // round, you must decide now". Skipped on decide turns (decision
    // already made) and after the very last turn (no next iteration).
    if (deps.showTurnsRemaining && !decideTurn && turn < hardCap - 1) {
      const remaining = hardCap - turn - 1; // turns including the upcoming one
      const total = hardCap;
      const hintText =
        remaining === 1
          ? `（系统提示：这是最后一轮（${total}/${total}）。本轮必须用 decide_write_article 做最终决定，否则会被 turn_cap 截断。）`
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
    collaboratorUsage:
      collaboratorUsage.total > 0 || collaboratorUsage.input > 0
        ? collaboratorUsage
        : undefined,
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
  decision?: { write?: boolean; reason?: string },
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

    if (name === 'confirm_plan') {
      const summary = String(args.summary ?? '').trim();
      // The actual flag flip lives in the loop body (above) so
      // parallel confirm_plan + web_search in the same turn doesn't
      // miss the gate. Here we just acknowledge.
      return summary
        ? `计划已锁定：${summary} —— web_search / fetch_url 已解锁。`
        : '计划已锁定 —— web_search / fetch_url 已解锁。';
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
      if (blockResearch) {
        return '（已暂停搜索 — 你和协作者必须都用 confirm_plan 工具确认方案后才能开始搜索。继续用 propose_plan 讨论，争取双方都按下确认。）';
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
        return '（已暂停抓取 — 你和协作者必须都用 confirm_plan 工具确认方案后才能开始抓取。继续用 propose_plan 讨论，争取双方都按下确认。）';
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
