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
  const preset = MODELS.find((m) => m.model === body.model);
  const baseUrl = preset?.baseUrl ?? 'https://openrouter.ai/api/v1';
  const apiKey = preset?.envKey ? ENV[preset.envKey] : ENV.OPENROUTER_API_KEY;
  if (!apiKey) {
    return c.json(
      {
        error: preset?.baseUrl
          ? `${preset.envKey} missing in .dev.vars (required for ${body.model})`
          : 'OPENROUTER_API_KEY missing in .dev.vars',
      },
      500,
    );
  }

  const initialUser = buildScrollInitialUserContent({
    history: body.history,
    memoryRepresentation: body.memory,
    injectedPrompt: body.injectedPrompt,
  });

  const openai = new OpenAI({
    apiKey,
    baseURL: baseUrl,
    defaultHeaders: {
      'HTTP-Referer': 'http://localhost:5174',
      'X-Title': 'PendingBot/scroll-lab',
    },
  });

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
