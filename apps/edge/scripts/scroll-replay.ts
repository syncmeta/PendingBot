#!/usr/bin/env bun
// Offline replay harness for the 奏折 (scroll) agent loop.
//
// 用法:
//   bun run apps/edge/scripts/scroll-replay.ts <conversation-id> [flags]
//
// Flags:
//   --bot <id>         Override the bot — default reads conversations.bot_id
//   --model <id>       Override the model — default reads bots.model_id
//   --turns <n>        Cap turns (default 30, lower = faster iteration)
//   --memory <file>    Paste in a bot-memory representation (skipped if absent)
//   --prompt-system <file>      Override system prompt path
//   --prompt-injected <file>    Override injected directive prompt path
//   --no-fetch         Stub fetch_url (returns "(harness 跳过抓取)")
//   --no-search        Stub web_search (returns empty results)
//
// Reads apps/edge/.dev.vars for keys, pulls history from the configured
// Supabase, runs runScrollLoop with stdout logging — every assistant
// turn / tool call / tool result is printed. No DB writes.
//
// Iteration loop:
//   1. tweak prompts/scroll.md or prompts/scroll-injected.md (or src/lib/scroll-loop.ts)
//   2. bun run apps/edge/scripts/scroll-replay.ts <conv-id>
//   3. read the trace, repeat.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import OpenAI from 'openai';
import {
  buildScrollInitialUserContent,
  extractSummary,
  extractTitle,
  HISTORY_LIMIT,
  runScrollLoop,
  type ScrollTurnInfo,
} from '../src/lib/scroll-loop';
import { braveSearch, firecrawlScrape } from '../src/lib/web';

// ── Args ─────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
if (argv.length === 0 || argv[0].startsWith('-')) {
  console.error('usage: bun run scroll-replay.ts <conversation-id> [--bot id] [--model id] [--turns n] [--memory file] [--no-fetch] [--no-search]');
  process.exit(2);
}
const conversationId = argv[0];

function flag(name: string): string | undefined {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}
function bool(name: string): boolean {
  return argv.includes(name);
}
const overrideBotId = flag('--bot');
const overrideModelId = flag('--model');
const turnCap = flag('--turns') ? Number(flag('--turns')) : undefined;
const memoryFile = flag('--memory');
const systemPromptFile = flag('--prompt-system');
const injectedPromptFile = flag('--prompt-injected');
const stubFetch = bool('--no-fetch');
const stubSearch = bool('--no-search');

// ── Paths ────────────────────────────────────────────────────────────
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const EDGE_ROOT = path.resolve(__dirname, '..');

// ── .dev.vars loader ─────────────────────────────────────────────────
function loadDevVars(): Record<string, string> {
  const text = fs.readFileSync(path.join(EDGE_ROOT, '.dev.vars'), 'utf8');
  const env: Record<string, string> = {};
  for (const line of text.split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (m) {
      let v = m[2];
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
        v = v.slice(1, -1);
      }
      env[m[1]] = v;
    }
  }
  return env;
}
const env = loadDevVars();
function need(k: string): string {
  const v = env[k];
  if (!v) {
    console.error(`missing ${k} in .dev.vars`);
    process.exit(1);
  }
  return v;
}
const SUPABASE_URL = need('SUPABASE_URL');
const SUPABASE_SERVICE_ROLE_KEY = need('SUPABASE_SERVICE_ROLE_KEY');
const OPENROUTER_API_KEY = need('OPENROUTER_API_KEY');
const BRAVE_API_KEY = stubSearch ? '' : need('BRAVE_API_KEY');
const FIRECRAWL_API_KEY = stubFetch ? '' : need('FIRECRAWL_API_KEY');

// ── Logging helpers ──────────────────────────────────────────────────
const isTTY = process.stdout.isTTY && !argv.includes('--no-color');
const C = {
  dim: (s: string) => (isTTY ? `\x1b[2m${s}\x1b[0m` : s),
  bold: (s: string) => (isTTY ? `\x1b[1m${s}\x1b[0m` : s),
  cyan: (s: string) => (isTTY ? `\x1b[36m${s}\x1b[0m` : s),
  yellow: (s: string) => (isTTY ? `\x1b[33m${s}\x1b[0m` : s),
  green: (s: string) => (isTTY ? `\x1b[32m${s}\x1b[0m` : s),
  magenta: (s: string) => (isTTY ? `\x1b[35m${s}\x1b[0m` : s),
  red: (s: string) => (isTTY ? `\x1b[31m${s}\x1b[0m` : s),
};

function divider(label: string): void {
  console.log(C.dim('─'.repeat(8) + ` ${label} ` + '─'.repeat(Math.max(8, 60 - label.length))));
}
function truncate(s: string, n = 1200): string {
  return s.length <= n ? s : s.slice(0, n) + C.dim(` …(+${s.length - n} chars)`);
}

// ── Supabase ─────────────────────────────────────────────────────────
const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
  db: { schema: 'pendingbot' },
});

// ── Prompts (load from disk, not via wrangler text-import) ───────────
function loadPrompt(rel: string, override?: string): string {
  const p = override ?? path.join(EDGE_ROOT, 'prompts', rel);
  return fs.readFileSync(p, 'utf8');
}
const systemPrompt = loadPrompt('scroll.md', systemPromptFile);
const injectedPrompt = loadPrompt('scroll-injected.md', injectedPromptFile);

