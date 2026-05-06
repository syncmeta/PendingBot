// scroll-lab server — local dev panel for the 奏折 (scroll) loop.
// Not deployed. Hono on Node. Reads keys from the same .dev.vars
// stash the CLI harness uses; runs runScrollLoop with injected
// search/scrape provider; streams turns to the client over SSE.

import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { streamSSE } from 'hono/streaming';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import OpenAI from 'openai';
import type { ChatCompletionMessageParam } from 'openai/resources/chat/completions';
import { Agent, fetch as undiciFetch, ProxyAgent, setGlobalDispatcher } from 'undici';
import {
  buildScrollInitialUserContent,
  extractSummary,
  extractTitle,
  runScrollLoop,
  type ProgressState,
  type ResumeState,
  type ScrollLoopResult,
  type ScrollTurnInfo,
  type UsageStats,
} from '../../edge/src/lib/scroll-loop.js';
import {
  makeScrape,
  makeSearch,
  type ScrapeProvider,
  type SearchProvider,
} from './providers.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const LAB_ROOT = path.resolve(__dirname, '..');
const REPO_ROOT = path.resolve(LAB_ROOT, '../..');
const EDGE_PROMPTS = path.join(REPO_ROOT, 'apps/edge/prompts');
const FIXTURE_DIRS = [
  path.join(LAB_ROOT, 'fixtures'),
  path.join(REPO_ROOT, 'apps/edge/scripts/fixtures'),
];
const RUNS_DIR = path.join(LAB_ROOT, 'runs');
fs.mkdirSync(RUNS_DIR, { recursive: true });

// ── .dev.vars loader (mirrors apps/edge/scripts/scroll-replay.ts) ────
function parseDotenv(text: string, into: Record<string, string>): void {
  for (const line of text.split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (m) {
      let v = m[2];
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
        v = v.slice(1, -1);
      }
      if (v) into[m[1]] = v;
    }
  }
}
function loadDevVars(): Record<string, string> {
  const env: Record<string, string> = {};
  const home = process.env.HOME ?? '';
  for (const file of [
    home ? path.join(home, '.config/pendingbot/.dev.vars') : '',
    path.join(REPO_ROOT, 'apps/edge/.dev.vars'),
  ].filter(Boolean)) {
    try {
      parseDotenv(fs.readFileSync(file, 'utf8'), env);
    } catch {
      /* optional */
    }
  }
  return env;
}
const ENV = loadDevVars();

// ── Proxy dispatcher ─────────────────────────────────────────────────
// Picks PROXY_URL from .dev.vars (or HTTPS_PROXY / HTTP_PROXY / ALL_PROXY
// env vars) and routes ALL outbound fetch through it — Brave / Firecrawl /
// Tavily / Exa / Serper / OpenRouter / DeepSeek 官方 are all affected the
// same way. Keep-alive caps mirror surf-test: idle conns get dropped fast
// so middleboxes (中国大陆常见) can't silently hold a stale TCP open.
const KEEP_ALIVE = {
  keepAliveTimeout: 4_000,
  keepAliveMaxTimeout: 10_000,
  connect: { timeout: 15_000 },
};
const proxyUrl =
  ENV.PROXY_URL ||
  process.env.HTTPS_PROXY ||
  process.env.https_proxy ||
  process.env.HTTP_PROXY ||
  process.env.http_proxy ||
  process.env.ALL_PROXY ||
  process.env.all_proxy;
if (proxyUrl) {
  setGlobalDispatcher(new ProxyAgent({ uri: proxyUrl, ...KEEP_ALIVE }));
  console.log(`[scroll-lab/api] proxy: ${proxyUrl}`);
} else {
  setGlobalDispatcher(new Agent(KEEP_ALIVE));
  console.log('[scroll-lab/api] no proxy (set PROXY_URL or HTTPS_PROXY)');
}

