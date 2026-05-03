import type {
  ChatCompletionMessageParam,
  ChatCompletionMessageToolCall,
  ChatCompletionTool,
} from 'openai/resources/chat/completions';
import type { Env } from '../types';
import type { Json } from '../db/schema';
import { serviceClient } from './supabase';
import { openrouterClient } from '../llm/client';
import { getPrompt } from '../llm/prompt-loader';
import { getBotMemory } from './memory';
import { jinaSearch, jinaRead } from './jina';

// Scroll/奏折 runner — direct port of the agent loop in
// PendingBot/surf-test (the user's design sandbox), adapted to run
// server-side without a human in the loop:
//
//   - Reads the bot's own conversation with this user (transcript +
//     Honcho representation) as the bot's memory of the friend.
//   - Loops with 4 tools — propose_plan / web_search / fetch_url /
//     take_note — until the model returns a final assistant turn with
//     no tool calls. That final text is the article.
//   - propose_plan in surf-test pauses for human confirmation; here we
//     auto-reply "用户：继续，按你的计划执行。" so the loop carries on.
//     Same prompt, no UI hooks needed yet (manual trigger is the only
//     entry point for now).
//   - Empty/silent finishes are deleted, not stored. ("空奏折不落库.")
//   - Final article + extracted title/summary land on the row; iOS
//     surfaces it via Realtime in the dedicated 奏折 tab.

const HISTORY_LIMIT = 30;
const HARD_CAP_TURNS = 30;            // safety net against runaway loops
const MAX_WALL_MS = 4 * 60 * 1000;    // Worker hard cap is ~5min, leave margin
const READ_TRUNCATE_CHARS = 8000;     // keep tool replies bounded
const SILENT_TOKEN = '[SILENT]';

