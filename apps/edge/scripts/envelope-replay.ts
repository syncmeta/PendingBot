#!/usr/bin/env bun
// Offline replay harness for the 来信 (envelope) agent loop.
//
// 用法（A：从真实对话拉取）:
//   bun run apps/edge/scripts/envelope-replay.ts <conversation-id> [flags]
//
// 用法（B：用合成对话 fixture，纯本地、不连 conversations 表）:
//   bun run apps/edge/scripts/envelope-replay.ts --fixture path/to/fixture.json --model <id>
//
// Flags:
//   --fixture <file>   Synthetic-conv JSON ({ history, model?, memory? } or just an array)
//   --bot <id>         Override the bot — default reads conversations.bot_id
//   --model <id>       Override the model — required in fixture mode unless fixture sets it
//   --turns <n>        Cap turns (default 30, lower = faster iteration)
//   --memory <file>    Paste in a bot-memory representation (skipped if absent)
//   --prompt-system <file>      Override system prompt path
//   --prompt-injected <file>    Override injected directive prompt path
//   --no-fetch         Stub fetch_url (returns "(harness 跳过抓取)")
//   --no-search        Stub web_search (returns empty results)
//   --no-color         Disable ANSI color
//
// Reads apps/edge/.dev.vars for keys, pulls history from the configured
// Supabase (or from --fixture), runs runEnvelopeLoop with stdout logging —
// every assistant turn / tool call / tool result is printed. No DB writes.
//
// Find a conversation id with: bun run scripts/envelope-list-convs.ts
//
// Iteration loop:
//   1. tweak prompts/envelope.md or prompts/envelope-injected.md (or src/lib/envelope-loop.ts)
//   2. bun run apps/edge/scripts/envelope-replay.ts <conv-id>   (or --fixture ...)
//   3. read the trace, repeat.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import OpenAI from 'openai';
import {
  buildEnvelopeInitialUserContent,
  extractSummary,
  extractTitle,
  HISTORY_LIMIT,
  runEnvelopeLoop,
  type EnvelopeTurnInfo,
} from '../src/lib/envelope-loop';
import { runWebScrape, runWebSearch } from '../src/lib/web';
import { WebToolMeter } from '../src/lib/web-meter';

// ── Args ─────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);

const VALUE_FLAGS = new Set([
  '--bot',
  '--model',
  '--turns',
  '--memory',
  '--prompt-system',
  '--prompt-injected',
  '--fixture',
]);
const BOOL_FLAGS = new Set(['--no-fetch', '--no-search', '--no-color']);

const positional: string[] = [];
const opts: Record<string, string | boolean> = {};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (VALUE_FLAGS.has(a)) {
    const v = argv[++i];
    if (v === undefined) {
      console.error(`flag ${a} expects a value`);
      process.exit(2);
    }
    opts[a] = v;
  } else if (BOOL_FLAGS.has(a)) {
    opts[a] = true;
  } else if (a.startsWith('-')) {
    console.error(`unknown flag: ${a}`);
    process.exit(2);
  } else {
    positional.push(a);
  }
}

const conversationId: string | undefined = positional[0];
const overrideBotId = opts['--bot'] as string | undefined;
const overrideModelId = opts['--model'] as string | undefined;
const turnCap = opts['--turns'] ? Number(opts['--turns']) : undefined;
const memoryFile = opts['--memory'] as string | undefined;
const systemPromptFile = opts['--prompt-system'] as string | undefined;
const injectedPromptFile = opts['--prompt-injected'] as string | undefined;
const fixtureFile = opts['--fixture'] as string | undefined;
const stubFetch = opts['--no-fetch'] === true;
const stubSearch = opts['--no-search'] === true;

if (!conversationId && !fixtureFile) {
  console.error('usage: bun run envelope-replay.ts <conversation-id> [flags]');
  console.error('       bun run envelope-replay.ts --fixture <file.json> --model <id> [flags]');
  process.exit(2);
}
if (conversationId && fixtureFile) {
  console.error('pass either <conversation-id> OR --fixture, not both');
  process.exit(2);
}

// ── Paths ────────────────────────────────────────────────────────────
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const EDGE_ROOT = path.resolve(__dirname, '..');

