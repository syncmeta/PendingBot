import type { Env } from '../types';
import type { Json } from '../db/schema';
import { serviceClient } from './supabase';
import { openrouterClient } from '../llm/client';
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
} from './scroll-loop';

// Worker-side orchestration shell around the pure agent loop in
// scroll-loop.ts. Owns the scroll_runs row lifecycle, history/memory
// loading, audit logging — i.e. everything the offline replay harness
// (scripts/scroll-replay.ts) does NOT want to do.
//
//   - Reads the bot's own conversation with this user (transcript +
//     Honcho representation) as the bot's memory of the friend.
//   - Loops with 4 tools — propose_plan / web_search / fetch_url /
//     take_note — until the model returns a final assistant turn with
//     no tool calls. That final text is the article.
//   - propose_plan in surf-test pauses for human confirmation; here we
//     auto-reply "用户：继续，按你的计划执行。" so the loop carries on.
//   - Empty/silent finishes are deleted, not stored. ("空奏折不落库.")
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
    result = await runScrollLoop({
      openai: openrouterClient(env),
      modelId,
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

    // ── Finalize ───────────────────────────────────────────────────────
    const finalProgress: ProgressState = { ...result.progress, phase: 'done' };

    // Empty / silent → don't store. (空奏折不落库.)
    const stripped = result.finalArticle.trim();
    const isEmpty = !stripped || stripped === SILENT_TOKEN || stripped.length < 20;
    if (isEmpty) {
      await supa.from('scroll_runs').delete().eq('id', scrollRunId);
      await auditRun(supa, {
        userId,
        conversationId,
        scrollRunId,
        botId,
        modelId,
        usage: result.usage,
        generationId: result.lastGenerationId,
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

    await auditRun(supa, {
      userId,
      conversationId,
      scrollRunId,
      botId,
      modelId,
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
