import type {
  ChatCompletionCreateParamsNonStreaming,
  ChatCompletionMessageParam,
} from 'openai/resources/chat/completions';
import type { Env } from '../types';
import type { Json } from '../db/schema';
import { serviceClient } from './supabase';
import {
  enqueueAudit,
  resolveRoute,
  type ResolvedRoute,
} from '../llm/router';
import {
  mergeProviderUsageDetails,
  usageFromCompletion,
} from '../llm/provider-usage';
import { ensurePromptOverridesLoaded, getPrompt } from '../llm/prompt-loader';
import { estimateTokens } from '../llm/token-estimate';
import { modelContextWindow } from '../llm/catalog';
import { uuidv7 } from './ids';
import { getBotMemory } from './memory';
import { mcpClient } from '../mcp/client';
import { loadToolRegistry, applyToolRegistry } from './tools-registry';
import { parseExaFetchPayload, parseExaSearchPayload } from '../mcp/parsers';
import { WebToolMeter, type WebToolUsage } from './web-meter';
import {
  buildEnvelopeInitialUserContent,
  extractSummary,
  extractTitle,
  HARD_CAP_TURNS,
  HISTORY_LIMIT,
  runEnvelopeLoop,
  SILENT_TOKEN,
  stripLeadingTitleAndSubtitle,
  TOOLS,
  type ProgressState,
  type EnvelopeLoopResult,
  type EnvelopeTurnInfo,
  type UsageStats,
} from './envelope-loop';

// Worker-side orchestration shell around the pure agent loop in
// envelope-loop.ts. Owns the envelope_runs row lifecycle, history/memory
// loading, audit logging, and production runtime dependencies.
//
// Surfaced to users as 来信/Envelopes — config (explorer model,
// collaborator model, turn cap) lives on the trigger body and is frozen
// onto the row at INSERT time. Per-turn trace lands in envelope_runs.turns
// as the loop progresses so the iOS detail page can render the thinking
// process.
//
// Naming note: audit_log.task_type carries `'scroll'` for historical
// rows from before the rename; new runs write `'envelope'`. iOS
// WalletView maps both to the same display label.

export {
  buildEnvelopeInitialUserContent,
  extractSummary,
  extractTitle,
  formatTranscript,
  HARD_CAP_TURNS,
  HISTORY_LIMIT,
  MAX_WALL_MS,
  READ_TRUNCATE_CHARS,
  runEnvelopeLoop,
  SILENT_TOKEN,
  type NoteEntry,
  type ProgressState,
  type EnvelopeLoopDeps,
  type EnvelopeLoopExitReason,
  type EnvelopeLoopResult,
  type EnvelopeToolDeps,
  type EnvelopeTurnInfo,
} from './envelope-loop';

// Model defaults are board-configurable system model-roles (envelopeExplorer /
// envelopeCollaborator, see lib/model-roles.ts). The caller resolves them and
// passes the slugs into resolveEnvelopeSettings so they're baked at trigger time
// (a later config change won't retroactively rewrite already-recorded runs).
// Code default for both = ~google/gemini-flash-latest.
export const DEFAULT_TURN_CAP = 15;
// Cap on (history + framing prompts) as a fraction of the bot's main
// model context window. 35% leaves the rest for the loop's research
// turns + tool replies + the writer-phase article. User-tunable per bot
// via bots.config.envelope.historyTokenBudgetPct.
export const DEFAULT_HISTORY_TOKEN_BUDGET_PCT = 35;
// If a bot's model_id isn't in the live model catalog we don't know its
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
  turnCap: number;
  historyTokenBudgetPct: number;
}

// Normalize a partial input (from the trigger body or persisted on
// the conversation) into a full settings object with defaults filled.
// Caps turnCap into [1, HARD_CAP_TURNS] so a stray UI value can't
// runaway-spend.
//
// Search/scrape providers are no longer configurable — both tools route
// through the MCP client to Exa's hosted MCP. Legacy `searchProvider` /
// `scrapeProvider` keys on persisted rows are ignored on read.
export function resolveEnvelopeSettings(
  input: Partial<EnvelopeSettings> | null | undefined,
  defaults: { explorerModel: string; collaboratorModel: string },
): EnvelopeSettings {
  const i = input ?? {};
  const turnCap = Math.max(
    1,
    Math.min(HARD_CAP_TURNS, Math.floor(i.turnCap ?? DEFAULT_TURN_CAP)),
  );
  const explorerModel =
    typeof i.explorerModel === 'string' && i.explorerModel.trim()
      ? i.explorerModel.trim()
      : defaults.explorerModel;
  const collaboratorModel =
    typeof i.collaboratorModel === 'string' && i.collaboratorModel.trim()
      ? i.collaboratorModel.trim()
      : defaults.collaboratorModel;
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
    turnCap,
    historyTokenBudgetPct,
  };
}