// ── Models — mirrors surf-test/config.ts list. OpenRouter for the
// `*-latest` aliases; the two `DeepSeek (官方)` presets bypass
// OpenRouter and hit api.deepseek.com directly. Add / remove here.
interface ModelPreset {
  name: string;
  model: string;
  baseUrl?: string;
  envKey?: string;        // ENV var to look up apiKey when baseUrl is set
}
const MODELS: ModelPreset[] = [
  { name: 'Grok 4.3',          model: 'x-ai/grok-4.3' },
  { name: 'Claude Sonnet ~',   model: '~anthropic/claude-sonnet-latest' },
  { name: 'Gemini Flash ~',    model: '~google/gemini-flash-latest' },
  { name: 'DeepSeek v4 Pro',   model: 'deepseek/deepseek-v4-pro' },
  {
    name: 'DeepSeek (官方)',
    model: 'deepseek-v4-pro',
    baseUrl: 'https://api.deepseek.com',
    envKey: 'DEEPSEEK_API_KEY',
  },
  {
    name: 'DeepSeek v4 Flash (官方)',
    model: 'deepseek-v4-flash',
    baseUrl: 'https://api.deepseek.com',
    envKey: 'DEEPSEEK_API_KEY',
  },
  {
    name: 'DeepSeek R1 (官方)',
    model: 'deepseek-reasoner',
    baseUrl: 'https://api.deepseek.com',
    envKey: 'DEEPSEEK_API_KEY',
  },
  { name: 'Kimi ~',            model: '~moonshotai/kimi-latest' },
  { name: 'GLM 5.1',           model: 'z-ai/glm-5.1' },
  { name: 'GPT-5.4',           model: 'openai/gpt-5.4' },
  { name: 'Claude Opus ~',     model: '~anthropic/claude-opus-latest' },
];

const app = new Hono();
app.use('*', cors());

// ── Config endpoint ──────────────────────────────────────────────────
app.get('/api/config', (c) => {
  return c.json({
    // Strip baseUrl/envKey; surface a `direct` flag (skips OpenRouter)
    // and a `keyMissing` flag so the UI can disable un-runnable models.
    models: MODELS.map((m) => ({
      name: m.name,
      model: m.model,
      direct: !!m.baseUrl,
      keyMissing: m.baseUrl ? !ENV[m.envKey ?? ''] : !ENV.OPENROUTER_API_KEY,
    })),
    defaultModel:
      MODELS.find((m) => !m.baseUrl && ENV.OPENROUTER_API_KEY)?.model ??
      MODELS[0]?.model ?? '',
    defaultCollaboratorModel: '~google/gemini-flash-latest',
    searchProviders: ['brave', 'tavily', 'exa', 'serper'] as SearchProvider[],
    scrapeProviders: ['firecrawl', 'tavily', 'exa'] as ScrapeProvider[],
    keysPresent: {
      openrouter: !!ENV.OPENROUTER_API_KEY,
      brave:      !!ENV.BRAVE_API_KEY,
      tavily:     !!ENV.TAVILY_API_KEY,
      exa:        !!ENV.EXA_API_KEY,
      serper:     !!ENV.SERPER_API_KEY,
      firecrawl:  !!ENV.FIRECRAWL_API_KEY,
      deepseek:   !!ENV.DEEPSEEK_API_KEY,
    },
  });
});

// ── Prompts ──────────────────────────────────────────────────────────
app.get('/api/prompts', (c) => {
  const system = fs.readFileSync(path.join(EDGE_PROMPTS, 'scroll.md'), 'utf8');
  const injected = fs.readFileSync(path.join(EDGE_PROMPTS, 'scroll-injected.md'), 'utf8');
  const write = fs.readFileSync(path.join(EDGE_PROMPTS, 'scroll-write.md'), 'utf8');
  const collaborator = fs.readFileSync(path.join(EDGE_PROMPTS, 'scroll-collaborator.md'), 'utf8');
  return c.json({ system, injected, write, collaborator });
});

// PUT /api/prompts — write back to apps/edge/prompts/*.md.
app.put('/api/prompts', async (c) => {
  let body: {
    system?: string;
    injected?: string;
    write?: string;
    collaborator?: string;
  };
  try {
    body = await c.req.json<typeof body>();
  } catch {
    return c.json({ error: 'invalid json' }, 400);
  }
  if (typeof body.system === 'string') {
    fs.writeFileSync(path.join(EDGE_PROMPTS, 'scroll.md'), body.system);
  }
  if (typeof body.injected === 'string') {
    fs.writeFileSync(path.join(EDGE_PROMPTS, 'scroll-injected.md'), body.injected);
  }
  if (typeof body.write === 'string') {
    fs.writeFileSync(path.join(EDGE_PROMPTS, 'scroll-write.md'), body.write);
  }
  if (typeof body.collaborator === 'string') {
    fs.writeFileSync(path.join(EDGE_PROMPTS, 'scroll-collaborator.md'), body.collaborator);
  }
  return c.json({ ok: true });
});

