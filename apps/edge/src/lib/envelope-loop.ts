import type {
  ChatCompletion,
  ChatCompletionMessageParam,
  ChatCompletionMessageToolCall,
  ChatCompletionCreateParamsNonStreaming,
  ChatCompletionTool,
} from 'openai/resources/chat/completions';
import {
  mergeProviderUsageDetails,
  usageFromCompletion,
  type ProviderUsageDetails,
} from '../llm/provider-usage';
import type { WebReadResult, WebSearchResult } from './web-types';

// Pure agent-loop core for the envelope feature (来信). Lives here,
// not in envelope-runner.ts, so the offline
// replay harness can import it from plain Node/Bun without dragging in
// `prompt-loader` (which uses wrangler's `.md`-as-text loader) or the
// `Env`-typed worker bindings.

export const HISTORY_LIMIT = 30;
export const HARD_CAP_TURNS = 30;            // safety net against runaway loops
export const MAX_WALL_MS = 4 * 60 * 1000;    // Worker hard cap is ~5min, leave margin
export const READ_TRUNCATE_CHARS = 8000;     // keep tool replies bounded
export const SILENT_TOKEN = '[SILENT]';

// Per-tool-call hard timeout. Without these, a hung Firecrawl scrape
// or a stalled Brave query would block the loop indefinitely — the
// for-loop's MAX_WALL_MS check only fires between turns, so a tool
// await would never cede back. Tripping these surfaces an error string
// to the model on the same turn so it can move on.
export const WEB_SEARCH_TIMEOUT_MS = 30 * 1000;
export const FETCH_URL_TIMEOUT_MS = 60 * 1000;

// Promise.race against a setTimeout — rejects with a labeled Error so
// the per-tool catch in execTool can stringify it cleanly. The original
// promise keeps running (we don't have an abort signal threaded through
// the provider HTTP calls yet); when it eventually resolves the result
// is dropped. That's fine for one-shot calls; revisit if it ever causes
// resource leaks.
async function withTimeout<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
  let to: ReturnType<typeof setTimeout> | undefined;
  const timer = new Promise<never>((_, reject) => {
    to = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);
  });
  try {
    return await Promise.race([p, timer]);
  } finally {
    if (to) clearTimeout(to);
  }
}