export interface RunEnvelopeInput {
  env: Env;
  envelopeRunId: string;
  conversationId: string;
  userId: string;
  botId: string;
  settings: EnvelopeSettings;
}

// Compact wire shape the iOS detail page reads. Truncated tool replies keep
// the row small; iOS only needs enough to render the trace.
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

export async function runEnvelope(input: RunEnvelopeInput): Promise<void> {
  const { env, envelopeRunId, conversationId, userId, botId, settings } = input;
  const supa = serviceClient(env);
  await ensurePromptOverridesLoaded(env);
  const startedAt = Date.now();
  const turnId = uuidv7();

  await supa
    .from('envelope_runs')
    .update({
      started_at: new Date().toISOString(),
      status: 'running',
      settings: settings as unknown as Json,
    })
    .eq('id', envelopeRunId);

  let route: ResolvedRoute | null = null;
  let result: EnvelopeLoopResult | null = null;
  const turnTrace: TurnTraceEntry[] = [];
  // Web-tool meter for this envelope run. Covers every search_web /
  // fetch_url call the explorer fires; snapshot is handed to recordAudit
  // at the end so tool spend lands in audit_web_tool_calls and folds
  // into the billed credits.
  const webMeter = await WebToolMeter.create(supa);

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

    const [convIdsRes, botMemory, modelCtx] = await Promise.all([
      supa
        .from('conversations')
        .select('id')
        .eq('user_id', userId)
        .eq('bot_id', botId)
        .eq('conversation_type', 'user_bot'),
      getBotMemory(env, botId),
      modelContextWindow(botRes.data.model_id),
    ]);

    const conversationIds = (convIdsRes.data ?? []).map((r) => r.id as string);
    if (conversationIds.length === 0) conversationIds.push(conversationId);
    const contextWindow = modelCtx ?? FALLBACK_CONTEXT_WINDOW;
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
      estimateTokens(getPrompt('envelope')) +
      estimateTokens(getPrompt('envelope-injected')) +
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
      await supa.from('envelope_runs').delete().eq('id', envelopeRunId);
      return;
    }

    const initialUser = buildEnvelopeInitialUserContent({
      history,
      memoryRepresentation: botMemory?.representation,
      injectedPrompt: getPrompt('envelope-injected'),
    });

    const initialProgress: ProgressState = {
      phase: 'plan',
      notes: [],
      visited_urls: [],
      plan_rounds: 0,
    };
    await supa
      .from('envelope_runs')
      .update({ progress: initialProgress as unknown as Json, updated_at: new Date().toISOString() })
      .eq('id', envelopeRunId);

    // Resolve explorer + (optional) collaborator routes in parallel.
    // A failed collaborator resolve falls back to no-collaborator —
    // we want the run to proceed even if the configured collaborator
    // alias was retired or has no enabled provider.
    route = await resolveRoute(supa, env, {
      modelSlug: settings.explorerModel,
      taskType: 'envelope',
      metadata: { turnId },
    });

    let collaboratorRoute: ResolvedRoute | null = null;
    if (settings.collaboratorModel) {
      try {
        collaboratorRoute = await resolveRoute(supa, env, {
          modelSlug: settings.collaboratorModel,
          taskType: 'envelope',
          metadata: { turnId },
        });
      } catch (err) {
        console.warn(
          '[envelope-runner] collaborator route failed; running without collaborator:',
          (err as Error).message,
        );
      }
    }
    const mainRoute = route;

    const collaboratorPrompt = getPrompt('envelope-collaborator');
    const transcript = history
      .filter((m) => m.content && m.content.trim())
      .map((m) => `${m.role === 'bot' ? '主探索者' : '朋友'}：${m.content}`)
      .join('\n');
    const memoryBlock = botMemory?.representation && botMemory.representation.trim()
      ? `## 朋友的背景\n${botMemory.representation.trim()}\n\n`
      : '';

    // Strict allowlist from the tools registry — disabling a row in
    // the board "Tools" page strips it from the envelope advertise
    // list within ~1 min, and any board-edited model_description
    // override is swapped in here. Null = registry unreachable;
    // default to the full TOOLS list rather than serving an empty
    // surface.
    const envelopeTools = applyToolRegistry(
      TOOLS,
      await loadToolRegistry(env, 'envelope'),
    );

    result = await runEnvelopeLoop({
      openai: mainRoute.client,
      modelId: mainRoute.modelToCall,
      systemPrompt: getPrompt('envelope'),
      initialUserContent: initialUser,
      tools: envelopeTools,
      webSearch: async (query) => {
        const { text, isError } = await mcpClient.callTool(
          'web_search_exa',
          { query },
          { env, meter: webMeter },
        );
        if (isError) return [];
        return parseExaSearchPayload(text);
      },
      fetchUrl: async (url) => {
        const { text, isError } = await mcpClient.callTool(
          'web_fetch_exa',
          { url },
          { env, meter: webMeter },
        );
        if (isError) return { url, title: '', content: '' };
        return parseExaFetchPayload(url, text);
      },
      hardCapTurns: settings.turnCap,
      simulateCollaboratorReply: collaboratorRoute
        ? async ({ turn, newMessages }) => {
            const turnSummary = formatTurnForCollaborator(newMessages);
            const request = {
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
            } as ChatCompletionCreateParamsNonStreaming;
            const r = await collaboratorRoute!.client.chat.completions.create(request);
            const text = r.choices[0]?.message?.content?.trim() ?? '';
            const promptDetails = (
              r.usage as { prompt_tokens_details?: { cached_tokens?: number } } | undefined
            )?.prompt_tokens_details;
            const providerUsage = usageFromCompletion(r.usage, r);
            return {
              text,
              usage: {
                input: r.usage?.prompt_tokens ?? 0,
                output: r.usage?.completion_tokens ?? 0,
                total: r.usage?.total_tokens ?? 0,
                cached: promptDetails?.cached_tokens ?? 0,
                ...providerUsage,
              },
            };
          }
        : undefined,
      onTurn: async ({ turn, progress, newMessages }) => {
        turnTrace.push(summarizeTurn(turn, newMessages));
        await supa
          .from('envelope_runs')
          .update({
            progress: progress as unknown as Json,
            turns: turnTrace as unknown as Json,
            updated_at: new Date().toISOString(),
          })
          .eq('id', envelopeRunId);
      },
      // Heartbeat between awaits within a turn — keeps the iOS detail
      // page ticking so a slow model + slow scrape doesn't look frozen.
      // Each heartbeat is a tiny progress-only UPDATE (no turns rewrite)
      // so we can fire ~3 of these per turn without much overhead.
      onActivity: async (snapshot) => {
        await supa
          .from('envelope_runs')
          .update({
            progress: snapshot as unknown as Json,
            updated_at: new Date().toISOString(),
          })
          .eq('id', envelopeRunId);
      },
      isCancelled: () => isRunCancelled(supa, envelopeRunId),
    });

    if (result.reason === 'cancelled') {
      await supa
        .from('envelope_runs')
        .update({ status: 'cancelled', finished_at: new Date().toISOString() })
        .eq('id', envelopeRunId);
      await auditRun(env, route, {
        auditId: turnId,
        userId,
        conversationId,
        envelopeRunId,
        botId,
        usage: result.usage,
        generationId: result.lastGenerationId,
        startedAt,
        action: 'cancelled',
        webTools: webMeter.snapshot(),
      });
      return;
    }

    if (result.collaboratorUsage) {
      result.usage.input += result.collaboratorUsage.input;
      result.usage.output += result.collaboratorUsage.output;
      result.usage.total += result.collaboratorUsage.total;
      result.usage.cached += result.collaboratorUsage.cached;
      mergeProviderUsageDetails(result.usage, result.collaboratorUsage);
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

      const request = {
        model: mainRoute.modelToCall,
        messages: [
          { role: 'system', content: getPrompt('envelope-write') },
          { role: 'user', content: writeUser },
        ],
      } as ChatCompletionCreateParamsNonStreaming;
      const writeResp = await mainRoute.client.chat.completions.create(request);
      writeArticle = (writeResp.choices[0]?.message?.content ?? '').trim();
      const writePromptDetails = (
        writeResp.usage as { prompt_tokens_details?: { cached_tokens?: number } } | undefined
      )?.prompt_tokens_details;
      const writeProviderUsage = usageFromCompletion(writeResp.usage, writeResp);
      writeUsage = {
        input: writeResp.usage?.prompt_tokens ?? 0,
        output: writeResp.usage?.completion_tokens ?? 0,
        total: writeResp.usage?.total_tokens ?? 0,
        cached: writePromptDetails?.cached_tokens ?? 0,
        ...writeProviderUsage,
      };
      writeGenerationId = writeResp.id;
      result.usage.input += writeUsage.input;
      result.usage.output += writeUsage.output;
      result.usage.total += writeUsage.total;
      result.usage.cached += writeUsage.cached;
      mergeProviderUsageDetails(result.usage, writeUsage);
    }

    const finalProgress: ProgressState = { ...result.progress, phase: 'done' };
    const stripped = writeArticle.trim();
    const isEmpty = !stripped || stripped === SILENT_TOKEN || stripped.length < 20;
    if (isEmpty) {
      await supa.from('envelope_runs').delete().eq('id', envelopeRunId);
      await auditRun(env, route, {
        auditId: turnId,
        userId,
        conversationId,
        envelopeRunId,
        botId,
        usage: result.usage,
        generationId: writeGenerationId ?? result.lastGenerationId,
        startedAt,
        action: 'silent',
        webTools: webMeter.snapshot(),
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
      .from('envelope_runs')
      .update({
        status: 'done',
        body_md: cleanedBody,
        title,
        summary,
        progress: finalProgress as unknown as Json,
        finished_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq('id', envelopeRunId);

    await auditRun(env, route, {
      auditId: turnId,
      userId,
      conversationId,
      envelopeRunId,
      botId,
      usage: result.usage,
      generationId: result.lastGenerationId,
      startedAt,
      action: 'memorial',
      webTools: webMeter.snapshot(),
    });
  } catch (err) {
    console.error('[envelope-runner]', err);
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
      .from('envelope_runs')
      .update({
        status: 'error',
        finished_at: new Date().toISOString(),
        progress: errProgress as unknown as Json,
        updated_at: new Date().toISOString(),
      })
      .eq('id', envelopeRunId);

    // Bill any web tool calls that landed before the failure (upstream
    // providers already consumed those quotas) plus any LLM tokens the
    // loop accumulated. Mirrors bot-reply's error-path audit. If neither
    // tool calls nor LLM tokens accrued, recordAudit settles into
    // 'skipped'/'free' and no debit fires.
    try {
      await auditRun(env, route, {
        auditId: turnId,
        userId,
        conversationId,
        envelopeRunId,
        botId,
        usage: result?.usage ?? { input: 0, output: 0, total: 0, cached: 0 },
        generationId: result?.lastGenerationId,
        startedAt,
        action: 'error',
        status: 'error',
        errorClass: err instanceof Error ? err.name : 'unknown',
        webTools: webMeter.snapshot(),
      });
    } catch (auditErr) {
      console.warn('[envelope-runner] audit on error failed:', auditErr);
    }
  }
}

// Render the explorer's most recent turn as a short transcript the
// collaborator model can chew on.
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
  envelopeRunId: string,
): Promise<boolean> {
  const { data } = await supa
    .from('envelope_runs')
    .select('status')
    .eq('id', envelopeRunId)
    .maybeSingle();
  return data?.status === 'cancelled';
}

interface AuditInput {
  auditId?: string;
  userId: string;
  conversationId: string;
  envelopeRunId: string;
  botId: string;
  usage: UsageStats;
  generationId?: string;
  startedAt: number;
  action: 'memorial' | 'silent' | 'cancelled' | 'error';
  status?: 'success' | 'error';
  errorClass?: string | null;
  webTools?: WebToolUsage[];
}

async function auditRun(
  env: Env,
  route: ResolvedRoute | null,
  i: AuditInput,
): Promise<void> {
  const cacheRead = i.usage.cached;
  const freshInput = Math.max(0, i.usage.input - cacheRead);
  await enqueueAudit(env, route, {
    auditId: i.auditId,
    userId: i.userId,
    conversationId: i.conversationId,
    taskType: 'envelope',
    startedAt: i.startedAt,
    generationId: i.generationId,
    status: i.status ?? 'success',
    errorClass: i.errorClass ?? null,
    inputTokens: freshInput,
    outputTokens: i.usage.output,
    cacheReadTokens: cacheRead,
    cacheWriteTokens: 0,
    providerCostUsd: i.usage.providerCostUsd,
    webTools: i.webTools,
    metadata: { envelope_run_id: i.envelopeRunId, bot_id: i.botId, action: i.action },
  });
}