// ── Per-run state — research gate flipped manually from the panel ──
// Map<runId, { researchUnlocked }>. Loop polls per turn so flips
// take effect on the next web_search / fetch_url call. State is
// kept until the run ends; resume re-creates it from the body.
const runStates = new Map<string, { researchUnlocked: boolean }>();

app.post('/api/runs/:id/state', async (c) => {
  const id = c.req.param('id');
  const body = (await c.req.json().catch(() => null)) as
    | { researchUnlocked?: boolean }
    | null;
  if (!body || typeof body.researchUnlocked !== 'boolean') {
    return c.json({ error: 'expected { researchUnlocked: boolean }' }, 400);
  }
  const cur = runStates.get(id) ?? { researchUnlocked: false };
  cur.researchUnlocked = body.researchUnlocked;
  runStates.set(id, cur);
  return c.json({ ok: true, researchUnlocked: cur.researchUnlocked });
});
app.get('/api/runs/:id/state', (c) => {
  const id = c.req.param('id');
  const s = runStates.get(id);
  return c.json({ researchUnlocked: s?.researchUnlocked ?? false });
});

// ── Fixtures ─────────────────────────────────────────────────────────
app.get('/api/fixtures', (c) => {
  const out: Array<{ id: string; path: string }> = [];
  for (const dir of FIXTURE_DIRS) {
    if (!fs.existsSync(dir)) continue;
    for (const f of fs.readdirSync(dir)) {
      if (!f.endsWith('.json')) continue;
      out.push({ id: f.replace(/\.json$/, ''), path: path.join(dir, f) });
    }
  }
  return c.json({ fixtures: out });
});
app.get('/api/fixtures/:id', (c) => {
  const id = c.req.param('id');
  for (const dir of FIXTURE_DIRS) {
    const p = path.join(dir, `${id}.json`);
    if (fs.existsSync(p)) {
      return c.json(JSON.parse(fs.readFileSync(p, 'utf8')));
    }
  }
  return c.json({ error: 'not found' }, 404);
});

// ── Runs (persisted after each /api/run completes) ───────────────────
// Each file: <ts>__<short>.json  containing { input, turns, result, ts }.
// Lives in apps/scroll-lab/runs/ — gitignored via repo-level *.json? no,
// .gitignore covers *.log only, so runs/ is committed-eligible. Add a
// .gitignore inside runs/ (next commit) so contents don't pollute git.
app.get('/api/runs', (c) => {
  const files = fs.existsSync(RUNS_DIR)
    ? fs
        .readdirSync(RUNS_DIR)
        .filter((f) => f.endsWith('.json'))
        .sort()
        .reverse()
    : [];
  const items = files.slice(0, 200).map((f) => {
    try {
      const j = JSON.parse(fs.readFileSync(path.join(RUNS_DIR, f), 'utf8')) as {
        ts?: string;
        input?: { model?: string; collaboratorModel?: string };
        result?: {
          reason?: string;
          turns?: number;
          elapsedMs?: number;
          usage?: { total?: number };
          title?: string | null;
          summary?: string | null;
        };
      };
      return {
        id: f.replace(/\.json$/, ''),
        ts: j.ts ?? '',
        model: j.input?.model ?? '',
        collaboratorModel: j.input?.collaboratorModel ?? '',
        reason: j.result?.reason ?? '',
        turns: j.result?.turns ?? 0,
        elapsedMs: j.result?.elapsedMs ?? 0,
        totalTokens: j.result?.usage?.total ?? 0,
        title: j.result?.title ?? null,
      };
    } catch {
      return { id: f.replace(/\.json$/, ''), ts: '', model: '', reason: 'parse-error', turns: 0, elapsedMs: 0, totalTokens: 0, title: null };
    }
  });
  return c.json({ runs: items });
});
app.get('/api/runs/:id', (c) => {
  const id = c.req.param('id');
  const p = path.join(RUNS_DIR, `${id}.json`);
  if (!fs.existsSync(p)) return c.json({ error: 'not found' }, 404);
  return c.json(JSON.parse(fs.readFileSync(p, 'utf8')));
});

