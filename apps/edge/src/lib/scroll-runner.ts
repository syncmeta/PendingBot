import type { ChatCompletionMessageParam } from 'openai/resources/chat/completions';
import type { Env } from '../types';
import type { Json } from '../db/schema';
import { serviceClient } from './supabase';
import {
  recordAudit,
  resolveRoute,
  type ResolvedRoute,
} from '../llm/router';
import { getPrompt } from '../llm/prompt-loader';
import { estimateTokens } from '../llm/token-estimate';
import { getBotMemory } from './memory';
import {
  DEFAULT_SEARCH_PROVIDER,
  DEFAULT_SCRAPE_PROVIDER,
  makeSearch,
  makeScrape,
  type SearchProvider,
  type ScrapeProvider,
} from './web';
import {
  buildScrollInitialUserContent,
  extractSummary,
  extractTitle,
  HARD_CAP_TURNS,
  HISTORY_LIMIT,
  runScrollLoop,
  SILENT_TOKEN,
  stripLeadingTitleAndSubtitle,
  type ProgressState,
  type ScrollLoopResult,
  type ScrollTurnInfo,
  type UsageStats,
} from './scroll-loop';

// Worker-side orchestration shell around the pure agent loop in
// scroll-loop.ts. Owns the scroll_runs row lifecycle, history/memory
// loading, audit logging — i.e. everything the offline replay harness
// (scripts/scroll-replay.ts) does NOT want to do.
//
// Surfaced to users as 来信/Envelopes — config (explorer model,
// collaborator model, search/scrape providers, turn cap) lives on the
// trigger body and is frozen onto the row at INSERT time. Per-turn
// trace lands in scroll_runs.turns as the loop progresses so the iOS
// detail page can render the thinking process.

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

// Defaults baked at trigger time so a config schema change doesn't
// retroactively rewrite already-recorded runs. Mirrors what scroll-lab
// settled on as the production defaults the user asked for.
export const DEFAULT_EXPLORER_MODEL = '~google/gemini-flash-latest';
export const DEFAULT_COLLABORATOR_MODEL = '~google/gemini-flash-latest';
export const DEFAULT_TURN_CAP = 15;
// Cap on (history + framing prompts) as a fraction of the bot's main
// model context window. 35% leaves the rest for the loop's research
// turns + tool replies + the writer-phase article. User-tunable per
// conversation in envelope_settings.historyTokenBudgetPct.
export const DEFAULT_HISTORY_TOKEN_BUDGET_PCT = 35;
// If a bot's model_id isn't registered in llm_models we don't know its
// context window. Fall through to a conservative central estimate so
// the budget calculation still produces something sensible.
const FALLBACK_CONTEXT_WINDOW = 200_000;
// Hard ceiling on rows fetched from `messages` before token-trimming.
// Catches pathological accounts with millions of rows; in practice the
// token budget bites long before this does.
const HISTORY_ROW_CAP = 2000;

export interface EnvelopeSettings {
  explorerModel: string;
  collaboratorModel: string | null;
  searchProvider: SearchProvider;
  scrapeProvider: ScrapeProvider;
  turnCap: number;
  historyTokenBudgetPct: number;
}

const VALID_SEARCH: SearchProvider[] = ['brave', 'tavily', 'exa', 'serper'];
const VALID_SCRAPE: ScrapeProvider[] = ['firecrawl', 'tavily', 'exa'];

// Normalize a partial input (from the trigger body or persisted on
// the conversation) into a full settings object with defaults filled.
// Caps turnCap into [1, HARD_CAP_TURNS] so a stray UI value can't
// runaway-spend.
export function resolveEnvelopeSettings(
  input: Partial<EnvelopeSettings> | null | undefined,
): EnvelopeSettings {
  const i = input ?? {};
  const turnCap = Math.max(
    1,
    Math.min(HARD_CAP_TURNS, Math.floor(i.turnCap ?? DEFAULT_TURN_CAP)),
  );
  const search = (VALID_SEARCH as string[]).includes(i.searchProvider as string)
    ? (i.searchProvider as SearchProvider)
    : DEFAULT_SEARCH_PROVIDER;
  const scrape = (VALID_SCRAPE as string[]).includes(i.scrapeProvider as string)
    ? (i.scrapeProvider as ScrapeProvider)
    : DEFAULT_SCRAPE_PROVIDER;
  const explorerModel =
    typeof i.explorerModel === 'string' && i.explorerModel.trim()
      ? i.explorerModel.trim()
      : DEFAULT_EXPLORER_MODEL;
  const collaboratorModel =
    typeof i.collaboratorModel === 'string' && i.collaboratorModel.trim()
      ? i.collaboratorModel.trim()
      : DEFAULT_COLLABORATOR_MODEL;
  // Clamp to (0, 100] so the slider can't disable history outright nor
  // pretend to have more context than the model actually offers.
  const rawPct = Number(i.historyTokenBudgetPct);
  const historyTokenBudgetPct =
    Number.isFinite(rawPct) && rawPct > 0 && rawPct <= 100
      ? Math.round(rawPct)
      : DEFAULT_HISTORY_TOKEN_BUDGET_PCT;
  return {
    explorerModel,
    collaboratorModel,
    searchProvider: search,
    scrapeProvider: scrape,
    turnCap,
    historyTokenBudgetPct,
  };
}

