import type { Env } from '../types';
import type { Json } from '../db/schema';
import { serviceClient } from './supabase';
import {
  recordAudit,
  resolveRoute,
  type ResolvedRoute,
} from '../llm/router';
import { getPrompt } from '../llm/prompt-loader';
import { getBotMemory } from './memory';
import { braveSearch, firecrawlScrape } from './web';
import {
  buildScrollInitialUserContent,
  extractSummary,
  extractTitle,
  HISTORY_LIMIT,
  runScrollLoop,
  SILENT_TOKEN,
  type ProgressState,
  type ScrollLoopResult,
  type UsageStats,
} from './scroll-loop';

// Worker-side orchestration shell around the pure agent loop in
// scroll-loop.ts. Owns the scroll_runs row lifecycle, history/memory
// loading, audit logging — i.e. everything the offline replay harness
// (scripts/scroll-replay.ts) does NOT want to do.
//
//   - Reads the bot's own conversation with this user (transcript +
//     Honcho representation) as the bot's memory of the friend.
//   - Loops with 5 tools — propose_plan / web_search / fetch_url /
//     take_note / stop_exploring — until the model calls
//     stop_exploring (or the loop is capped/cancelled).
//   - On reason='stopped', a separate writer call (scroll-write.md +
//     same model) takes the gathered notes/URLs and produces the
//     final article. No more single-phase "no tool call → article".
//   - Empty/silent writer outputs are deleted, not stored. ("空奏折不落库.")
//   - Final article + extracted title/summary land on the row; iOS
//     surfaces it via Realtime in the dedicated 奏折 tab.

// Re-export the loop-level types/helpers so existing callers that
// already imported from scroll-runner don't break.
export {
  buildScrollInitialUserContent,
  extractSummary,
  extractTitle,
  formatTranscript,
  HARD_CAP_TURNS,
  HISTORY_LIMIT,
  MAX_WALL_MS,
  READ_TRUNCATE_CHARS,
  runScrollLoop,
  SILENT_TOKEN,
  type NoteEntry,
  type ProgressState,
  type ScrollLoopDeps,
  type ScrollLoopExitReason,
  type ScrollLoopResult,
  type ScrollToolDeps,
  type ScrollTurnInfo,
} from './scroll-loop';

export interface RunScrollInput {
  env: Env;
  scrollRunId: string;
  conversationId: string;
  userId: string;
  botId: string;
}