// ── Run (SSE-streamed loop) ──────────────────────────────────────────
type HistoryMsg = { role: 'user' | 'bot' | 'human'; content: string };
interface RunBody {
  model: string;
  systemPrompt: string;        // editable; fall back to current scroll.md if empty
  injectedPrompt: string;      // editable; fall back to current scroll-injected.md if empty
  history: HistoryMsg[];
  memory?: string;
  searchProvider: SearchProvider;
  scrapeProvider: ScrapeProvider;
  stubSearch?: boolean;
  stubFetch?: boolean;
  turns?: number;
  // Optional second model that plays a co-explorer chiming in after
  // each non-final turn. Empty / absent → no collaborator injection;
  // propose_plan still gets the static "用户：继续..." reply.
  collaboratorModel?: string;
  // System prompt for the collaborator. Empty / absent → server reads
  // scroll-collaborator.md from disk.
  collaboratorPrompt?: string;
  // When true, the panel injects a `（系统提示：还剩 N 轮可用）`
  // user message at the start of each turn so the model can reason
  // about budget. Off by default — on the worker we never expose this.
  showTurnsRemaining?: boolean;
  // Same idea, but for the collaborator's prompt (independent toggle).
  collaboratorShowTurnsRemaining?: boolean;
  // For POST /api/run-continue: ID of a previous run to resume from.
  // When present, server loads runs/<id>.json, reconstructs the deps
  // and the saved messages array, runs `turns` more iterations, and
  // appends to the same file.
  resumeFromRunId?: string;
  // Manual research gate — start the run with web_search / fetch_url
  // allowed (true) or blocked (false). The panel can flip the gate
  // mid-run via POST /api/runs/:id/state. Defaults to false (locked).
  initialResearchUnlocked?: boolean;
  // Two-phase write step: when writePhasePrompt is non-empty, after
  // phase 1 (research loop) ends with reason='final', run a second
  // model call with writePhasePrompt as system + phase-1 output as
  // research context → its content replaces finalArticle. Empty
  // writePhasePrompt = single-phase mode (legacy / current behavior).
  writeModel?: string;
  writePhasePrompt?: string;
}

// Build a callback that asks a separate model to play a co-explorer
// chiming in after each non-final turn. Sees the friend's transcript
// + memory + a summary of what the main agent JUST did (assistant
// content + tool calls + truncated tool results). Returns a string
// that the loop pushes as a `role: 'user'` message before the next
// iteration. System prompt is editable via prompts/scroll-collaborator.md.
type CollaboratorInput = {
  turn: number;
  hardCapTurns: number;
  newMessages: ChatCompletionMessageParam[];
};
type CollaboratorOutput = {
  text: string;
  usage?: { input: number; output: number; total: number; cached: number };
};
type CollaboratorReply = (i: CollaboratorInput) => Promise<CollaboratorOutput>;

function formatTurnForCollaborator(newMessages: ChatCompletionMessageParam[]): string {
  const lines: string[] = [];
  for (const m of newMessages) {
    if (m.role === 'assistant') {
      const content = (m.content as string | null) ?? '';
      if (content.trim()) lines.push(`主探索者：${content}`);
      const tcs = (m as { tool_calls?: Array<{ function: { name: string; arguments: string } }> }).tool_calls;
      if (tcs?.length) {
        for (const tc of tcs) {
          let preview = tc.function.arguments;
          try {
            const o = JSON.parse(tc.function.arguments) as Record<string, unknown>;
            const v =
              (o.thoughts as string | undefined) ??
              (o.query as string | undefined) ??
              (o.url as string | undefined) ??
              (o.text as string | undefined) ??
              JSON.stringify(o);
            preview = typeof v === 'string' ? v : JSON.stringify(o);
          } catch {
            /* keep raw */
          }
          lines.push(`  调用工具 ${tc.function.name}: ${preview.slice(0, 400)}`);
        }
      }
    } else if (m.role === 'tool') {
      const content = (m.content as string | null) ?? '';
      lines.push(`  工具返回: ${content.slice(0, 400)}`);
    }
  }
  return lines.join('\n');
}