// ── Main ─────────────────────────────────────────────────────────────
async function main(): Promise<void> {
  divider('conv');
  console.log(`conversation_id: ${C.cyan(conversationId)}`);

  // Resolve bot id via the conversation row, unless overridden.
  let botId = overrideBotId;
  if (!botId) {
    const { data: conv, error } = await supa
      .from('conversations')
      .select('bot_id')
      .eq('id', conversationId)
      .maybeSingle();
    if (error) throw new Error(`conversations lookup: ${error.message}`);
    if (!conv?.bot_id) throw new Error('conversation has no bot_id (use --bot to override)');
    botId = conv.bot_id as string;
  }
  console.log(`bot_id:          ${C.cyan(botId)}`);

  const [historyRes, botRes] = await Promise.all([
    supa
      .from('messages')
      .select('role, content, created_at')
      .eq('conversation_id', conversationId)
      .neq('role', 'log')
      .order('created_at', { ascending: false })
      .limit(HISTORY_LIMIT),
    supa.from('bots').select('id, model_id, display_name').eq('id', botId).single(),
  ]);
  if (historyRes.error) throw new Error(`messages: ${historyRes.error.message}`);
  if (botRes.error || !botRes.data) throw new Error(`bot: ${botRes.error?.message ?? 'no row'}`);

  const modelId = overrideModelId ?? (botRes.data.model_id as string);
  const history = (historyRes.data ?? []).reverse() as Array<{
    role: 'user' | 'bot' | 'human';
    content: string | null;
  }>;
  const hLen = history.filter((m) => m.content && m.content.trim()).length;

  console.log(`bot.display_name: ${botRes.data.display_name ?? '(unset)'}`);
  console.log(`model_id:         ${C.cyan(modelId)}`);
  console.log(`history messages: ${hLen}`);
  if (hLen < 2) {
    console.error(C.red('history too short — runScroll would early-delete the row'));
    process.exit(1);
  }

  // Optional memory file — paste in the bot's "long-term observation" snippet.
  let memoryRepresentation: string | null = null;
  if (memoryFile) {
    memoryRepresentation = fs.readFileSync(memoryFile, 'utf8');
    console.log(`memory file:      ${memoryFile} (${memoryRepresentation.length} chars)`);
  } else {
    console.log(C.dim('memory:           (none — pass --memory <file> to inject)'));
  }

  const initialUser = buildScrollInitialUserContent({
    history,
    memoryRepresentation,
    injectedPrompt,
  });

  divider('initial user content');
  console.log(truncate(initialUser, 2000));

  const openai = new OpenAI({
    apiKey: OPENROUTER_API_KEY,
    baseURL: 'https://openrouter.ai/api/v1',
    defaultHeaders: {
      'HTTP-Referer': 'https://pendingname.com',
      'X-Title': 'PendingBot/scroll-replay',
    },
  });

  // braveSearch / firecrawlScrape only read env.BRAVE_API_KEY /
  // env.FIRECRAWL_API_KEY. Cast through `unknown` because Env is the
  // worker bindings interface (R2/KV etc.) we don't have here.
  const webEnv = { BRAVE_API_KEY, FIRECRAWL_API_KEY } as unknown as Parameters<typeof braveSearch>[0];

  const startedAt = Date.now();
  const onTurn = ({ turn, progress, newMessages }: ScrollTurnInfo): void => {
    divider(`turn ${turn}  phase=${progress.phase}  notes=${progress.notes.length}  urls=${progress.visited_urls.length}`);
    for (const m of newMessages) {
      if (m.role === 'assistant') {
        const content = (m.content as string | null) ?? '';
        const tcs = (m.tool_calls ?? []) as Array<{ id: string; function: { name: string; arguments: string } }>;
        if (content.trim()) {
          console.log(C.bold('assistant:'));
          console.log(truncate(content));
        }
        for (const tc of tcs) {
          console.log(C.yellow(`tool_call ${tc.function.name}`) + C.dim(`  id=${tc.id}`));
          console.log(C.dim(truncate(tc.function.arguments, 500)));
        }
      } else if (m.role === 'tool') {
        const content = (m.content as string | null) ?? '';
        console.log(C.green(`tool_result`) + C.dim(`  id=${(m as { tool_call_id?: string }).tool_call_id ?? ''}`));
        console.log(C.dim(truncate(content, 800)));
      }
    }
  };

  const result = await runScrollLoop({
    openai,
    modelId,
    systemPrompt,
    initialUserContent: initialUser,
    webSearch: stubSearch
      ? async () => []
      : (q) => braveSearch(webEnv, q),
    fetchUrl: stubFetch
      ? async (u) => ({ url: u, title: '', content: '(harness 跳过抓取)' })
      : (u) => firecrawlScrape(webEnv, u),
    onTurn,
    hardCapTurns: turnCap,
  });

  const elapsedMs = Date.now() - startedAt;

  divider('result');
  console.log(`reason:          ${C.magenta(result.reason)}`);
  console.log(`turns:           ${result.turns}`);
  console.log(`elapsed:         ${(elapsedMs / 1000).toFixed(1)}s`);
  console.log(`usage:           in=${result.usage.input}  out=${result.usage.output}  total=${result.usage.total}`);
  console.log(`generation_id:   ${result.lastGenerationId ?? '(n/a)'}`);
  console.log(`progress.notes:  ${result.progress.notes.length}`);
  console.log(`progress.urls:   ${result.progress.visited_urls.length}`);
  console.log(`progress.plan:   ${result.progress.plan_rounds} round(s)`);

  divider('final article');
  if (!result.finalArticle.trim()) {
    console.log(C.dim('(empty — runScroll would delete the row as 空奏折)'));
  } else {
    console.log(`title:    ${extractTitle(result.finalArticle) ?? '(none)'}`);
    console.log(`summary:  ${extractSummary(result.finalArticle) ?? '(none)'}`);
    console.log();
    console.log(result.finalArticle);
  }
}

main().catch((err) => {
  console.error(C.red('replay failed:'), err);
  process.exit(1);
});