export interface RunScrollInput {
  env: Env;
  scrollRunId: string;
  conversationId: string;
  userId: string;
  botId: string;
  settings: EnvelopeSettings;
}

// Compact wire shape the iOS detail page reads — same intent as the
// scroll-lab dev panel, minus per-call usage. Truncated tool replies
// keep the row small; iOS only needs enough to render the trace.
interface TurnTraceEntry {
  i: number;
  assistant?: string;
  reasoning?: string;
  tool_calls?: Array<{ name: string; args: Record<string, unknown> }>;
  tool_results?: Array<{ tool_call_id: string; content: string }>;
  collaborator?: string;
}

const TRACE_TEXT_LIMIT = 2000;
const TRACE_TOOL_LIMIT = 600;

function summarizeTurn(i: number, newMessages: ChatCompletionMessageParam[]): TurnTraceEntry {
  const entry: TurnTraceEntry = { i };
  for (const m of newMessages) {
    if (m.role === 'assistant') {
      const content = typeof m.content === 'string' ? m.content : '';
      if (content.trim()) entry.assistant = content.slice(0, TRACE_TEXT_LIMIT);
      const reasoning = (m as { reasoning_content?: string }).reasoning_content;
      if (typeof reasoning === 'string' && reasoning.trim()) {
        entry.reasoning = reasoning.slice(0, TRACE_TEXT_LIMIT);
      }
      const tcs = (m as {
        tool_calls?: Array<{ id: string; function: { name: string; arguments: string } }>;
      }).tool_calls;
      if (tcs?.length) {
        entry.tool_calls = tcs.map((tc) => {
          let parsed: Record<string, unknown> = {};
          try {
            parsed = JSON.parse(tc.function.arguments) as Record<string, unknown>;
          } catch {
            parsed = { _raw: tc.function.arguments.slice(0, TRACE_TOOL_LIMIT) };
          }
          return { name: tc.function.name, args: parsed };
        });
      }
    } else if (m.role === 'tool') {
      const content = typeof m.content === 'string' ? m.content : '';
      const toolCallId = (m as { tool_call_id: string }).tool_call_id;
      entry.tool_results ??= [];
      entry.tool_results.push({
        tool_call_id: toolCallId,
        content: content.slice(0, TRACE_TOOL_LIMIT),
      });
    } else if (m.role === 'user') {
      const content = typeof m.content === 'string' ? m.content : '';
      // The loop injects collaborator replies and (optional) budget hints
      // as `role: 'user'`. We only persist the collaborator's voice
      // here; budget hints are config noise the UI doesn't need.
      if (content.trim() && !content.startsWith('（系统提示')) {
        entry.collaborator = content.slice(0, TRACE_TEXT_LIMIT);
      }
    }
  }
  return entry;
}