function makeCollaborator(
  client: OpenAI,
  modelId: string,
  history: HistoryMsg[],
  memory: string | undefined,
  systemPrompt: string,
  showTurnsRemaining: boolean,
): CollaboratorReply {
  const transcript = history
    .filter((m) => m.content.trim())
    .map((m) => `${m.role === 'bot' ? '主探索者' : '朋友'}：${m.content}`)
    .join('\n');
  const memoryBlock = memory && memory.trim() ? `## 朋友的背景\n${memory.trim()}\n\n` : '';

  return async ({ turn, hardCapTurns, newMessages }) => {
    const turnSummary = formatTurnForCollaborator(newMessages);
    // Same shape as the main-model hint: include both remaining and
    // total, and escalate on the last round.
    let budgetBlock = '';
    if (showTurnsRemaining) {
      // `turn` is 0-indexed, hardCapTurns is total; remaining =
      // turns still available (excluding the one already finished).
      const remaining = Math.max(0, hardCapTurns - turn - 1);
      const total = hardCapTurns;
      const line =
        remaining === 0
          ? `（提示：主探索者刚走完最后一轮（${total}/${total}），下一步必须由它用 decide_write_article 做最终决定。）`
          : remaining === 1
            ? `（提示：下一轮是主探索者的最后一轮（${total}/${total}），它本轮（或最迟下一轮）必须做决定。）`
            : `（提示：主探索者还剩 ${remaining}/${total} 轮研究/工具调用机会。）`;
      budgetBlock = `\n\n${line}`;
    }
    const r = await client.chat.completions.create({
      model: modelId,
      messages: [
        { role: 'system', content: systemPrompt },
        {
          role: 'user',
          content:
            `${memoryBlock}## 朋友的聊天记录\n${transcript}\n\n` +
            `## 主探索者第 ${turn} 轮做了什么\n${turnSummary}` +
            budgetBlock +
            `\n\n请用"协作者"的身份给主探索者一个简短的回应（直接说话，不要写"协作者："开头）：`,
        },
      ],
    });
    const text = r.choices[0]?.message?.content?.trim() ?? '';
    const promptDetails = (r.usage as { prompt_tokens_details?: { cached_tokens?: number } } | undefined)
      ?.prompt_tokens_details;
    const usage = {
      input: r.usage?.prompt_tokens ?? 0,
      output: r.usage?.completion_tokens ?? 0,
      total: r.usage?.total_tokens ?? 0,
      cached: promptDetails?.cached_tokens ?? 0,
    };
    return { text, usage };
  };
}

