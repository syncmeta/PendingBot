import { randomUUID } from 'node:crypto';
import type {
  ChatCompletionContentPart,
  ChatCompletionCreateParamsStreaming,
  ChatCompletionMessageParam,
  ChatCompletionMessageToolCall,
  ChatCompletionTool,
} from 'openai/resources/chat/completions';
import type { Env } from '../../types';
import type { Json } from '../../db/schema';
import { serviceClient } from '../supabase';
import {
  auditErrorFields,
  enqueueAudit,
  FallbackError,
  type ResolvedRoute,
  type RouteTraceEntry,
  usageFromCompletion,
  withFallback,
} from '../../llm/router';
import { mergeProviderUsageDetails } from '../../llm/provider-usage';
import {
  chatMessagesToResponsesInput,
  chatToolsToResponsesTools,
  openResponsesStream,
  OPENAI_BUILTIN_TOOLS,
  type LlmStreamChunk,
} from '../../llm/responses-adapter';
import { openAnthropicStream } from '../../llm/anthropic-adapter';
import { openGeminiStream } from '../../llm/gemini-adapter';
import { buildMessages, type BuildMessagesInput } from '../../llm/builder';
import { resolveLocale } from '../../i18n/locale';
import { loadPrompt, getPromptMeta } from '../../i18n/prompts';
import {
  loadAttachmentAsFilePart,
  loadAttachmentAsImagePart,
  summarizeAttachments,
} from '../../llm/vision';
import { modelSupportsVision } from '../../llm/catalog';
import {
  getBotMemory,
  getUserMemory,
  getBotViewOfUser,
  getUserViewOfBot,
} from '../memory';
import { resolveInventory } from '../attachment-cache';
import { classifyAttachment } from '../attachments';
import { persistAttachmentBytes } from '../attachments-persist';
import {
  resolveBotNote,
  resolveChatMemo,
  resolveSubscriptions,
} from '../persona-cache';
import { resolveProviderSlug } from '../../llm/providers';
import { WebToolMeter } from '../web-meter';
import {
  ASK_FRIEND_TOOL,
  buildOpenRouterServerTools,
  CHAT_TOOLS,
  DELEGATE_TO_SPECIALIST_TOOL,
  EXECUTE_CODE_TOOL,
  GROUP_BOT_TOOLS,
  REQUEST_EXECUTE_CODE_TOOL,
  SUBMIT_INQUIRY_ANSWER_TOOL,
  type WebSearchConfig,
} from './tool-defs';
import { loadBotSocialSnapshot, loadInquiryContext } from '../bot-social';
import {
  type Citation,
  type ToolCtx,
  runTool,
  safeParseArgs,
} from './tool-runner';
import { dispatchMcpTool } from './mcp-dispatch';
import { mcpClient } from '../../mcp/client';
import { loadToolRegistry, applyToolRegistry } from '../tools-registry';
import { uuidv7 } from '../ids';

// Public re-exports — callers do
//   import { runChatTurn, type RunChatTurnInput } from '../lib/bot-reply';
// which resolves through this barrel.
export { type Citation } from './tool-runner';

// Multi-bubble splitter — bot's reply may be one continuous block, or several
// short bubbles separated by `\n---\n`.
const BUBBLE_DELIMITER = '\n---\n';
export const BUBBLE_OVERFLOW_CHARS = 60;

// Bot's "I have nothing to say" control token (system.md). Dropped if the
// final reply trims to exactly this — no DB row, no bubble event.
const SILENT_TOKEN = '[SILENT]';

// Marker the bot can emit anywhere in its reply (typically the end) to
// flag the active lookback notes as no longer relevant. Stripped from the
// user-visible content; route handler then UPDATEs bot_lookbacks.active=false
// for whichever ids the runner reports.
const DROP_LOOKBACK_TOKEN = '[DROP_LOOKBACK]';