const TOOLS: ChatCompletionTool[] = [
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

export interface RunScrollInput {
  env: Env;
  scrollRunId: string;
  conversationId: string;
  userId: string;
  botId: string;
}

interface NoteEntry {
  text: string;
  source?: string;
  t: number;
}

interface ProgressState {
  phase: 'gather' | 'plan' | 'research' | 'compose' | 'done' | 'error';
  notes: NoteEntry[];
  visited_urls: string[];
  plan_rounds: number;
}

function safeParse(s: string): Record<string, unknown> {
  try {
    return JSON.parse(s) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function formatTranscript(
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
function extractTitle(body: string): string | null {
  const lines = body.split('\n').map((l) => l.trim()).filter(Boolean);
  for (const line of lines) {
    const m = line.match(/^#{1,3}\s+(.+)$/);
    if (m) return m[1].trim().slice(0, 30);
  }
  return lines[0] ? lines[0].slice(0, 30) : null;
}

// Summary heuristic: first paragraph (until blank line), markdown stripped,
// capped at 100 chars. Skips a title-like first line if present.
function extractSummary(body: string): string | null {
  const blocks = body.split(/\n\s*\n/).map((b) => b.trim()).filter(Boolean);
  // If the first block is a single short heading, skip past it.
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

export async function runScroll(input: RunScrollInput): Promise<void> {
  const { env, scrollRunId, conversationId, userId, botId } = input;
  const supa = serviceClient(env);
  const startedAt = Date.now();

  let usage = { input: 0, output: 0, total: 0 };
  let lastGenerationId: string | undefined;

  const progress: ProgressState = {
    phase: 'gather',
    notes: [],
    visited_urls: [],
    plan_rounds: 0,
  };

  const persistProgress = async () => {
    await supa
      .from('scroll_runs')
      .update({ progress: progress as unknown as Json, updated_at: new Date().toISOString() })
      .eq('id', scrollRunId);
  };

  await supa
    .from('scroll_runs')
    .update({ started_at: new Date().toISOString(), status: 'running' })
    .eq('id', scrollRunId);

  try {
    // ── Gather: conv history + bot details + memory ─────────────────────
    const [historyRes, botRes, botMemory] = await Promise.all([
      supa
        .from('messages')
        .select('role, content, created_at')
        .eq('conversation_id', conversationId)
        .neq('role', 'log')
        .order('created_at', { ascending: false })
        .limit(HISTORY_LIMIT),
      supa.from('bots').select('id, model_id, display_name').eq('id', botId).single(),
      getBotMemory(env, botId),
    ]);

    if (botRes.error || !botRes.data) {
      throw new Error(`bot lookup failed: ${botRes.error?.message ?? 'no row'}`);
    }
    const modelId = botRes.data.model_id as string;

    const history = (historyRes.data ?? []).reverse() as Array<{
      role: 'user' | 'bot' | 'human';
      content: string | null;
    }>;
    if (history.filter((m) => m.content && m.content.trim()).length < 2) {
      // Not enough material to write a memorial. Per "空奏折不落库": delete.
      await supa.from('scroll_runs').delete().eq('id', scrollRunId);
      return;
    }

    const transcript = formatTranscript(history);
    const memoryBlock = botMemory && botMemory.representation.trim()
      ? `## 我对这位朋友的长期观察\n${botMemory.representation.trim()}\n\n`
      : '';

    const initialUser = [
      memoryBlock + '## 朋友的聊天记录\n\n' + transcript,
      '---',
      getPrompt('scroll-injected'),
      '（请按工具说明的工作节奏推进。）',
    ].join('\n\n');

    progress.phase = 'plan';
    await persistProgress();

    // ── Agent loop ─────────────────────────────────────────────────────
    const messages: ChatCompletionMessageParam[] = [
      { role: 'system', content: getPrompt('scroll') },
      { role: 'user', content: initialUser },
    ];

    const openai = openrouterClient(env);
    let finalArticle = '';

    for (let turn = 0; turn < HARD_CAP_TURNS; turn++) {
      if (Date.now() - startedAt > MAX_WALL_MS) {
        // Wall-time budget hit — stop the loop and let whatever we have
        // become the article (still subject to the empty-check below).
        break;
      }
      const cancelled = await isCancelled(supa, scrollRunId);
      if (cancelled) {
        await supa
          .from('scroll_runs')
          .update({ status: 'cancelled', finished_at: new Date().toISOString() })
          .eq('id', scrollRunId);
        return;
      }

      const completion = await openai.chat.completions.create({
        model: modelId,
        messages,
        tools: TOOLS,
        tool_choice: 'auto',
        parallel_tool_calls: true,
      });
      lastGenerationId = completion.id;
      if (completion.usage) {
        usage.input += completion.usage.prompt_tokens ?? 0;
        usage.output += completion.usage.completion_tokens ?? 0;
        usage.total += completion.usage.total_tokens ?? 0;
      }

      const choice = completion.choices[0];
      const msg = choice?.message;
      if (!msg) break;

      const toolCalls = (msg.tool_calls ?? []) as ChatCompletionMessageToolCall[];
      const assistantContent = msg.content ?? '';

      // Push the assistant turn as-is (with tool_calls if any).
      messages.push({
        role: 'assistant',
        content: assistantContent,
        ...(toolCalls.length ? { tool_calls: toolCalls } : {}),
      });

      if (toolCalls.length === 0) {
        // No tool call → this assistant text is the final article.
        finalArticle = assistantContent.trim();
        break;
      }

      // Execute every tool call, in parallel where independent. Each
      // pushes a `role:'tool'` reply back into messages.
      const toolReplies = await Promise.all(
        toolCalls.map((tc) => execTool(env, tc, progress)),
      );
      for (let i = 0; i < toolCalls.length; i++) {
        messages.push({
          role: 'tool',
          tool_call_id: toolCalls[i].id,
          content: toolReplies[i],
        });
      }

      // Persist progress so the iOS feed shimmer reflects what's happening.
      progress.phase = progress.notes.length > 0 ? 'compose' : 'research';
      await persistProgress();
    }

    // ── Finalize ───────────────────────────────────────────────────────
    progress.phase = 'done';

    // Empty / silent → don't store. (空奏折不落库.)
    const stripped = finalArticle.trim();
    const isEmpty =
      !stripped ||
      stripped === SILENT_TOKEN ||
      stripped.length < 20;
    if (isEmpty) {
      await supa.from('scroll_runs').delete().eq('id', scrollRunId);
      await auditRun(supa, {
        userId,
        conversationId,
        scrollRunId,
        botId,
        modelId,
        usage,
        generationId: lastGenerationId,
        startedAt,
        action: 'silent',
      });
      return;
    }

    const title = extractTitle(stripped);
    const summary = extractSummary(stripped);

    await supa
      .from('scroll_runs')
      .update({
        status: 'done',
        body_md: stripped,
        title,
        summary,
        progress: progress as unknown as Json,
        finished_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq('id', scrollRunId);

    await auditRun(supa, {
      userId,
      conversationId,
      scrollRunId,
      botId,
      modelId,
      usage,
      generationId: lastGenerationId,
      startedAt,
      action: 'memorial',
    });
  } catch (err) {
    console.error('[scroll-runner]', err);
    progress.phase = 'error';
    await supa
      .from('scroll_runs')
      .update({
        status: 'error',
        finished_at: new Date().toISOString(),
        progress: progress as unknown as Json,
        updated_at: new Date().toISOString(),
      })
      .eq('id', scrollRunId);
  }
}

async function isCancelled(
  supa: ReturnType<typeof serviceClient>,
  scrollRunId: string,
): Promise<boolean> {
  const { data } = await supa
    .from('scroll_runs')
    .select('status')
    .eq('id', scrollRunId)
    .maybeSingle();
  return data?.status === 'cancelled';
}

// Execute a single tool call. Side effects (notes / visited urls) are
// recorded onto `progress` so the runner can persist them. The return
// value is the string content the model sees back.
async function execTool(
  env: Env,
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
      const hits = await jinaSearch(env, query);
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
      const page = await jinaRead(env, url);
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

interface AuditInput {
  userId: string;
  conversationId: string;
  scrollRunId: string;
  botId: string;
  modelId: string;
  usage: { input: number; output: number; total: number };
  generationId?: string;
  startedAt: number;
  action: 'memorial' | 'silent';
}

async function auditRun(
  supa: ReturnType<typeof serviceClient>,
  i: AuditInput,
): Promise<void> {
  await supa.from('audit_log').insert({
    user_id: i.userId,
    conversation_id: i.conversationId,
    task_type: 'scroll',
    model_id: i.modelId,
    input_tokens: i.usage.input,
    output_tokens: i.usage.output,
    total_tokens: i.usage.total,
    generation_id: i.generationId,
    latency_ms: Date.now() - i.startedAt,
    metadata: { scroll_run_id: i.scrollRunId, bot_id: i.botId, action: i.action },
  });
}