app.post('/api/run', async (c) => {
  let body: RunBody;
  try {
    body = await c.req.json<RunBody>();
  } catch {
    return c.json({ error: 'invalid json' }, 400);
  }
  if (!body.history || body.history.length < 2) {
    return c.json({ error: 'history must have at least 2 messages' }, 400);
  }

  // Pick base URL + API key per the model preset (DeepSeek 官方 hits
  // api.deepseek.com directly; everything else goes through OpenRouter).
  function clientFor(modelId: string): OpenAI | { error: string } {
    const preset = MODELS.find((m) => m.model === modelId);
    const baseUrl = preset?.baseUrl ?? 'https://openrouter.ai/api/v1';
    const apiKey = preset?.envKey ? ENV[preset.envKey] : ENV.OPENROUTER_API_KEY;
    if (!apiKey) {
      return {
        error: preset?.baseUrl
          ? `${preset.envKey} missing in .dev.vars (required for ${modelId})`
          : 'OPENROUTER_API_KEY missing in .dev.vars',
      };
    }
    return new OpenAI({
      apiKey,
      baseURL: baseUrl,
      // OpenAI SDK 4.x defaults to `node-fetch` v2 in Node, which goes
      // through node:http(s) and ignores undici's setGlobalDispatcher
      // — so the proxy we set above wouldn't apply. Force it onto
      // undici's fetch so the ProxyAgent is honored.
      fetch: undiciFetch as unknown as typeof globalThis.fetch,
      defaultHeaders: {
        'HTTP-Referer': 'http://localhost:5174',
        'X-Title': 'PendingBot/scroll-lab',
      },
    });
  }

  const mainClient = clientFor(body.model);
  if ('error' in mainClient) return c.json({ error: mainClient.error }, 500);

  // Optional collaborator: a separate LLM that chimes in after each
  // non-final turn. If model not chosen / key missing, the loop runs
  // without collaborator injection.
  let collaborator: CollaboratorReply | undefined;
  if (body.collaboratorModel) {
    const collabClient = clientFor(body.collaboratorModel);
    if ('error' in collabClient) {
      return c.json({ error: `collaborator: ${collabClient.error}` }, 500);
    }
    const collabPrompt =
      body.collaboratorPrompt && body.collaboratorPrompt.trim()
        ? body.collaboratorPrompt
        : fs.readFileSync(path.join(EDGE_PROMPTS, 'scroll-collaborator.md'), 'utf8');
    collaborator = makeCollaborator(
      collabClient,
      body.collaboratorModel,
      body.history,
      body.memory,
      collabPrompt,
      !!body.collaboratorShowTurnsRemaining,
    );
  }

  const initialUser = buildScrollInitialUserContent({
    history: body.history,
    memoryRepresentation: body.memory,
    injectedPrompt: body.injectedPrompt,
  });

  const openai = mainClient;

  const webSearch = body.stubSearch ? async () => [] : makeSearch(body.searchProvider, ENV);
  const fetchUrl = body.stubFetch
    ? async (url: string) => ({ url, title: '', content: '(stub: scroll-lab 跳过抓取)' })
    : makeScrape(body.scrapeProvider, ENV);

  // Cancel hook: client closes the SSE stream → the request's
  // AbortSignal fires → next iteration of the loop sees aborted=true
  // and returns reason='cancelled' cleanly.
  const reqSignal = c.req.raw.signal;
  const collectedTurns: ScrollTurnInfo[] = [];

  // Resume support — when body.resumeFromRunId is set, we hydrate the
  // loop state from a previously saved run JSON and append new turns
  // back to that same file (instead of generating a fresh run id).
  let resumeState: ResumeState | undefined;
  let priorTurns: ScrollTurnInfo[] = [];
  let runId: string;
  let ts: string;
  if (body.resumeFromRunId) {
    const p = path.join(RUNS_DIR, `${body.resumeFromRunId}.json`);
    if (!fs.existsSync(p)) {
      return c.json({ error: `resume: run ${body.resumeFromRunId} not found` }, 404);
    }
    const saved = JSON.parse(fs.readFileSync(p, 'utf8')) as {
      id: string;
      ts: string;
      turns?: ScrollTurnInfo[];
      messages?: ChatCompletionMessageParam[];
      result?: {
        progress?: ProgressState;
        usage?: UsageStats;
        collaboratorUsage?: UsageStats;
      };
    };
    if (!saved.messages?.length) {
      return c.json(
        { error: `resume: run ${body.resumeFromRunId} has no saved messages array` },
        400,
      );
    }
    resumeState = {
      messages: saved.messages,
      progress: saved.result?.progress ?? {
        phase: 'plan',
        notes: [],
        visited_urls: [],
        plan_rounds: 0,
      },
      usage: saved.result?.usage ?? { input: 0, output: 0, total: 0, cached: 0 },
      collaboratorUsage: saved.result?.collaboratorUsage,
    };
    priorTurns = saved.turns ?? [];
    runId = saved.id;
    ts = saved.ts;
  } else {
    ts = new Date().toISOString();
    runId = ts.replace(/[:.]/g, '-') + '__' + Math.random().toString(36).slice(2, 8);
  }

  // Register the run's research-gate state so the panel can flip it
  // mid-run via POST /api/runs/:id/state. Cleaned up at the end.
  runStates.set(runId, { researchUnlocked: !!body.initialResearchUnlocked });

  return streamSSE(c, async (stream) => {
    await stream.writeSSE({
      event: 'start',
      data: JSON.stringify({
        runId,
        model: body.model,
        systemChars: body.systemPrompt.length,
        initialUserChars: initialUser.length,
      }),
    });

    let result: ScrollLoopResult | undefined;
    let errorMessage: string | undefined;
    const startedAt = Date.now();
    try {
      result = await runScrollLoop({
        openai,
        modelId: body.model,
        systemPrompt: body.systemPrompt,
        initialUserContent: initialUser,
        webSearch,
        fetchUrl,
        hardCapTurns: body.turns,
        showTurnsRemaining: !!body.showTurnsRemaining,
        simulateCollaboratorReply: collaborator,
        isCancelled: () => Promise.resolve(reqSignal.aborted),
        isResearchUnlocked: () => runStates.get(runId)?.researchUnlocked ?? false,
        resume: resumeState,
        onTurn: async (info: ScrollTurnInfo) => {
          // Keep turn numbering continuous across resumes — the loop's
          // internal counter restarts at 0 each invocation, so we
          // offset by the prior tail length before persisting/streaming.
          const adjusted: ScrollTurnInfo = { ...info, turn: priorTurns.length + info.turn };
          collectedTurns.push(adjusted);
          await stream.writeSSE({ event: 'turn', data: JSON.stringify(adjusted) });
        },
      });
    } catch (err) {
      errorMessage = String((err as Error)?.message ?? err);
      await stream.writeSSE({ event: 'error', data: errorMessage });
    }

    // ── Optional phase 2: write the article from phase-1's research ──
    // Only when phase 1 ended cleanly with content AND the panel
    // supplied a writePhasePrompt. Single-phase mode (empty prompt)
    // skips this entirely and behaves exactly as before.
    let phase1Summary: string | undefined;
    let writeUsage: UsageStats | undefined;
    let writeGenerationId: string | undefined;
    if (
      result &&
      result.reason === 'final' &&
      result.finalArticle.trim() &&
      body.writePhasePrompt &&
      body.writePhasePrompt.trim()
    ) {
      const phase1Output = result.finalArticle.trim();
      const phase2ModelId = body.writeModel || body.model;
      const phase2Client = clientFor(phase2ModelId);
      if ('error' in phase2Client) {
        await stream.writeSSE({
          event: 'error',
          data: `phase-2 (write) client: ${phase2Client.error}`,
        });
      } else {
        const notes = result.progress.notes ?? [];
        const urls = result.progress.visited_urls ?? [];
        const notesBlock =
          notes.length > 0
            ? '\n\n## 你记录的关键笔记\n' +
              notes
                .map((n, i) => `${i + 1}. ${n.text}${n.source ? ` — ${n.source}` : ''}`)
                .join('\n')
            : '';
        const urlsBlock =
          urls.length > 0 ? '\n\n## 你访问过的链接\n' + urls.map((u) => `- ${u}`).join('\n') : '';
        const phase2User = [
          initialUser,
          '---',
          '## 你刚才做的研究和思考\n\n' + phase1Output,
          (notesBlock + urlsBlock).trim() || '',
          '## 任务\n基于上面的研究和聊天记录，按 system prompt 的要求给朋友写一篇文章。',
        ]
          .filter((s) => s.trim())
          .join('\n\n');

        try {
          const phase2 = await phase2Client.chat.completions.create({
            model: phase2ModelId,
            messages: [
              { role: 'system', content: body.writePhasePrompt },
              { role: 'user', content: phase2User },
            ],
          });
          const phase2Text = (phase2.choices[0]?.message?.content ?? '').trim();
          const phase2PromptDetails = (phase2.usage as { prompt_tokens_details?: { cached_tokens?: number } } | undefined)
            ?.prompt_tokens_details;
          writeUsage = {
            input: phase2.usage?.prompt_tokens ?? 0,
            output: phase2.usage?.completion_tokens ?? 0,
            total: phase2.usage?.total_tokens ?? 0,
            cached: phase2PromptDetails?.cached_tokens ?? 0,
          };
          writeGenerationId = phase2.id;

          // Stream phase 2 as an extra "turn" so the UI sees it inline.
          const cum: UsageStats = {
            input: result.usage.input + writeUsage.input,
            output: result.usage.output + writeUsage.output,
            total: result.usage.total + writeUsage.total,
            cached: result.usage.cached + writeUsage.cached,
          };
          await stream.writeSSE({
            event: 'turn',
            data: JSON.stringify({
              turn: collectedTurns.length,
              progress: { ...result.progress, phase: 'compose' },
              newMessages: [{ role: 'assistant', content: phase2Text }],
              turnUsage: writeUsage,
              cumulativeUsage: cum,
              generationId: phase2.id,
            }),
          });

          phase1Summary = phase1Output;
          result.finalArticle = phase2Text;
          result.usage = cum;
        } catch (err) {
          await stream.writeSSE({
            event: 'error',
            data: `phase-2 (write) failed: ${String((err as Error)?.message ?? err)}`,
          });
        }
      }
    }

    let resultPayload: Record<string, unknown> | undefined;
    if (result) {
      const finalText = result.finalArticle.trim();
      resultPayload = {
        reason: result.reason,
        // Total turns visible to the panel = prior persisted + freshly
        // executed this invocation. priorTurns.length is 0 for fresh
        // (non-resume) runs.
        turns: priorTurns.length + result.turns,
        elapsedMs: Date.now() - startedAt,
        usage: result.usage,
        collaboratorUsage: result.collaboratorUsage,
        generationId: result.lastGenerationId,
        progress: result.progress,
        finalArticle: finalText,
        title: extractTitle(finalText),
        summary: extractSummary(finalText),
        declineReason: result.declineReason,
        lastAssistantText: result.lastAssistantText,
        phase1Summary,
        writeUsage,
        writeGenerationId,
        // Echo so the panel knows whether we appended to an existing
        // run vs created a new one (drives the "继续" button labels).
        runId,
        resumed: !!body.resumeFromRunId,
      };
      await stream.writeSSE({ event: 'result', data: JSON.stringify(resultPayload) });
    }

    // Persist the full run to disk regardless of how it ended (final /
    // turn_cap / cancelled / error). Skip only for empty/aborted
    // before-first-turn so we don't pile up zero-content junk.
    if (collectedTurns.length > 0 || result || errorMessage) {
      try {
        const file = path.join(RUNS_DIR, `${runId}.json`);
        fs.writeFileSync(
          file,
          JSON.stringify(
            {
              id: runId,
              ts,
              input: {
                model: body.model,
                collaboratorModel: body.collaboratorModel ?? '',
                collaboratorPrompt: body.collaboratorPrompt ?? '',
                writeModel: body.writeModel ?? '',
                writePhasePrompt: body.writePhasePrompt ?? '',
                initialResearchUnlocked: !!body.initialResearchUnlocked,
                showTurnsRemaining: !!body.showTurnsRemaining,
                collaboratorShowTurnsRemaining: !!body.collaboratorShowTurnsRemaining,
                searchProvider: body.searchProvider,
                scrapeProvider: body.scrapeProvider,
                stubSearch: !!body.stubSearch,
                stubFetch: !!body.stubFetch,
                turns: body.turns ?? null,
                memory: body.memory ?? '',
                history: body.history,
                systemPrompt: body.systemPrompt,
                injectedPrompt: body.injectedPrompt,
              },
              start: {
                systemChars: body.systemPrompt.length,
                initialUserChars: initialUser.length,
              },
              // Resume mode: prepend the prior turns so the file
              // accumulates across "继续一轮" presses. Fresh mode:
              // priorTurns is [] and this is just collectedTurns.
              turns: [...priorTurns, ...collectedTurns],
              // Persist the full messages array so the next resume
              // can pick up exactly where we left off — without this
              // we'd have to reconstruct from turns, which is brittle.
              messages: result?.messages ?? resumeState?.messages ?? [],
              result: resultPayload ?? null,
              error: errorMessage ?? null,
            },
            null,
            2,
          ),
        );
      } catch (err) {
        console.warn('[scroll-lab/api] failed to persist run:', err);
      }
    }
    // Run finished — let the runStates entry linger briefly so a
    // late panel poll doesn't get confused, then drop it. Resume
    // re-creates the entry from the body.initialResearchUnlocked.
    setTimeout(() => runStates.delete(runId), 30_000);
  });
});