function couldStillBeSilent(s: string): boolean {
  if (s.length === 0) return true;
  if (s.length > SILENT_TOKEN.length) return false;
  return SILENT_TOKEN.startsWith(s);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function stringField(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value : null;
}

function firstCodeLine(code: string): string | null {
  return code
    .split('\n')
    .map((line) => line.trim())
    .find((line) => line.length > 0)
    ?.slice(0, 120) ?? null;
}

function toolInputPreview(name: string, payload: Record<string, unknown>): string | null {
  const query = stringField(payload.query);
  if (query) return query;
  const url = stringField(payload.url);
  if (url) return url;
  const skillName = stringField(payload.skill_name);
  if (skillName) return skillName;
  const codePreview = stringField(payload.code_preview);
  if (codePreview) return codePreview;
  const code = stringField(payload.code);
  if (code) return firstCodeLine(code) ?? `${code.length} chars`;
  const reason = name === 'request_execute_code' ? stringField(payload.reason) : null;
  if (reason) return reason;
  if (typeof payload.chars === 'number') return `${payload.chars} chars`;
  return null;
}

function toolResultSummary(payload: Record<string, unknown>): string | null {
  if (typeof payload.count === 'number') return `${payload.count} 条结果`;
  const title = stringField(payload.title);
  if (title) return title;
  const skillName = stringField(payload.skill_name);
  if (skillName) return skillName;
  const decision = stringField(payload.decision);
  if (decision) {
    if (decision === 'approved') return '已批准';
    if (decision === 'denied') return '已拒绝';
    if (decision === 'timeout') return '已超时';
    return decision;
  }
  if (typeof payload.exit_code === 'number') {
    const tail = stringField(payload.stdout_tail);
    return tail ? `exit ${payload.exit_code} · ${tail}` : `exit ${payload.exit_code}`;
  }
  if (typeof payload.chars === 'number') {
    return payload.chars > 0 ? `${payload.chars} 字回答` : '暂无相关记忆';
  }
  return null;
}

async function persistToolTraceMetadata(
  supa: ReturnType<typeof serviceClient>,
  parentMessageId: string,
  toolTrace: PersistedToolTraceEvent[],
  citations: Citation[],
): Promise<void> {
  if (toolTrace.length === 0 && citations.length === 0) return;

  const { data, error: readError } = await supa
    .from('messages')
    .select('metadata')
    .eq('id', parentMessageId)
    .maybeSingle();
  if (readError) return;

  const existing = isRecord(data?.metadata) ? data.metadata : {};
  const next: Record<string, Json> = {
    ...(existing as Record<string, Json>),
    tool_trace: toolTrace.map((ev) => ({ ...ev })),
  };
  if (citations.length > 0) {
    next.tool_citations = citations.map((c) => ({ ...c }));
  }

  await supa
    .from('messages')
    .update({ metadata: next })
    .eq('id', parentMessageId);
}

// Decode a base64 PNG payload from the OpenAI image_generation built-in
// tool into raw bytes. Image-gen always returns PNG, so this is the only
// MIME we need to handle on the encoded-input side; the persistence
// itself goes through the generic persistAttachmentBytes helper now.
//
// The 23505-partial-index race fallback was the historical footgun
// here — see persistAttachmentBytes for the long-form comment. (Lost
// roughly 165s once on 2026-05-20 when an upsert silently dropped a
// generated PNG; the rewrite below makes that path explicit.)
function decodeBase64Png(base64: string): Uint8Array {
  const bin = atob(base64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

// Maximum agent-loop iterations (one LLM call + tool execution per iteration).
// Bounds runaway tool spam if the model keeps calling tools indefinitely.
const MAX_TOOL_ROUNDS = 6;

type PersistedToolTraceEvent = {
  name: string;
  input: string | null;
  result_summary: string | null;
  result_error: string | null;
  result_detail: string | null;
  done: boolean;
};

export interface RunChatTurnInput {
  env: Env;
  conversationId: string;
  userId: string;
  parentMessageId: string;     // user's just-inserted message id
  bot: {
    id: string;
    display_name: string;
    model_id: string;
    output_mode: 'single' | 'bubble';
    /// IANA timezone the bot considers itself in (bots.tz). NULL for
    /// private bots (they follow the listener's clientTz). For public
    /// bots: appears in the system prompt as self-awareness, and is the
    /// fallback time-hint tz when clientTz is absent (group dispatch).
    tz?: string | null;
  };
  recentContext: BuildMessagesInput['recentContext'];
  newMessage: string;
  /// Attachment ids on the current user turn (the message that triggered
  /// this reply). When the bot's main model has vision, these load as
  /// image_url content parts on the user turn so the model reads them
  /// directly. When it doesn't, runChatTurn ensures their summaries land
  /// before the LLM call so the inventory section carries the description.
  /// Caller in routes/messages.ts forwards parsed.attachmentIds.
  currentAttachmentIds?: string[];
  /// The bot's pinned vision model (bots.config.visionModel). NULL = auto.
  /// Threaded through to summarize + read_attachment so the pin kicks in.
  visionModelOverride?: string | null;
  /// The bot's provider pin (bots.model_provider, e.g. 'openai'). When
  /// set, passed to LLMRouter as preferProvider; the existing fallback
  /// chain still kicks in if the chosen provider 5xxs. NULL = follow the
  /// default routing.
  providerOverride?: string | null;
  /// Lookback notes the client cached. Each is fed into the prompt as a
  /// private context block; the bot decides per turn whether to keep them.
  activeLookbacks?: Array<{ id: string; body_md: string }>;
  /// True when conv.conversation_type === 'self'. The standard "self
  /// section" of the system prompt is filled from the user's Honcho
  /// representation (user-${userId}) instead of the bot's own — so the
  /// per-user self-bot's self-model is the user's accumulated peer model.
  isSelfChat?: boolean;
  /// Client's IANA timezone (e.g. "Asia/Shanghai"). Used to format the
  /// "this message was sent at ..." hint we attach to each turn.
  clientTz?: string;
  signal: AbortSignal;
  emit: (event: string, data: unknown) => void;
  /// Set true by dispatchGroupTurn so the bot gets the
  /// set_my_group_nickname / set_bot_group_description tools in this
  /// turn's tool list. Default false keeps 1v1 / self / user_user
  /// surfaces clean.
  inGroup?: boolean;
  /// Per-bot OpenRouter web-search config (bots.config.webSearch), parsed
  /// by the caller. Only consumed on the OpenRouter routing path — it
  /// tunes the `openrouter:web_search` server tool (engine, result caps,
  /// domain filters). Absent = default search (engine=auto, no limits).
  webSearch?: WebSearchConfig | null;
}

export interface RunChatTurnResult {
  finalStatus: 'done' | 'interrupted' | 'error';
  totalContent: string;
  bubblesInserted: number;
  /// IDs of lookback notes the bot decided to retire this turn (because
  /// it emitted [DROP_LOOKBACK]). Caller flips active=false for them.
  droppedLookbackIds: string[];
}

export async function runChatTurn(input: RunChatTurnInput): Promise<RunChatTurnResult> {
  const {
    env, conversationId, userId, parentMessageId,
    bot, recentContext, newMessage, signal, emit,
  } = input;
  const activeLookbacks = input.activeLookbacks ?? [];
  const supa = serviceClient(env);
  const startedAt = Date.now();
  const turnId = uuidv7();

  // Kick off the tools-registry allowlist lookup immediately — it
  // doesn't depend on the prompt, so it overlaps with locale + memory
  // resolution + prompt assembly instead of sitting serially in front
  // of the LLM call.
  const allowedRegistryPromise = loadToolRegistry(env, 'chat');

  const locale = await resolveLocale(null, supa, userId, env);

  // 1. Look up self section + skills + bot-authored note + chat memo in
  // parallel. All four are KV-first (botMemory + subscriptions + note +
  // memo) with read-through fallback to Supabase on miss, so the
  // happy-path batch is pure KV — zero Supabase RTT before LLM dispatch.
  // The fall-through KV writes are detached via a no-op shim since
  // we're already inside turnWork (kept alive by the SSE stream's own
  // waitUntil binding).
  const noop = (p: Promise<unknown>) => { p.catch(() => undefined); };
  // Same provider hint we'll later hand to the LLM router. Used to
  // scope which user skills are visible this turn — skills the user
  // tagged for the other provider stay hidden.
  const turnProviderSlug = resolveProviderSlug(input.providerOverride);
  // Theory-of-mind sections (② bot→user, ④ user→bot) are pair-scoped and
  // only make sense for a regular 1v1: a group has no single "you", and in a
  // self-chat the bot ≡ the user. Skip the KV reads otherwise.
  const relational = !input.isSelfChat && !(input.inGroup ?? false);
  const [
    botMemory, subsBundle, botNote, chatMemo, botViewOfUser, userViewOfBot,
    socialSnapshot,
  ] = await Promise.all([
    input.isSelfChat ? getUserMemory(env, userId) : getBotMemory(env, bot.id),
    resolveSubscriptions(env, supa, userId, conversationId, turnProviderSlug, noop),
    resolveBotNote(env, supa, bot.id, userId, noop),
    resolveChatMemo(env, supa, bot.id, conversationId, noop),
    relational ? getBotViewOfUser(env, bot.id, userId) : Promise.resolve(null),
    relational ? getUserViewOfBot(env, userId, bot.id) : Promise.resolve(null),
    // Bot social-graph snapshot — feeds the per-turn "我的社交圈" volatile
    // section. Self-chat skips it: bot ≡ user and the social graph isn't
    // a frame the bot should reason about. Best-effort: any DB hiccup
    // degrades to "no social section" rather than failing the turn.
    input.isSelfChat
      ? Promise.resolve(null)
      : loadBotSocialSnapshot(supa, bot.id).catch(() => null),
  ]);

  // Inquiry context — pending answers from ask_friend that resolved
  // while THIS conv was active (need to weave into next reply) +
  // open inquiries this bot has sitting on THIS conv as the relay
  // (need to expose inquiry_id so submit_inquiry_answer is callable
  // across turns). Self-chat doesn't have inquiries.
  const inquiryContext = input.isSelfChat
    ? { pendingAnswers: [], openRelayInquiries: [] }
    : await loadInquiryContext(supa, bot.id, conversationId).catch(() => ({
        pendingAnswers: [],
        openRelayInquiries: [],
      }));
  const skills = subsBundle.skills.map((s) => ({
    name: s.name,
    description: s.description,
    body: s.body,
  }));
  const allowedTools = new Set<string>(subsBundle.allowedTools);

  // 1.5 Vision/attachment resolution.
  //
  // - mainHasVision: vision support from the live catalog for this conv's
  //   main model. Drives whether we send images inline on the current
  //   turn or rely on text summaries.
  // - attachmentInventory: every image visible in this conv's recent
  //   history, rendered as a "## 历史图片附件" system block by the builder.
  //   The model can call read_attachment with the listed IDs to look at
  //   any image again.
  // - currentImageParts: actual image_url blocks for the current turn's
  //   images, only populated when main has vision.
  // - When main lacks vision and the current turn has unsummarized images,
  //   we sync-trigger summarizeAttachments so the inventory has at least
  //   the summary by the time we hit the LLM. summarizeAttachments is
  //   idempotent — the async hook in routes/messages.ts may already be
  //   running; this just guarantees we don't ship without summaries.
  const visionOverride = input.visionModelOverride ?? null;
  const mainHasVision = await modelSupportsVision(bot.model_id);
  const currentSet = new Set(input.currentAttachmentIds ?? []);

  // History inventory pull. KV-first via per-conv id list + per-id
  // metadata; falls back to Supabase on miss (cold conv) and warms KV.
  // Cap at 30 mirrors the Supabase query's `limit(30)`. The fall-through
  // KV writes are detached — no waitUntil binding here since we're
  // inside a long-lived turnWork promise that's already kept alive by
  // the SSE stream's own waitUntil. Use the no-op waitUntil shim.
  const inventoryRows = await resolveInventory(
    env,
    supa,
    conversationId,
    (p) => { p.catch(() => undefined); },
  );
  const inventory = inventoryRows.map((r) => ({
    id: r.id,
    summary: r.summary,
    tags: r.tags,
    status: r.status,
    isCurrentTurn: currentSet.has(r.id),
    mime: r.mime,
    filename: r.filename,
  }));

  // Current-turn attachment content parts. Images go in as image_url
  // parts (only when the main model has vision); PDFs go in as file
  // parts (the provider parses them natively, regardless of vision);
  // all other file types are not sent inline — the model reaches them
  // through the file inventory + read_attachment tool.
  let currentImageParts: ChatCompletionContentPart[] | undefined;
  let currentFileParts: ChatCompletionContentPart[] | undefined;
  if (input.currentAttachmentIds && input.currentAttachmentIds.length > 0) {
    const { data: rows } = await supa
      .from('attachments')
      .select('id, r2_key, mime_type, byte_size, filename')
      .in('id', input.currentAttachmentIds);
    const imageParts: ChatCompletionContentPart[] = [];
    const fileParts: ChatCompletionContentPart[] = [];
    for (const r of (rows ?? []) as Array<{
      r2_key: string;
      mime_type: string;
      byte_size: number;
      filename: string | null;
    }>) {
      const kind = classifyAttachment(r.mime_type);
      if (kind === 'pdf') {
        const p = await loadAttachmentAsFilePart(env, r);
        if (p) fileParts.push(p);
      } else if (kind === 'image' && mainHasVision) {
        const p = await loadAttachmentAsImagePart(env, r);
        if (p) imageParts.push(p);
      }
    }
    if (imageParts.length > 0) currentImageParts = imageParts;
    if (fileParts.length > 0) currentFileParts = fileParts;
  }
  if (
    !mainHasVision &&
    input.currentAttachmentIds &&
    input.currentAttachmentIds.length > 0
  ) {
    // Block on summarization for any current-turn images that don't yet
    // have summaries. The async hook fired by routes/messages.ts may be
    // mid-flight; summarizeAttachment is idempotent and short-circuits
    // on summary_status='done', so a second concurrent call costs at
    // most one duplicated LLM round-trip. Worth it for the determinism.
    const pending = inventory
      .filter(
        (a) =>
          a.isCurrentTurn && a.status !== 'done' && a.status !== 'skipped',
      )
      .map((a) => a.id);
    if (pending.length > 0) {
      await summarizeAttachments(
        {
          supa,
          env,
          conversationId,
          userId,
          mainModelSlug: bot.model_id,
          visionOverride,
        },
        pending,
      );
      // Re-pull the rows we just summarized so the inventory reflects
      // the new state (rather than re-querying the whole list).
      const { data: refreshed } = await supa
        .from('attachments')
        .select('id, summary, tags, summary_status')
        .in('id', pending);
      const updates = new Map<
        string,
        { summary: string | null; tags: string[]; status: string }
      >();
      for (const r of (refreshed as Array<{
        id: string;
        summary: string | null;
        tags: string[] | null;
        summary_status: string;
      }> | null) ?? []) {
        updates.set(r.id, {
          summary: r.summary,
          tags: r.tags ?? [],
          status: r.summary_status,
        });
      }
      for (const item of inventory) {
        const u = updates.get(item.id);
        if (u) {
          item.summary = u.summary;
          item.tags = u.tags;
          item.status = u.status;
        }
      }
    }
  }

  // 2. Build prompt. The builder marks the cache breakpoint per plan/02
  // (every 4 rounds; see llm/builder.ts). activeLookbacks become an
  // additional system block so the bot sees its prior fact-check notes.
  const messages: ChatCompletionMessageParam[] = await buildMessages(
    env,
    {
      bot, botMemory, botViewOfUser, userViewOfBot, skills, botNote, chatMemo,
      lookbacks: activeLookbacks,
      recentContext, newMessage,
      currentImageParts,
      currentFileParts,
      attachmentInventory: inventory,
      socialGraph: socialSnapshot ?? undefined,
      pendingInquiryAnswers: inquiryContext.pendingAnswers.length > 0
        ? inquiryContext.pendingAnswers
        : undefined,
      openRelayInquiries: inquiryContext.openRelayInquiries.length > 0
        ? inquiryContext.openRelayInquiries
        : undefined,
      clientTz: input.clientTz,
    },
    locale,
  );

  // AbortSignal propagation: caller's signal aborts the upstream openai fetch.
  const ac = new AbortController();
  const onCallerAbort = () => ac.abort();
  signal.addEventListener('abort', onCallerAbort, { once: true });

  // Bubble grouping: every visible message in this turn shares one bubble_group_id.
  const bubbleGroupId = randomUUID();
  let bubbleIndex = 0;
  let pending = '';
  let totalContent = '';
  let emittedLen = 0;
  let bubblesInserted = 0;
  const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  const providerUsage = {};
  let generationId: string | undefined;

  // Per-turn web-search citations. Every search_web call appends new urls
  // (deduped by url, so `[N]` stays stable across rounds in the same turn).
  // Each emitted bubble row stores the snapshot at insert time — later bubbles
  // may carry a longer list, but earlier ones never reference an [N] beyond
  // their snapshot's bounds.
  const citations: Citation[] = [];

  // Per-turn web-tool meter. Every MCP tool call below records into
  // this; the snapshot is passed to enqueueAudit as `webTools` so the
  // tool spend folds into audit_log.tool_cost_usd + cost_credits and
  // each call lands in audit_web_tool_calls.
  const webMeter = await WebToolMeter.create(supa);

  const toolTrace: PersistedToolTraceEvent[] = [];
  let toolTracePersist = Promise.resolve();
  const queueToolTracePersist = () => {
    const traceSnapshot = toolTrace.map((ev) => ({ ...ev }));
    const citationSnapshot = citations.map((c) => ({ ...c }));
    toolTracePersist = toolTracePersist
      .catch(() => undefined)
      .then(() => persistToolTraceMetadata(
        supa,
        parentMessageId,
        traceSnapshot,
        citationSnapshot,
      ))
      .catch(() => undefined);
  };
  const emitToolEvent = (event: string, data: unknown) => {
    if (isRecord(data)) {
      if (event === 'tool_call') {
        const name = String(data.name ?? '');
        if (name) {
          toolTrace.push({
            name,
            input: toolInputPreview(name, data),
            result_summary: null,
            result_error: null,
            result_detail: null,
            done: false,
          });
          queueToolTracePersist();
        }
      } else if (event === 'tool_result') {
        const name = String(data.name ?? '');
        let idx = -1;
        for (let i = toolTrace.length - 1; i >= 0; i--) {
          if (toolTrace[i].name === name && !toolTrace[i].done) {
            idx = i;
            break;
          }
        }
        const ev: PersistedToolTraceEvent = idx >= 0
          ? toolTrace[idx]
          : {
              name,
              input: null,
              result_summary: null,
              result_error: null,
              result_detail: null,
              done: false,
            };
        ev.result_summary = toolResultSummary(data);
        ev.result_error = stringField(data.error);
        ev.result_detail = stringField(data.detail) ?? stringField(data.stderr);
        ev.done = true;
        if (idx >= 0) {
          toolTrace[idx] = ev;
        } else {
          toolTrace.push(ev);
        }
        queueToolTracePersist();
      } else if (event === 'citations') {
        queueToolTracePersist();
      }
    }
    emit(event, data);
  };

  const emitBubble = async (text: string) => {
    if (!text) return;
    bubbleIndex++;
    const bubbleId = randomUUID();
    const clientMessageId = randomUUID();
    const snapshot = citations.length > 0 ? citations.map((c) => ({ ...c })) : null;
    const { data: inserted, error } = await supa.from('messages').insert({
      id: bubbleId,
      client_message_id: clientMessageId,
      conversation_id: conversationId,
      sender_bot_id: bot.id,
      role: 'bot',
      status: 'done',
      content: text,
      parent_message_id: parentMessageId,
      bubble_group_id: bubbleGroupId,
      citations: snapshot,
      model_slug: bot.model_id,
      model_provider: turnProviderSlug,
    }).select('message_seq').single();
    if (error) {
      console.warn('[bot-reply] bubble insert', error.message);
      return;
    }
    bubblesInserted++;
    emit('bubble', {
      id: bubbleId,
      index: bubbleIndex,
      bubble_group_id: bubbleGroupId,
      message_seq: inserted?.message_seq ?? null,
      content: text,
      citations: snapshot,
    });
  };

  // Insert one bot message carrying N attachment ids. Used by both
  // image_generation (single PNG via emitGeneratedImage below) and the
  // send_images tool (1–5 mixed-MIME). Shape: same bubble_group_id as
  // this turn's text bubbles, empty content, attachments jsonb
  // { ids: […] }.
  //
  // Deliberately does NOT emit an SSE `bubble` event or touch
  // `bubbleIndex`: that counter is kept in lockstep with the splitter's
  // streamed text bubbles so the client can rekey them, and an image
  // bubble has no streamed counterpart. The inserted row reaches the
  // client through the Cloudflare realtime hub (messages-table AFTER
  // INSERT trigger → notify_realtime() → /v1/realtime-internal/notify →
  // RealtimeHubDO WebSocket fan-out).
  const emitImagesMessage = async (attachmentIds: string[]): Promise<boolean> => {
    if (attachmentIds.length === 0) return false;
    const { error } = await supa.from('messages').insert({
      id: randomUUID(),
      client_message_id: randomUUID(),
      conversation_id: conversationId,
      sender_bot_id: bot.id,
      role: 'bot',
      status: 'done',
      content: '',
      parent_message_id: parentMessageId,
      bubble_group_id: bubbleGroupId,
      attachments: { ids: attachmentIds },
      model_slug: bot.model_id,
      model_provider: turnProviderSlug,
    });
    if (error) {
      console.warn('[bot-reply] images-message insert', error.message);
      return false;
    }
    bubblesInserted++;
    return true;
  };

  // Insert a `log_kind='guess_prompt'` row — the blind-box "猜一猜"
  // interactive card. Mirrors the crew_proposal log insert in
  // tools/start-crew.ts: log rows carry sender_bot_id + log_payload +
  // a short human-readable `content` fallback, and (unlike bot bubbles)
  // do NOT set parent_message_id / bubble_group_id. The client filters
  // role='log' out of normal bubbles and dispatches by log_kind.
  const emitGuessPrompt = async (): Promise<boolean> => {
    const messageId = randomUUID();
    const { error } = await supa.from('messages').insert({
      id: messageId,
      client_message_id: messageId,
      conversation_id: conversationId,
      sender_bot_id: bot.id,
      role: 'log',
      log_kind: 'guess_prompt',
      log_payload: {},
      content: '猜一猜我是哪个模型？',
      status: 'done',
    });
    if (error) {
      console.warn('[bot-reply] guess-prompt insert', error.message);
      return false;
    }
    return true;
  };

  // Persist an image the OpenAI image_generation built-in tool
  // produced into an attachments row + bot message. The caller is
  // responsible for resolving the corresponding `tool_result` SSE so
  // the UI chip doesn't sit at "image_generation 中" forever.
  //
  // Returns: ok with the new attachment id, or failed with a reason
  // string so the dispatch site can surface an error chip in the
  // trace UI instead of silently swallowing the result.
  // ("not-persisted" = R2 PUT or attachments INSERT failed and was
  // logged. "insert-failed" = the messages row insert failed.)
  type EmitImageResult =
    | { ok: true; attachmentId: string }
    | { ok: false; reason: string };
  const emitGeneratedImage = async (
    base64: string,
  ): Promise<EmitImageResult> => {
    const attachmentId = await persistAttachmentBytes(
      env, supa, userId, conversationId, decodeBase64Png(base64), 'image/png',
    );
    if (!attachmentId) return { ok: false, reason: 'not-persisted' };
    const ok = await emitImagesMessage([attachmentId]);
    return ok ? { ok: true, attachmentId } : { ok: false, reason: 'insert-failed' };
  };

  const toolCtx: ToolCtx = {
    signal: ac.signal,
    emit: emitToolEvent,
    userId,
    botId: bot.id,
    parentMessageId,
    botModelId: bot.model_id,
    visionOverride,
    conversationId,
    citations,
    webMeter,
    inGroup: input.inGroup ?? false,
    emitImagesMessage,
    emitGuessPrompt,
  };

  // Each round inside the agent loop runs its own withFallback — when
  // one provider fails before-first-chunk, the router can re-resolve
  // and try the next-best alias for the same canonical model. Once a
  // stream has started yielding chunks (i.e. bytes have flown to the
  // iOS client), fallback is no longer safe; iteration errors below
  // surface as 'interrupted'/'error' status instead.
  let route: ResolvedRoute | null = null;
  const routeTrace: RouteTraceEntry[] = [];
  emit('typing', { state: 'thinking' });

  // Compose this turn's tool list. Always-on tools come from CHAT_TOOLS,
  // plus request_execute_code (user-approval-gated, safe by construction).
  // Skill-gated tools (currently: unsupervised execute_code) only appear
  // when at least one subscribed skill opts the user in via its
  // frontmatter.allowed_tools. Web search / web fetch / datetime come
  // from the provider's own server-side tools — OpenRouter native
  // plugins on the Chat Completions path, OpenAI built-ins on the
  // Responses path — added to the request below per provider.
  // delegate_to_specialist: always-on now that it dispatches to an
  // arbitrary model slug (not another bot), so visibility/contact gating
  // is moot. The tools registry can still hide it from the model via
  // applyToolRegistry below if an operator disables it on the board.
  const turnToolsRaw: ChatCompletionTool[] = [
    ...CHAT_TOOLS,
    REQUEST_EXECUTE_CODE_TOOL,
    DELEGATE_TO_SPECIALIST_TOOL,
  ];
  if (allowedTools.has('execute_code')) turnToolsRaw.push(EXECUTE_CODE_TOOL);
  if (input.inGroup) {
    turnToolsRaw.push(...GROUP_BOT_TOOLS);
  }
  // ask_friend / submit_inquiry_answer are public-bot-only. The
  // visibility check piggybacks on socialSnapshot.isPublic — already
  // fetched alongside the social graph data above. Private bots get
  // neither (their only friend is the owner = the person they're
  // already talking to). The submit tool is only useful inside a relay
  // conversation, but we expose it on every public-bot turn rather than
  // try to detect "we're in someone's relay" — the tool's own
  // ownership check will reject misuse.
  if (socialSnapshot?.isPublic) {
    turnToolsRaw.push(ASK_FRIEND_TOOL, SUBMIT_INQUIRY_ANSWER_TOOL);
  }

  // Strict allowlist from the tools registry — disabling a row in the
  // board "Tools" page strips it here within ~1 min (60s isolate
  // cache). The registry also swaps in any board-edited
  // model_description override. `null` means the registry was
  // unreachable; pass through unfiltered rather than serving the model
  // an empty tool list.
  const toolRegistry = await allowedRegistryPromise;
  const turnTools: ChatCompletionTool[] = applyToolRegistry(
    turnToolsRaw,
    toolRegistry,
  );

  // OpenAI-native bots reach web search and code execution through
  // OpenAI's server-side built-in tools (added in the runner closure
  // below), not the Cloudflare sandbox — so their function-tool list
  // is the internal surface only: no request_execute_code / execute_code.
  const nativeFnToolsRaw: ChatCompletionTool[] = [
    ...CHAT_TOOLS,
    DELEGATE_TO_SPECIALIST_TOOL,
  ];
  if (input.inGroup) {
    nativeFnToolsRaw.push(...GROUP_BOT_TOOLS);
  }
  if (socialSnapshot?.isPublic) {
    nativeFnToolsRaw.push(ASK_FRIEND_TOOL, SUBMIT_INQUIRY_ANSWER_TOOL);
  }
  const nativeFnTools: ChatCompletionTool[] = applyToolRegistry(
    nativeFnToolsRaw,
    toolRegistry,
  );

  // Per-bot web-search master switch, shared across every provider path
  // (OpenAI built-in, Anthropic server tool, Gemini grounding, OpenRouter
  // plugin). Absent / true = on, matching OpenRouter's historical default;
  // only an explicit `enabled: false` in bots.config.webSearch turns it off.
  const webSearchOn = input.webSearch?.enabled !== false;

  try {
    // Outer agent loop. Each iteration is one LLM call. If the model emits
    // tool_calls, we execute them and re-iterate; otherwise we exit.
    for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
      if (ac.signal.aborted) break;

      const roundOpen = await withFallback(
        supa,
        env,
        {
          modelSlug: bot.model_id,
          taskType: 'message_reply',
          preferProvider: input.providerOverride ?? undefined,
          metadata: { userId, conversationId, turnId },
        },
        async (r): Promise<{ stream: AsyncIterable<LlmStreamChunk> }> => {
          // Native-protocol providers (Anthropic Messages / Gemini
          // generateContent) go through their own adapters using raw fetch
          // against the AI Gateway native passthrough (route.baseURL +
          // route.aigToken, Unified Billing). Each adapter re-emits its
          // response as Chat-Completions-shaped chunks so the merge loop
          // below is identical. nativeFnTools is the function-tool surface
          // (no OpenRouter server plugins / OpenAI built-ins).
          if (r.provider.apiStyle === 'anthropic') {
            const stream = await openAnthropicStream(
              r.baseURL,
              r.aigToken,
              {
                model: r.modelToCall,
                messages,
                tools: nativeFnTools,
                webSearch: webSearchOn ? input.webSearch ?? {} : null,
              },
              ac.signal,
            );
            return { stream };
          }
          if (r.provider.apiStyle === 'gemini') {
            const stream = await openGeminiStream(
              r.baseURL,
              r.aigToken,
              {
                model: r.modelToCall,
                messages,
                tools: nativeFnTools,
                webSearch: webSearchOn,
              },
              ac.signal,
              r.byokAlias,
            );
            return { stream };
          }
          // OpenAI-native providers speak the Responses API; everything
          // else (OpenRouter etc.) stays on Chat Completions. The adapter
          // re-emits Responses events as Chat-Completions-shaped chunks so
          // the streaming merge loop below is identical for both.
          if (r.provider.apiStyle === 'responses') {
            const { instructions, input } = chatMessagesToResponsesInput(messages);
            const stream = await openResponsesStream(
              r.client,
              {
                model: r.modelToCall,
                instructions,
                input,
                // Internal function tools + OpenAI's server-side built-in
                // tools (code interpreter, image gen always; web search only
                // when the bot's web-search switch is on).
                tools: [
                  ...chatToolsToResponsesTools(nativeFnTools),
                  ...(webSearchOn
                    ? OPENAI_BUILTIN_TOOLS
                    : OPENAI_BUILTIN_TOOLS.filter(
                        (t) => t.type !== 'web_search_preview',
                      )),
                ],
              },
              ac.signal,
            );
            return { stream };
          }
          // OpenRouter exposes web search / fetch / datetime as
          // server-executed plugin tools. They sit alongside our
          // function tools in the `tools` array but don't conform to the
          // OpenAI function-tool shape, so the cast is unavoidable. The
          // model decides when to call them; OpenRouter runs them and
          // feeds the result back without ever surfacing a function_call
          // to the worker.
          const chatTools =
            r.provider.slug === 'openrouter'
              ? [
                  ...turnTools,
                  ...(buildOpenRouterServerTools(input.webSearch) as unknown as ChatCompletionTool[]),
                ]
              : turnTools;
          const request = {
            model: r.modelToCall,
            messages,
            tools: chatTools,
            tool_choice: 'auto',
            stream: true,
            stream_options: { include_usage: true },
            // OpenRouter only returns `usage.cost` in streaming when this
            // extra body field is set.
            ...(r.provider.slug === 'openrouter' ? { usage: { include: true } } : {}),
          } as ChatCompletionCreateParamsStreaming;
          const stream = await r.client.chat.completions.create(
            request,
            { signal: ac.signal },
          );
          return { stream };
        },
      );
      const { stream } = roundOpen.result;
      route = roundOpen.route;
      routeTrace.push(...roundOpen.routeTrace);

      // Per-call accumulators.
      let assistantContent = '';
      const toolCalls: ChatCompletionMessageToolCall[] = [];
      // OpenRouter runs web search server-side and returns its sources as
      // message-level `annotations` (no function call to trace). Open a
      // synthetic search chip on the first one so the UI shows a search
      // happened; close it after the stream. OpenRouter doesn't expose the
      // query, so the chip carries no 搜索词.
      let orSearchChipOpen = false;

      for await (const chunk of stream) {
        if (ac.signal.aborted) break;
        const id = (chunk as { id?: string }).id;
        if (id && !generationId) generationId = id;

        const delta = chunk.choices?.[0]?.delta;

        // Visible content delta.
        const contentDelta = delta?.content ?? '';
        if (contentDelta) {
          pending += contentDelta;
          totalContent += contentDelta;
          assistantContent += contentDelta;

          // Hold token emissions while the cumulative reply could still be
          // the [SILENT] control token. Once the prefix breaks, flush.
          if (!couldStillBeSilent(totalContent.trimStart())) {
            const toEmit = totalContent.slice(emittedLen);
            if (toEmit) emit('token', { delta: toEmit });
            emittedLen = totalContent.length;
          }

          // Drain complete bubbles from pending.
          // eslint-disable-next-line no-constant-condition
          while (true) {
            const idx = pending.indexOf(BUBBLE_DELIMITER);
            if (idx === -1) break;
            const bubble = pending.slice(0, idx).trim();
            pending = pending.slice(idx + BUBBLE_DELIMITER.length);
            if (bubble) await emitBubble(bubble);
          }
        }

        // Tool call streaming. OpenAI emits tool_calls in chunks; merge by
        // index so we end up with one entry per call.
        const tcDeltas = delta?.tool_calls;
        if (tcDeltas) {
          for (const tc of tcDeltas) {
            const i = tc.index;
            if (!toolCalls[i]) {
              toolCalls[i] = {
                id: tc.id ?? '',
                type: 'function',
                function: { name: '', arguments: '' },
              };
            }
            if (tc.id) toolCalls[i].id = tc.id;
            if (tc.function?.name) toolCalls[i].function.name = tc.function.name;
            if (tc.function?.arguments) {
              toolCalls[i].function.arguments += tc.function.arguments;
            }
          }
        }

        // OpenRouter web-search citations ride the delta as `annotations`
        // (type 'url_citation', url+title nested under `url_citation`). The
        // Responses/native paths surface their sources via chunk.citations
        // instead; this handles the Chat Completions dialect only.
        const anns = (delta as { annotations?: unknown } | undefined)?.annotations;
        if (Array.isArray(anns)) {
          let addedAny = false;
          for (const a of anns) {
            if (!a || typeof a !== 'object') continue;
            const rec = a as { type?: unknown; url_citation?: unknown };
            if (rec.type !== 'url_citation' || !rec.url_citation || typeof rec.url_citation !== 'object') {
              continue;
            }
            const uc = rec.url_citation as { url?: unknown; title?: unknown };
            const url = typeof uc.url === 'string' ? uc.url : '';
            if (!url || citations.some((x) => x.url === url)) continue;
            if (!orSearchChipOpen) {
              emitToolEvent('tool_call', { name: 'web_search' });
              orSearchChipOpen = true;
            }
            citations.push({
              url,
              title: typeof uc.title === 'string' && uc.title ? uc.title : url,
            });
            addedAny = true;
          }
          if (addedAny) emitToolEvent('citations', { items: citations });
        }

        if (chunk.usage) {
          const u = usageFromCompletion(chunk.usage, chunk);
          usage.input += u.inputTokens ?? 0;
          usage.output += u.outputTokens ?? 0;
          usage.cacheRead += u.cacheReadTokens ?? 0;
          usage.cacheWrite += u.cacheWriteTokens ?? 0;
          mergeProviderUsageDetails(providerUsage, u);
        }

        // Built-in (server-side) tool activity. web_search / code_interpreter
        // run inside the provider — no tool_call for the loop to execute,
        // just mirror progress into the tool-trace UI. A finished
        // image_generation carries a PNG, which becomes its own bubble.
        if (chunk.builtinTool) {
          const bt = chunk.builtinTool;
          if (
            bt.kind === 'image_generation' &&
            bt.phase === 'completed' &&
            bt.imageBase64
          ) {
            // Persist → message row → resolve the open image_generation
            // chip with a tool_result either way. Without this the UI's
            // tool trace would sit on "image_generation 中" forever
            // (the started chip never got its matching result), even
            // when persistence succeeded. On success the bubble itself
            // arrives separately via the realtime hub.
            const r = await emitGeneratedImage(bt.imageBase64);
            emitToolEvent(
              'tool_result',
              r.ok
                ? { name: bt.kind, attachment_id: r.attachmentId }
                : { name: bt.kind, error: r.reason },
            );
          } else if (bt.kind === 'web_search') {
            // Normalise every provider's server-side search onto the same
            // tool name so the iOS trace renders it identically (chip,
            // 搜索词 label). The query (when the provider surfaces it) rides
            // the 'started' chip; results arrive separately via
            // chunk.citations below.
            emitToolEvent(
              bt.phase === 'started' ? 'tool_call' : 'tool_result',
              bt.phase === 'started' && bt.query
                ? { name: 'web_search', query: bt.query }
                : { name: 'web_search' },
            );
          } else {
            emitToolEvent(
              bt.phase === 'started' ? 'tool_call' : 'tool_result',
              { name: bt.kind },
            );
          }
        }

        // Server-side web-search results (OpenAI url_citation annotations,
        // Anthropic/Gemini result blocks). Fold into the per-turn citation
        // list — deduped against anything the MCP search path already added
        // — and push the cumulative list so iOS resolves [N] taps and shows
        // the result count.
        if (chunk.citations && chunk.citations.length > 0) {
          let added = false;
          for (const c of chunk.citations) {
            if (!c.url || citations.some((x) => x.url === c.url)) continue;
            citations.push({ url: c.url, title: c.title || c.url, snippet: c.snippet });
            added = true;
          }
          if (added) emitToolEvent('citations', { items: citations });
        }
      }

      // Close the synthetic OpenRouter search chip now the stream is done.
      if (orSearchChipOpen) {
        emitToolEvent('tool_result', { name: 'web_search', count: citations.length });
      }

      // Push the assistant turn (with any tool_calls) into running history
      // so the next iteration sees its own decision.
      if (toolCalls.length > 0) {
        messages.push({
          role: 'assistant',
          content: assistantContent || null,
          tool_calls: toolCalls,
        });
        // Execute tools. Each result becomes a tool message in history.
        // The mcpClient.owns() branch handles MCP-advertised tools (none
        // are advertised by default — the envelope-runner still drives
        // Exa MCP directly, and this branch is the seam for a future
        // per-bot MCP opt-in). Everything else flows through runTool.
        //
        // send_images is the one *terminal* function tool we expose: its
        // act of being called IS the bot's message (an attachment row),
        // so we break the agent loop after it runs instead of feeding
        // the result back for another LLM turn. Any text the model
        // emitted alongside the tool call has already bubbled through
        // the splitter, so the tail-emit at the bottom of runChatTurn
        // takes care of the rest.
        let terminalToolFired = false;
        for (const tc of toolCalls) {
          const args = safeParseArgs(tc.function.arguments);
          const result = mcpClient.owns(tc.function.name)
            ? await dispatchMcpTool(env, tc.function.name, args, toolCtx)
            : await runTool(env, tc.function.name, args, toolCtx);
          messages.push({ role: 'tool', tool_call_id: tc.id, content: result });
          if (tc.function.name === 'send_images') terminalToolFired = true;
        }
        if (terminalToolFired) break;
        // Loop: the model may want to call more tools or finally produce
        // user-visible content. Carry on.
        continue;
      }

      // No tool calls — this iteration's assistant text IS the final reply.
      messages.push({
        role: 'assistant',
        content: assistantContent || null,
      });
      break;
    }

    // Strip any [DROP_LOOKBACK] marker before emitting the tail bubble
    // OR running the silent check — the marker is a control token, not
    // user-visible content.
    let droppedLookbackIds: string[] = [];
    if (pending.includes(DROP_LOOKBACK_TOKEN) || totalContent.includes(DROP_LOOKBACK_TOKEN)) {
      pending = pending.split(DROP_LOOKBACK_TOKEN).join('').trim();
      totalContent = totalContent.split(DROP_LOOKBACK_TOKEN).join('').trim();
      droppedLookbackIds = activeLookbacks.map((l) => l.id);
    }

    const trimmed = totalContent.trim();
    if (trimmed === SILENT_TOKEN || trimmed === '') {
      emit('silent', { bubble_group_id: bubbleGroupId });
      bubblesInserted = 0;
      pending = '';
    } else if (pending.trim()) {
      await emitBubble(pending.trim());
      pending = '';
    }

    const finalStatus: RunChatTurnResult['finalStatus'] = ac.signal.aborted ? 'interrupted' : 'done';
    if (trimmed !== SILENT_TOKEN) {
      emit(finalStatus, { bubble_group_id: bubbleGroupId, total_content: totalContent });
    }
    await toolTracePersist;

    await enqueueAudit(env, route, {
      auditId: turnId,
      userId,
      conversationId,
      taskType: 'message_reply',
      startedAt,
      generationId,
      status: 'success',
      routeTrace,
      inputTokens: usage.input,
      outputTokens: usage.output,
      cacheReadTokens: usage.cacheRead,
      cacheWriteTokens: usage.cacheWrite,
      ...providerUsage,
      webTools: webMeter.snapshot(),
      // Full conversation → Langfuse generation input/output (#248). The
      // assistant turn was pushed onto `messages` above, so it carries the
      // whole prompt; `totalContent` is the raw model output.
      promptBody: messages,
      completionBody: totalContent,
      // Link the trace to the main system prompt's Langfuse version (text
      // surface → 'system'); no-op when Langfuse/KV hasn't populated it.
      promptName: getPromptMeta('system', locale)?.name,
      promptVersion: getPromptMeta('system', locale)?.version,
      metadata: {
        bot_id: bot.id,
        status: finalStatus,
        bubble_group_id: bubbleGroupId,
        bubbles: bubblesInserted,
      },
    });

    return { finalStatus, totalContent, bubblesInserted, droppedLookbackIds };
  } catch (err) {
    const aborted = ac.signal.aborted;
    if (pending.trim()) {
      try { await emitBubble(pending.trim()); } catch {}
    }
    const status: RunChatTurnResult['finalStatus'] = aborted ? 'interrupted' : 'error';
    // String(err) drops to "" / "[object Object]" for thrown plain objects;
    // dig into common error shapes so the iOS alert shows something useful.
    const message = aborted
      ? 'aborted'
      : (() => {
          if (err instanceof Error) {
            const head = err.message || err.name || 'Error';
            return err.stack ? `${head}\n${err.stack.split('\n').slice(0, 4).join('\n')}` : head;
          }
          if (err && typeof err === 'object') {
            try {
              return JSON.stringify(err).slice(0, 500);
            } catch {
              return Object.prototype.toString.call(err);
            }
          }
          return String(err) || 'unknown error';
        })();
    console.error('[bot-reply] runChatTurn failed:', err);
    emit(status, { message });
    await toolTracePersist;

    // Audit the failed turn so error rate / fallback metrics in the
    // panel see this. Two error paths:
    //   - FallbackError: every alias re-resolution attempt failed
    //     before any stream chunk arrived. lastRoute may be null.
    //     routeTrace shows the chain.
    //   - Anything else (mid-stream throw, tool error, etc.): we
    //     stayed on whatever route last opened a stream. Use the
    //     accumulated routeTrace from prior round successes.
    try {
      const audit = auditErrorFields(err);
      const fbErr = err instanceof FallbackError ? err : null;
      // Non-FallbackError throws happened after a route was already
      // open — keep that route and the trace accumulated by the rounds
      // that did succeed, rather than auditErrorFields' nulls.
      const auditRoute = fbErr ? audit.route : route;
      const auditTrace = fbErr ? audit.routeTrace : routeTrace;
      // error_class always speaks the classifyError vocabulary (auth /
      // rate_limit / no_route / …) so audit_log groups cleanly — it used
      // to fall back to the raw JS `err.name` on the non-fallback branch.
      const errorClass = aborted ? null : audit.errorClass;
      await enqueueAudit(env, auditRoute, {
        auditId: turnId,
        userId,
        conversationId,
        taskType: 'message_reply',
        startedAt,
        generationId,
        status: aborted ? 'success' : 'error',
        errorClass,
        routeTrace: auditTrace,
        inputTokens: usage.input,
        outputTokens: usage.output,
        cacheReadTokens: usage.cacheRead,
        cacheWriteTokens: usage.cacheWrite,
        ...providerUsage,
        // Tool calls that landed before the LLM stream errored should
        // still be billed — the upstream provider already consumed
        // those quotas regardless of how the turn ended.
        webTools: webMeter.snapshot(),
        // Full prompt + whatever output streamed before the error → Langfuse,
        // so a failed turn is debuggable from the trace (#248).
        promptBody: messages,
        completionBody: totalContent,
        promptName: getPromptMeta('system', locale)?.name,
        promptVersion: getPromptMeta('system', locale)?.version,
        metadata: {
          bot_id: bot.id,
          status,
          message: message.slice(0, 200),
          error_message: audit.message,
        },
      });
    } catch (auditErr) {
      console.warn('[bot-reply] audit on error failed:', auditErr);
    }

    return { finalStatus: status, totalContent, bubblesInserted, droppedLookbackIds: [] };
  } finally {
    signal.removeEventListener('abort', onCallerAbort);
  }
}