export async function runScroll(input: RunScrollInput): Promise<void> {
  const { env, scrollRunId, conversationId, userId, botId } = input;
  const supa = serviceClient(env);
  const startedAt = Date.now();

  await supa
    .from('scroll_runs')
    .update({ started_at: new Date().toISOString(), status: 'running' })
    .eq('id', scrollRunId);

  let modelId = '';
  let route: ResolvedRoute | null = null;
  let result: ScrollLoopResult | null = null;

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
    modelId = botRes.data.model_id as string;

    const history = (historyRes.data ?? []).reverse() as Array<{
      role: 'user' | 'bot' | 'human';
      content: string | null;
    }>;
    if (history.filter((m) => m.content && m.content.trim()).length < 2) {
      // Not enough material to write a memorial. Per "空奏折不落库": delete.
      await supa.from('scroll_runs').delete().eq('id', scrollRunId);
      return;
    }

    const initialUser = buildScrollInitialUserContent({
      history,
      memoryRepresentation: botMemory?.representation,
      injectedPrompt: getPrompt('scroll-injected'),
    });

    const initialProgress: ProgressState = {
      phase: 'plan',
      notes: [],
      visited_urls: [],
      plan_rounds: 0,
    };
    await supa
      .from('scroll_runs')
      .update({ progress: initialProgress as unknown as Json, updated_at: new Date().toISOString() })
      .eq('id', scrollRunId);

    // ── Agent loop ─────────────────────────────────────────────────────
    // resolveRoute gives us the OpenAI-compatible client pointed at the
    // chosen provider (WR primary, OR fallback) plus the alias-specific
    // model id. scroll-loop then drives the multi-turn agent loop with
    // those, fully unaware of our routing concerns.
    route = await resolveRoute(supa, env, {
      modelSlug: modelId,
      taskType: 'scroll',
    });
    result = await runScrollLoop({
      openai: route.client,
      modelId: route.modelToCall,
      systemPrompt: getPrompt('scroll'),
      initialUserContent: initialUser,
      webSearch: (q) => braveSearch(env, q),
      fetchUrl: (u) => firecrawlScrape(env, u),
      onTurn: async ({ progress }) => {
        await supa
          .from('scroll_runs')
          .update({ progress: progress as unknown as Json, updated_at: new Date().toISOString() })
          .eq('id', scrollRunId);
      },
      isCancelled: () => isRunCancelled(supa, scrollRunId),
    });

    if (result.reason === 'cancelled') {
      await supa
        .from('scroll_runs')
        .update({ status: 'cancelled', finished_at: new Date().toISOString() })
        .eq('id', scrollRunId);
      return;
    }

    // ── Writer phase ──────────────────────────────────────────────────
    // The exploration loop never produces an article anymore. Only on
    // reason==='stopped' do we have a clean signal to write; any other
    // exit (turn_cap / wall_cap / no_tool_call / no_choice) means the
    // model didn't reach a deliberate stop, so nothing to write.
    let writeArticle = '';
    let writeUsage: typeof result.usage | undefined;
    let writeGenerationId: string | undefined;
    if (result.reason === 'stopped') {
      const notes = result.progress.notes ?? [];
      const urls = result.progress.visited_urls ?? [];
      const notesBlock =
        notes.length > 0
          ? '## 主探索者记录的关键笔记\n' +
            notes
              .map((n, i) => `${i + 1}. ${n.text}${n.source ? ` — ${n.source}` : ''}`)
              .join('\n')
          : '## 主探索者记录的关键笔记\n（没有记笔记）';
      const urlsBlock =
        urls.length > 0
          ? '## 主探索者访问过的链接\n' + urls.map((u) => `- ${u}`).join('\n')
          : '';
      const stopBlock = result.stopReason
        ? `## 主探索者停止探索的理由\n${result.stopReason}`
        : '';
      const writeUser = [
        initialUser,
        '---',
        notesBlock,
        urlsBlock,
        stopBlock,
        '## 任务\n基于上面的笔记和聊天记录，按 system prompt 的要求给朋友写一篇文章。',
      ]
        .filter((s) => s.trim())
        .join('\n\n');

      const writeResp = await openrouterClient(env).chat.completions.create({
        model: modelId,
        messages: [
          { role: 'system', content: getPrompt('scroll-write') },
          { role: 'user', content: writeUser },
        ],
      });
      writeArticle = (writeResp.choices[0]?.message?.content ?? '').trim();
      const writePromptDetails = (writeResp.usage as { prompt_tokens_details?: { cached_tokens?: number } } | undefined)
        ?.prompt_tokens_details;
      writeUsage = {
        input: writeResp.usage?.prompt_tokens ?? 0,
        output: writeResp.usage?.completion_tokens ?? 0,
        total: writeResp.usage?.total_tokens ?? 0,
        cached: writePromptDetails?.cached_tokens ?? 0,
      };
      writeGenerationId = writeResp.id;
      // Fold writer-phase tokens into the run's totals so the audit
      // row reflects actual cost, not just the exploration loop.
      result.usage.input += writeUsage.input;
      result.usage.output += writeUsage.output;
      result.usage.total += writeUsage.total;
      result.usage.cached += writeUsage.cached;
    }

    // ── Finalize ───────────────────────────────────────────────────────
    const finalProgress: ProgressState = { ...result.progress, phase: 'done' };

    // Empty / silent → don't store. (空奏折不落库.)
    const stripped = writeArticle.trim();
    const isEmpty = !stripped || stripped === SILENT_TOKEN || stripped.length < 20;
    if (isEmpty) {
      await supa.from('scroll_runs').delete().eq('id', scrollRunId);
      await auditRun(supa, route, {
        userId,
        conversationId,
        scrollRunId,
        botId,
        usage: result.usage,
        generationId: writeGenerationId ?? result.lastGenerationId,
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
        progress: finalProgress as unknown as Json,
        finished_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq('id', scrollRunId);

    await auditRun(supa, route, {
      userId,
      conversationId,
      scrollRunId,
      botId,
      usage: result.usage,
      generationId: result.lastGenerationId,
      startedAt,
      action: 'memorial',
    });
  } catch (err) {
    console.error('[scroll-runner]', err);
    const errProgress: ProgressState = {
      ...(result?.progress ?? {
        phase: 'plan',
        notes: [],
        visited_urls: [],
        plan_rounds: 0,
      }),
      phase: 'error',
    };
    await supa
      .from('scroll_runs')
      .update({
        status: 'error',
        finished_at: new Date().toISOString(),
        progress: errProgress as unknown as Json,
        updated_at: new Date().toISOString(),
      })
      .eq('id', scrollRunId);
  }
}

async function isRunCancelled(
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

interface AuditInput {
  userId: string;
  conversationId: string;
  scrollRunId: string;
  botId: string;
  // scroll-loop's UsageStats: input includes cached, total = input+output,
  // cached is the cache-hit subset of input. We split for recordAudit so
  // accounting is non-overlapping (input - cached). cache_creation isn't
  // surfaced by scroll-loop yet — passes 0 for cacheWrite.
  usage: UsageStats;
  generationId?: string;
  startedAt: number;
  action: 'memorial' | 'silent';
}

async function auditRun(
  supa: ReturnType<typeof serviceClient>,
  route: ResolvedRoute,
  i: AuditInput,
): Promise<void> {
  const cacheRead = i.usage.cached;
  const freshInput = Math.max(0, i.usage.input - cacheRead);
  await recordAudit(supa, route, {
    userId: i.userId,
    conversationId: i.conversationId,
    taskType: 'scroll',
    startedAt: i.startedAt,
    generationId: i.generationId,
    status: 'success',
    inputTokens: freshInput,
    outputTokens: i.usage.output,
    cacheReadTokens: cacheRead,
    cacheWriteTokens: 0,
    metadata: { scroll_run_id: i.scrollRunId, bot_id: i.botId, action: i.action },
  });
}