// ── OpenRouter cost lookup (post-stream USD) ─────────────────────────
app.get('/api/openrouter-generation/:id', async (c) => {
  if (!ENV.OPENROUTER_API_KEY) return c.json({ error: 'no llm key' }, 500);
  const id = c.req.param('id');
  // OpenRouter takes a beat to settle the record. Quick poll.
  for (let i = 0; i < 5; i++) {
    const r = await fetch(`https://openrouter.ai/api/v1/generation?id=${encodeURIComponent(id)}`, {
      headers: { Authorization: `Bearer ${ENV.OPENROUTER_API_KEY}` },
    });
    if (r.ok) {
      const j = (await r.json()) as { data?: unknown };
      if (j?.data) return c.json(j);
    }
    await new Promise((res) => setTimeout(res, 500));
  }
  return c.json({ error: 'generation not found yet' }, 404);
});

// ── Bind ─────────────────────────────────────────────────────────────
const PORT = Number(process.env.PORT ?? 5175);
serve({ fetch: app.fetch, port: PORT });
console.log(`[scroll-lab/api] listening on http://localhost:${PORT}`);
console.log(`[scroll-lab/api] keys present:`, {
  openrouter: !!ENV.OPENROUTER_API_KEY,
  brave: !!ENV.BRAVE_API_KEY,
  tavily: !!ENV.TAVILY_API_KEY,
  exa: !!ENV.EXA_API_KEY,
  serper: !!ENV.SERPER_API_KEY,
  firecrawl: !!ENV.FIRECRAWL_API_KEY,
});