export async function runScroll(input: RunScrollInput): Promise<void> {
  const { env, scrollRunId, conversationId, userId, botId, settings } = input;
  const supa = serviceClient(env);
  const startedAt = Date.now();

  await supa
    .from('scroll_runs')
    .update({
      started_at: new Date().toISOString(),
      status: 'running',
      settings: settings as unknown as Json,
    })
    .eq('id', scrollRunId);

  let route: ResolvedRoute | null = null;
  let result: ScrollLoopResult | null = null;
  const turnTrace: TurnTraceEntry[] = [];

  try {
    // We pull bot first because everything else (context-window lookup,
    // peer convs, memory) needs its row. The history is intentionally
    // *cross-conversation* — the letter is "from this bot to this user",
    // and any chat they've had together is fair game; pinning it to a
    // single conversation_id was an artifact of the original design.
    const botRes = await supa
      .from('bots')
      .select('id, model_id, display_name')
      .eq('id', botId)
      .single();
    if (botRes.error || !botRes.data) {
      throw new Error(`bot lookup failed: ${botRes.error?.message ?? 'no row'}`);
    }

    const [convIdsRes, botMemory, modelCtxRes] = await Promise.all([
      supa
        .from('conversations')
        .select('id')
        .eq('user_id', userId)
        .eq('bot_id', botId)
        .eq('conversation_type', 'user_bot'),
      getBotMemory(env, botId),
      supa
        .from('llm_models')
        .select('context_window')
        .eq('slug', botRes.data.model_id)
        .maybeSingle(),
    ]);

    const conversationIds = (convIdsRes.data ?? []).map((r) => r.id as string);
    if (conversationIds.length === 0) conversationIds.push(conversationId);
    const contextWindow = modelCtxRes.data?.context_window ?? FALLBACK_CONTEXT_WINDOW;
    const tokenBudget = Math.max(
      1024,
      Math.floor((contextWindow * settings.historyTokenBudgetPct) / 100),
    );

    const historyRes = await supa
      .from('messages')
      .select('role, content, created_at, conversation_id')
      .in('conversation_id', conversationIds)
      .neq('role', 'log')
      .order('created_at', { ascending: false })
      .limit(HISTORY_ROW_CAP);

    // Trim newest-first until adding the next row would push us past the
    // budget. The "framing" overhead — system prompt, injected directive,
    // memory block — is reserved up-front so a giant memory section
    // can't push the prompt over the model's hard limit.
    const framingTokens =
      estimateTokens(getPrompt('scroll')) +
      estimateTokens(getPrompt('scroll-injected')) +
      estimateTokens(botMemory?.representation ?? '') +
      512; // slack for transcript headers / separators / silent-token
    let used = framingTokens;
    const kept: Array<{
      role: 'user' | 'bot' | 'human';
      content: string | null;
      created_at: string;
    }> = [];
    for (const row of (historyRes.data ?? []) as Array<{
      role: 'user' | 'bot' | 'human';
      content: string | null;
      created_at: string;
    }>) {
      const cost = estimateTokens(row.content) + 8; // role + sep framing
      if (used + cost > tokenBudget) break;
      used += cost;
      kept.push(row);
    }
    // The loop assembles transcripts in chronological order. Sort here
    // by created_at so messages from different conversations interleave
    // correctly even though Supabase ordering was newest-first.
    kept.sort((a, b) => a.created_at.localeCompare(b.created_at));
    const history = kept as Array<{
      role: 'user' | 'bot' | 'human';
      content: string | null;
    }>;
    if (history.filter((m) => m.content && m.content.trim()).length < 2) {
      // Not enough material to write an envelope. Per "空奏折不落库": delete.
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

    // Resolve explorer + (optional) collaborator routes in parallel.
    // A failed collaborator resolve falls back to no-collaborator —
    // we want the run to proceed even if the configured collaborator
    // alias was retired or has no enabled provider.
    route = await resolveRoute(supa, env, {
      modelSlug: settings.explorerModel,
      taskType: 'scroll',
    });

    let collaboratorRoute: ResolvedRoute | null = null;
    if (settings.collaboratorModel) {
      try {
        collaboratorRoute = await resolveRoute(supa, env, {
          modelSlug: settings.collaboratorModel,
          taskType: 'scroll',
        });
      } catch (err) {
        console.warn(
          '[scroll-runner] collaborator route failed; running without collaborator:',
          (err as Error).message,
        );
      }
    }

    const collaboratorPrompt = getPrompt('scroll-collaborator');
    const transcript = history
      .filter((m) => m.content && m.content.trim())
      .map((m) => `${m.role === 'bot' ? '主探索者' : '朋友'}：${m.content}`)
      .join('\n');
    const memoryBlock = botMemory?.representation && botMemory.representation.trim()
      ? `## 朋友的背景\n${botMemory.representation.trim()}\n\n`
      : '';

    result = await runScrollLoop({
      openai: route.client,
      modelId: route.modelToCall,
      systemPrompt: getPrompt('scroll'),
      initialUserContent: initialUser,
      webSearch: makeSearch(env, settings.searchProvider),
      fetchUrl: makeScrape(env, settings.scrapeProvider),
      hardCapTurns: settings.turnCap,
      simulateCollaboratorReply: collaboratorRoute
        ? async ({ turn, newMessages }) => {
            const turnSummary = formatTurnForCollaborator(newMessages);
            const r = await collaboratorRoute!.client.chat.completions.create({
              model: collaboratorRoute!.modelToCall,
              messages: [
                { role: 'system', content: collaboratorPrompt },
                {
                  role: 'user',
                  content:
                    `${memoryBlock}## 朋友的聊天记录\n${transcript}\n\n` +
                    `## 主探索者第 ${turn} 轮做了什么\n${turnSummary}\n\n` +
                    `请用"协作者"的身份给主探索者一个简短的回应（直接说话，不要写"协作者："开头）：`,
                },
              ],
            });
            const text = r.choices[0]?.message?.content?.trim() ?? '';
            const promptDetails = (
              r.usage as { prompt_tokens_details?: { cached_tokens?: number } } | undefined
            )?.prompt_tokens_details;
            return {
              text,
              usage: {
                input: r.usage?.prompt_tokens ?? 0,
                output: r.usage?.completion_tokens ?? 0,
                total: r.usage?.total_tokens ?? 0,
                cached: promptDetails?.cached_tokens ?? 0,
              },
            };
          }
        : undefined,
      onTurn: async ({ turn, progress, newMessages }) => {
        turnTrace.push(summarizeTurn(turn, newMessages));
        await supa
          .from('scroll_runs')
          .update({
            progress: progress as unknown as Json,
            turns: turnTrace as unknown as Json,
            updated_at: new Date().toISOString(),
          })
          .eq('id', scrollRunId);
      },
      // Heartbeat between awaits within a turn — keeps the iOS detail
      // page ticking so a slow model + slow scrape doesn't look frozen.
      // Each heartbeat is a tiny progress-only UPDATE (no turns rewrite)
      // so we can fire ~3 of these per turn without much overhead.
      onActivity: async (snapshot) => {
        await supa
          .from('scroll_runs')
          .update({
            progress: snapshot as unknown as Json,
            updated_at: new Date().toISOString(),
          })
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

    // Writer phase — only on a deliberate stop_exploring exit.
    let writeArticle = '';
    let writeUsage: UsageStats | undefined;
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

      const writeResp = await route.client.chat.completions.create({
        model: route.modelToCall,
        messages: [
          { role: 'system', content: getPrompt('scroll-write') },
          { role: 'user', content: writeUser },
        ],
      });
      writeArticle = (writeResp.choices[0]?.message?.content ?? '').trim();
      const writePromptDetails = (
        writeResp.usage as { prompt_tokens_details?: { cached_tokens?: number } } | undefined
      )?.prompt_tokens_details;
      writeUsage = {
        input: writeResp.usage?.prompt_tokens ?? 0,
        output: writeResp.usage?.completion_tokens ?? 0,
        total: writeResp.usage?.total_tokens ?? 0,
        cached: writePromptDetails?.cached_tokens ?? 0,
      };
      writeGenerationId = writeResp.id;
      result.usage.input += writeUsage.input;
      result.usage.output += writeUsage.output;
      result.usage.total += writeUsage.total;
      result.usage.cached += writeUsage.cached;
    }

    const finalProgress: ProgressState = { ...result.progress, phase: 'done' };
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
    // Title + subtitle live in their own columns and are rendered by
    // the iOS header; stripping them out of body_md keeps the markdown
    // body from showing them a second time.
    const cleanedBody = stripLeadingTitleAndSubtitle(stripped);

    await supa
      .from('scroll_runs')
      .update({
        status: 'done',
        body_md: cleanedBody,
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

// Render the explorer's most recent turn as a short transcript the
// collaborator model can chew on. Mirrors apps/scroll-lab's helper —
// keep them in sync if the format ever changes there.
function formatTurnForCollaborator(newMessages: ChatCompletionMessageParam[]): string {
  const lines: string[] = [];
  for (const m of newMessages) {
    if (m.role === 'assistant') {
      const content = typeof m.content === 'string' ? m.content : '';
      if (content.trim()) lines.push(`主探索者：${content}`);
      const tcs = (m as { tool_calls?: Array<{ function: { name: string; arguments: string } }> })
        .tool_calls;
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
      const content = typeof m.content === 'string' ? m.content : '';
      lines.push(`  工具返回: ${content.slice(0, 400)}`);
    }
  }
  return lines.join('\n');
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