// ── .dev.vars loader ─────────────────────────────────────────────────
// Two sources, merged in this order (later overrides earlier):
//   1. ~/.config/pendingbot/.dev.vars   — user-global stash (good for
//      OPENROUTER_API_KEY etc. you don't want to recopy per worktree)
//   2. apps/edge/.dev.vars              — project-local, wins on conflict
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
      // Skip empty values so a half-filled project-local .dev.vars doesn't
      // clobber a real value from the global stash.
      if (v) into[m[1]] = v;
    }
  }
}
function loadDevVars(): Record<string, string> {
  const env: Record<string, string> = {};
  const home = process.env.HOME ?? '';
  const candidates = [
    home ? path.join(home, '.config/pendingbot/.dev.vars') : '',
    path.join(EDGE_ROOT, '.dev.vars'),
  ].filter(Boolean);
  for (const file of candidates) {
    try {
      const text = fs.readFileSync(file, 'utf8');
      parseDotenv(text, env);
    } catch {
      // fine — file optional
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
// Fixture mode skips Supabase entirely — convs/messages/bots not touched.
const SUPABASE_URL = fixtureFile ? env.SUPABASE_URL ?? '' : need('SUPABASE_URL');
const SUPABASE_SECRET_KEY = fixtureFile
  ? env.SUPABASE_SECRET_KEY ?? ''
  : need('SUPABASE_SECRET_KEY');
const OPENROUTER_API_KEY = need('OPENROUTER_API_KEY');
const BRAVE_API_KEY = stubSearch ? '' : need('BRAVE_API_KEY');
const FIRECRAWL_API_KEY = stubFetch ? '' : need('FIRECRAWL_API_KEY');

// ── Logging helpers ──────────────────────────────────────────────────
const isTTY = process.stdout.isTTY && !opts['--no-color'];
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

// ── Prompts (load from disk, not via wrangler text-import) ───────────
function loadPrompt(rel: string, override?: string): string {
  const p = override ?? path.join(EDGE_ROOT, 'prompts', rel);
  return fs.readFileSync(p, 'utf8');
}
const systemPrompt = loadPrompt('envelope.md', systemPromptFile);
const injectedPrompt = loadPrompt('envelope-injected.md', injectedPromptFile);

// ── Fixture loader ───────────────────────────────────────────────────
type HistoryMsg = { role: 'user' | 'bot' | 'human'; content: string | null };
interface FixtureFile {
  history?: HistoryMsg[];
  messages?: HistoryMsg[];     // alias — same thing
  model?: string;
  memory?: string;
}
function loadFixture(file: string): { history: HistoryMsg[]; model?: string; memory?: string } {
  const raw = JSON.parse(fs.readFileSync(file, 'utf8')) as FixtureFile | HistoryMsg[];
  if (Array.isArray(raw)) return { history: raw };
  const history = raw.history ?? raw.messages ?? [];
  return { history, model: raw.model, memory: raw.memory };
}

// ── Main ─────────────────────────────────────────────────────────────
async function main(): Promise<void> {
  let history: HistoryMsg[];
  let modelId: string;
  let botDisplayName = '';
  let botId = overrideBotId;
  let memoryFromFixture: string | undefined;

  if (fixtureFile) {
    divider('fixture');
    console.log(`fixture: ${C.cyan(fixtureFile)}`);
    const fx = loadFixture(fixtureFile);
    history = fx.history;
    memoryFromFixture = fx.memory;
    modelId = overrideModelId ?? fx.model ?? '';
    if (!modelId) {
      console.error(C.red('fixture mode requires --model <id> (or "model" field in the fixture)'));
      process.exit(2);
    }
    if (botId) console.log(`bot_id (override): ${C.cyan(botId)}`);
  } else {
    // Real-conv mode: pull from Supabase.
    const supa = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
      db: { schema: 'pendingbot' },
    });
    divider('conv');
    console.log(`conversation_id: ${C.cyan(conversationId!)}`);

    if (!botId) {
      const { data: conv, error } = await supa
        .from('conversations')
        .select('bot_id')
        .eq('id', conversationId!)
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
        .eq('conversation_id', conversationId!)
        .neq('role', 'log')
        .order('created_at', { ascending: false })
        .limit(HISTORY_LIMIT),
      supa.from('bots').select('id, model_id, display_name').eq('id', botId).single(),
    ]);
    if (historyRes.error) throw new Error(`messages: ${historyRes.error.message}`);
    if (botRes.error || !botRes.data) throw new Error(`bot: ${botRes.error?.message ?? 'no row'}`);

    modelId = overrideModelId ?? (botRes.data.model_id as string);
    botDisplayName = (botRes.data.display_name as string) ?? '';
    history = (historyRes.data ?? []).reverse() as HistoryMsg[];
  }

  const hLen = history.filter((m) => m.content && m.content.trim()).length;

  if (botDisplayName) console.log(`bot.display_name: ${botDisplayName}`);
  console.log(`model_id:         ${C.cyan(modelId)}`);
  console.log(`history messages: ${hLen}`);
  if (hLen < 2) {
    console.error(C.red('history too short — runEnvelope would early-delete the row'));
    process.exit(1);
  }

  // Optional memory: --memory file > fixture's "memory" field > none.
  let memoryRepresentation: string | null = null;
  if (memoryFile) {
    memoryRepresentation = fs.readFileSync(memoryFile, 'utf8');
    console.log(`memory file:      ${memoryFile} (${memoryRepresentation.length} chars)`);
  } else if (memoryFromFixture) {
    memoryRepresentation = memoryFromFixture;
    console.log(`memory:           (from fixture, ${memoryRepresentation.length} chars)`);
  } else {
    console.log(C.dim('memory:           (none — pass --memory <file> to inject)'));
  }

  const initialUser = buildEnvelopeInitialUserContent({
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
      'X-Title': 'PendingBot/envelope-replay',
    },
  });

  // The web fetch helpers only read env.BRAVE_API_KEY /
  // env.FIRECRAWL_API_KEY. Cast through `unknown` because Env is the
  // worker bindings interface (R2/KV etc.) we don't have here.
  const webEnv = { BRAVE_API_KEY, FIRECRAWL_API_KEY } as unknown as Parameters<typeof runWebSearch>[0];

  // No-op meter — the offline harness has no Supabase to write
  // audit_web_tool_calls into. Calls are still recorded in-memory so
  // the script can print a summary at the end if we ever want one;
  // costs come out as 0 since the price map is empty.
  const replayMeter = WebToolMeter.withPrices({});

  const startedAt = Date.now();
  const onTurn = ({ turn, progress, newMessages }: EnvelopeTurnInfo): void => {
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

  const result = await runEnvelopeLoop({
    openai,
    modelId,
    systemPrompt,
    initialUserContent: initialUser,
    webSearch: stubSearch
      ? async () => []
      : (q) => runWebSearch(webEnv, { provider: 'brave', query: q, meter: replayMeter }),
    fetchUrl: stubFetch
      ? async (u) => ({ url: u, title: '', content: '(harness 跳过抓取)' })
      : (u) => runWebScrape(webEnv, { provider: 'firecrawl', url: u, meter: replayMeter }),
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

  divider('exploration outcome');
  if (result.reason === 'stopped') {
    console.log(C.green('reason=stopped — production runner would now run the writer phase.'));
    if (result.stopReason) console.log(`stop reason: ${result.stopReason}`);
  } else {
    console.log(C.dim(`reason=${result.reason} — no writer phase; runEnvelope would delete the row as 空来信.`));
  }
  if (result.lastAssistantText) {
    console.log();
    console.log(C.dim('last assistant text:'));
    console.log(result.lastAssistantText);
  }
  if (result.progress.notes.length > 0) {
    console.log();
    console.log(C.dim(`notes (${result.progress.notes.length}):`));
    for (const n of result.progress.notes) {
      console.log(`  - ${n.text}${n.source ? ` — ${n.source}` : ''}`);
    }
  }
  // Title / summary helpers are still re-exported for callers that
  // produce final markdown elsewhere; keep imports stable.
  void extractTitle;
  void extractSummary;
}

main().catch((err) => {
  console.error(C.red('replay failed:'), err);
  process.exit(1);
});