// Envelope-stage tools. As with bot-reply/tool-defs.ts, the model-facing
// `function.description` is NOT defined here — it's the single source of
// truth in pendingbot.tools.model_description and gets swapped in by
// applyToolRegistry at runner-assembly time. Only name + parameter schema
// live in code.
export const TOOLS: ChatCompletionTool[] = [
  {
    type: 'function',
    function: {
      name: 'propose_plan',
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
  // Live "what's happening right now" line written between awaits (model
  // call → tool execution → collaborator). UI surfaces this next to the
  // typing dots so a long single turn doesn't look frozen. Cleared at
  // the end of a turn so the phase label takes over until the next.
  current_activity?: string | null;
}

export type EnvelopeLoopExitReason =
  | 'stopped'       // model called stop_exploring — caller runs the writer phase next
  | 'no_tool_call'  // model returned no tool calls (anomaly; only stop_exploring can end exploration)
  | 'turn_cap'      // hit hardCapTurns without ever calling stop_exploring
  | 'wall_cap'      // hit maxWallMs without ever calling stop_exploring
  | 'cancelled'     // isCancelled() returned true
  | 'no_choice';    // openai returned an empty choices array

export interface UsageStats extends ProviderUsageDetails {
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

export interface ChatCompletionClient {
  chat: {
    completions: {
      create(
        request: ChatCompletionCreateParamsNonStreaming,
      ): PromiseLike<ChatCompletion>;
    };
  };
}

export interface EnvelopeLoopDeps {
  openai: ChatCompletionClient;
  modelId: string;
  systemPrompt: string;
  initialUserContent: string;
  webSearch: (query: string) => Promise<WebSearchResult[]>;
  fetchUrl: (url: string) => Promise<WebReadResult>;
  // Fires after each turn (model call + any tool calls). Use it for
  // progress persistence (worker) or stdout logging (replay script).
  onTurn?: (info: EnvelopeTurnInfo) => Promise<void> | void;
  // Fires between awaits inside a turn so the UI can show a live
  // "current_activity" line — "主探索者在思考…", "正在搜索 X", "协作者
  // 在评议…". The runner persists each snapshot to envelope_runs.progress
  // so iOS Realtime gets ticks within a single long turn instead of one
  // bulk update at the end. Snapshot is a fresh object — caller is free
  // to keep it.
  onActivity?: (snapshot: ProgressState) => Promise<void> | void;
  // Polled at the top of each iteration. Return true to abort cleanly.
  isCancelled?: () => Promise<boolean>;
  hardCapTurns?: number;
  maxWallMs?: number;
  /// Override the advertised tool list. Defaults to `TOOLS` (every
  /// envelope-stage tool). The runner-side filter from
  /// `applyToolRegistry` passes a pruned subset so disabling a row in
  /// the board "Tools" page strips it here.
  tools?: ChatCompletionTool[];
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

export interface EnvelopeTurnInfo {
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

export interface EnvelopeLoopResult {
  // The loop itself never produces an article — the writer phase
  // (caller-side, after reason==='stopped') is what fills body_md.
  // Kept for compatibility with telemetry; left empty by the loop.
  finalArticle: string;
  progress: ProgressState;
  usage: UsageStats;
  collaboratorUsage?: UsageStats;
  lastGenerationId?: string;
  reason: EnvelopeLoopExitReason;
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

export interface EnvelopeToolDeps {
  webSearch: EnvelopeLoopDeps['webSearch'];
  fetchUrl: EnvelopeLoopDeps['fetchUrl'];
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
// fall back to the first non-empty line. Hard-capped slightly above the
// prompt's 24-char request so a one-character overshoot still fits;
// well-behaved output won't hit this limit. Returns null if neither
// yields anything.
export function extractTitle(body: string): string | null {
  const lines = body.split('\n').map((l) => l.trim()).filter(Boolean);
  for (const line of lines) {
    const m = line.match(/^#{1,3}\s+(.+)$/);
    if (m) return m[1].trim().slice(0, 32);
  }
  return lines[0] ? lines[0].slice(0, 32) : null;
}

// Summary heuristic. The current prompt asks for an explicit subtitle as
// a `> blockquote` right after the H1; prefer that. Fall back to the
// legacy "first paragraph" behaviour for bodies written before the
// format change. Capped slightly above the prompt's 60-char request so
// the feed cover doesn't truncate well-formed output.
export function extractSummary(body: string): string | null {
  const blocks = body.split(/\n\s*\n/).map((b) => b.trim()).filter(Boolean);
  if (blocks.length === 0) return null;

  // Locate the explicit subtitle blockquote — the first `> ...` block
  // we hit before any non-heading paragraph counts as the subtitle.
  for (const block of blocks) {
    if (/^#{1,3}\s+/.test(block) && !block.includes('\n')) continue;
    if (block.startsWith('>')) {
      const subtitle = block
        .split('\n')
        .map((l) => l.replace(/^>\s?/, '').trim())
        .filter(Boolean)
        .join(' ');
      const stripped = stripInlineMarkdown(subtitle);
      if (stripped) return stripped.slice(0, 80);
    }
    break;
  }

  // Legacy fallback: first non-heading paragraph.
  let first = blocks[0] ?? '';
  if (/^#{1,3}\s+/.test(first) && !first.includes('\n')) first = blocks[1] ?? '';
  if (!first) return null;
  const stripped = stripInlineMarkdown(first);
  return stripped ? stripped.slice(0, 100) : null;
}

function stripInlineMarkdown(text: string): string {
  return text
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/^>\s?/gm, '')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/\*([^*]+)\*/g, '$1')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();
}

// Strip the leading H1 + subtitle blockquote from a finished article so
// the stored body_md is just the body. The header on iOS already
// surfaces title and subtitle from their own columns; rendering them a
// second time inside the markdown body duplicates them on screen.
export function stripLeadingTitleAndSubtitle(body: string): string {
  const lines = body.split('\n');
  let i = 0;

  // Skip blank lines.
  while (i < lines.length && lines[i].trim() === '') i++;

  // Drop a single leading H1/H2/H3 line if present.
  if (i < lines.length && /^\s*#{1,3}\s+/.test(lines[i])) {
    i++;
    while (i < lines.length && lines[i].trim() === '') i++;
  }

  // Drop a leading blockquote (the subtitle) — every consecutive `> `
  // line plus the blank line that closes it.
  if (i < lines.length && /^\s*>/.test(lines[i])) {
    while (i < lines.length && /^\s*>/.test(lines[i])) i++;
    while (i < lines.length && lines[i].trim() === '') i++;
  }

  return lines.slice(i).join('\n').trim();
}

// Build the user-side opener that frames the conversation: bot's long-term
// observation (if any) + recent transcript + the injected directive prompt.
// Same shape used by the worker and the replay harness so they stay aligned.
export function buildEnvelopeInitialUserContent(input: {
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

// Pure agent loop — no Supabase, no audit, no row mutation. The production
// worker shell in envelope-runner.ts supplies persistence, billing, and
// runtime tool dependencies around this core loop.
export async function runEnvelopeLoop(deps: EnvelopeLoopDeps): Promise<EnvelopeLoopResult> {
  const {
    openai,
    modelId,
    systemPrompt,
    initialUserContent,
    onTurn,
    onActivity,
    isCancelled,
  } = deps;
  // Heartbeat helper — sets progress.current_activity and flushes via
  // onActivity. Snapshot is a shallow copy so the runner can update its
  // db row without us mutating it later. Awaiting keeps order, but the
  // runner is free to fire-and-forget by not awaiting inside.
  const setActivity = async (text: string | null): Promise<void> => {
    progress.current_activity = text;
    if (!onActivity) return;
    await onActivity({
      ...progress,
      notes: [...progress.notes],
      visited_urls: [...progress.visited_urls],
    });
  };
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

  let reason: EnvelopeLoopExitReason = 'turn_cap';
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

    await setActivity(turn === 0 ? '主探索者在思考开场…' : '主探索者在想下一步…');
    const request = {
      model: modelId,
      messages,
      tools: deps.tools ?? TOOLS,
      tool_choice: 'auto',
      parallel_tool_calls: true,
    } as ChatCompletionCreateParamsNonStreaming;
    const completion = await openai.chat.completions.create(request);
    lastGenerationId = completion.id;
    // OpenAI / OpenRouter expose prompt-cache hits via
    // `prompt_tokens_details.cached_tokens`. Anthropic via OpenRouter
    // also fills it. Cast through `unknown` because it's not in the
    // strict type for older SDK versions.
    const providerUsage = usageFromCompletion(completion.usage, completion);
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
    mergeProviderUsageDetails(usage, providerUsage);

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
      progress.current_activity = null;
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

    await setActivity(summarizeToolActivity(toolCalls));
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
      await setActivity('协作者在评议…');
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
          mergeProviderUsageDetails(collaboratorUsage, out.usage);
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
        console.warn('[envelope-loop] collaborator failed:', msg);
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

    progress.current_activity = null;
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
    // the 'envelope-write' prompt; lab uses its own writePhasePrompt).
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

// One-line "what's about to happen" string shown next to the typing
// dots while a turn's tools are executing. Picks a representative tool
// (search query / fetched host / first note) so the user sees concrete
// progress, not a generic "正在工作".
function summarizeToolActivity(toolCalls: ChatCompletionMessageToolCall[]): string {
  if (toolCalls.length === 0) return '主探索者在落笔…';
  const parts: string[] = [];
  for (const tc of toolCalls) {
    const args = safeParse(tc.function.arguments);
    const name = tc.function.name;
    if (name === 'web_search') {
      const q = String(args.query ?? '').trim();
      if (q) parts.push(`搜索 "${q.slice(0, 40)}"`);
      else parts.push('搜索');
    } else if (name === 'fetch_url') {
      const url = String(args.url ?? '').trim();
      let host = url;
      try { host = new URL(url).host.replace(/^www\./, ''); } catch { /* keep raw */ }
      parts.push(`读 ${host.slice(0, 40)}`);
    } else if (name === 'take_note') {
      const text = String(args.text ?? '').trim();
      parts.push(text ? `记 "${text.slice(0, 30)}"` : '记笔记');
    } else if (name === 'propose_plan') {
      parts.push('和协作者过方案');
    } else if (name === 'stop_exploring') {
      parts.push('准备收笔');
    }
  }
  if (parts.length === 0) return '主探索者在落笔…';
  // Cap the line — multi-tool turns can otherwise produce a wall of text.
  const joined = parts.slice(0, 3).join(' · ');
  return parts.length > 3 ? `${joined}…` : joined;
}

// Execute a single tool call. Side effects (notes / visited urls) are
// recorded onto `progress` so the runner can persist them. The return
// value is the string content the model sees back.
async function execTool(
  tools: EnvelopeToolDeps,
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
      const hits = await withTimeout(
        tools.webSearch(query),
        WEB_SEARCH_TIMEOUT_MS,
        `web_search "${query.slice(0, 40)}"`,
      );
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
      const page = await withTimeout(
        tools.fetchUrl(url),
        FETCH_URL_TIMEOUT_MS,
        `fetch_url ${url.slice(0, 80)}`,
      );
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
