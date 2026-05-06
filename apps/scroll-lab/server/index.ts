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
import { Agent, ProxyAgent, setGlobalDispatcher } from 'undici';
import {
  buildScrollInitialUserContent,
  extractSummary,
  extractTitle,
  runScrollLoop,
  type ScrollLoopResult,
  type ScrollTurnInfo,
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
  { name: 'Claude Sonnet ~',   model: 'anthropic/claude-sonnet-latest' },
  { name: 'Gemini Flash ~',    model: 'google/gemini-flash-latest' },
  { name: 'DeepSeek v4 Pro',   model: 'deepseek/deepseek-v4-pro' },
  {
    name: 'DeepSeek (官方)',
    model: 'deepseek-chat',
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
  { name: 'Kimi ~',            model: 'moonshotai/kimi-latest' },
  { name: 'GLM 5.1',           model: 'z-ai/glm-5.1' },
  { name: 'GPT-5.4',           model: 'openai/gpt-5.4' },
  { name: 'Claude Opus ~',     model: 'anthropic/claude-opus-latest' },
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
  return c.json({ system, injected });
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
  // Optional second model that plays the friend's reply to propose_plan.
  // Empty / absent → fall back to the static "用户：继续..." string.
  userSimulatorModel?: string;
}

// Build a callback that asks a second model to play the "friend"
// responding to the assistant's proposed research plan. Receives the
// raw JSON args from the propose_plan tool call.
function makeUserSimulator(
  client: OpenAI,
  modelId: string,
  history: HistoryMsg[],
  memory: string | undefined,
): (planArgs: string) => Promise<string> {
  const transcript = history
    .filter((m) => m.content.trim())
    .map((m) => `${m.role === 'bot' ? '研究助手' : '朋友'}：${m.content}`)
    .join('\n');
  const memoryBlock = memory && memory.trim() ? `## 朋友的背景\n${memory.trim()}\n\n` : '';

  return async (planArgs: string) => {
    let summary = planArgs;
    try {
      const obj = JSON.parse(planArgs) as {
        thoughts?: string;
        queries?: Array<{ q: string; reason?: string }>;
        urls?: Array<{ url: string; reason?: string }>;
      };
      summary = [
        obj.thoughts && `思考：${obj.thoughts}`,
        obj.queries?.length && `想搜：\n${obj.queries.map((q) => `  - ${q.q}` + (q.reason ? ` (${q.reason})` : '')).join('\n')}`,
        obj.urls?.length && `想抓：\n${obj.urls.map((u) => `  - ${u.url}` + (u.reason ? ` (${u.reason})` : '')).join('\n')}`,
      ].filter(Boolean).join('\n\n');
    } catch {
      /* fall through with raw args */
    }

    const r = await client.chat.completions.create({
      model: modelId,
      messages: [
        {
          role: 'system',
          content:
            '你扮演下面"朋友"的角色。一位研究助手刚刚分享了它打算如何帮你研究你的处境。你看完后用自然口语回应——可以同意、补充信息、改变方向、表达不耐烦或质疑、提一个问题。保持你前面聊天记录里的语气。不奉承，不做"完美用户"。回复控制在 2-4 句之内。',
        },
        {
          role: 'user',
          content:
            `${memoryBlock}## 我们之前的聊天\n${transcript}\n\n## 研究助手刚刚说\n${summary}\n\n请用"朋友"的身份回应（直接说话，不要写"朋友："开头）：`,
        },
      ],
    });
    return r.choices[0]?.message?.content?.trim() ?? '';
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
      defaultHeaders: {
        'HTTP-Referer': 'http://localhost:5174',
        'X-Title': 'PendingBot/scroll-lab',
      },
    });
  }

  const mainClient = clientFor(body.model);
  if ('error' in mainClient) return c.json({ error: mainClient.error }, 500);

  // Optional friend-simulator: a second LLM impersonates the friend
  // responding to propose_plan. If model not chosen / key missing, the
  // loop falls back to its built-in "用户：继续，按你的计划执行。" string.
  let simulator: ((args: string) => Promise<string>) | undefined;
  if (body.userSimulatorModel) {
    const simClient = clientFor(body.userSimulatorModel);
    if ('error' in simClient) {
      return c.json({ error: `simulator: ${simClient.error}` }, 500);
    }
    simulator = makeUserSimulator(simClient, body.userSimulatorModel, body.history, body.memory);
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

  return streamSSE(c, async (stream) => {
    await stream.writeSSE({
      event: 'start',
      data: JSON.stringify({
        model: body.model,
        systemChars: body.systemPrompt.length,
        initialUserChars: initialUser.length,
      }),
    });

    let result: ScrollLoopResult | undefined;
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
        simulateUserReply: simulator,
        onTurn: async (info: ScrollTurnInfo) => {
          await stream.writeSSE({
            event: 'turn',
            data: JSON.stringify(info),
          });
        },
      });
    } catch (err) {
      await stream.writeSSE({ event: 'error', data: String((err as Error)?.message ?? err) });
      return;
    }

    const finalText = result.finalArticle.trim();
    await stream.writeSSE({
      event: 'result',
      data: JSON.stringify({
        reason: result.reason,
        turns: result.turns,
        elapsedMs: Date.now() - startedAt,
        usage: result.usage,
        generationId: result.lastGenerationId,
        progress: result.progress,
        finalArticle: finalText,
        title: extractTitle(finalText),
        summary: extractSummary(finalText),
      }),
    });
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
