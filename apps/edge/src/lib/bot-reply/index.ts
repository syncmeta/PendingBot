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
import { classifyAttachment, sha256Hex, r2KeyForHash } from '../attachments';
import {
  resolveBotNote,
  resolveChatMemo,
  resolveSubscriptions,
} from '../persona-cache';
import { resolveProviderSlug } from '../../llm/providers';
import { WebToolMeter } from '../web-meter';
import {
  buildDelegateTool,
  buildOpenRouterServerTools,
  CHAT_TOOLS,
  EXECUTE_CODE_TOOL,
  GROUP_BOT_TOOLS,
  REQUEST_EXECUTE_CODE_TOOL,
  type WebSearchConfig,
} from './tool-defs';
import { specialistTargetsForUser } from './tools/delegate';
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

// Persist an image the OpenAI image_generation built-in tool produced:
// base64 PNG → R2 (content-addressed, same scheme as user uploads) → an
// attachments row owned by the conversation's user. Returns the new
// attachment id, or null if anything failed (the turn carries on without
// the image rather than aborting). Idempotent on (user_id, content_sha256).
//
// Dedup pattern matches routes/upload.ts: SELECT-then-INSERT with a
// 23505 race fallback. We can't use `.upsert(..., { onConflict })`
// here because the dedup index `idx_attachments_user_sha256` is
// *partial* (`WHERE content_sha256 IS NOT NULL`), and PostgREST's
// `ON CONFLICT (cols)` syntax can't auto-arbitrate against a partial
// index — PG returns "no unique or exclusion constraint matching the
// ON CONFLICT specification" and the upsert silently fails, eating the
// generated image. (Found 2026-05-20 after image_generation appeared to
// hang in chat: turn completed cleanly in ~165s, base64 came back, but
// the attachment row never landed and emitGeneratedImage early-returned
// without inserting a bubble.)
async function persistGeneratedImage(
  env: Env,
  supa: ReturnType<typeof serviceClient>,
  userId: string,
  conversationId: string,
  base64: string,
): Promise<string | null> {
  try {
    const bin = atob(base64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const sha = await sha256Hex(bytes);
    const key = r2KeyForHash(sha, 'image/png');

    // Fast path: this user already has a row for these bytes (e.g. the
    // model regenerated an identical image). Reuse it; skip R2 write.
    {
      const { data: dup } = await supa
        .from('attachments')
        .select('id')
        .eq('user_id', userId)
        .eq('content_sha256', sha)
        .maybeSingle();
      if (dup) return (dup as { id: string }).id;
    }

    const existing = await env.UPLOADS.head(key).catch(() => null);
    if (!existing) {
      await env.UPLOADS.put(key, bytes, {
        httpMetadata: { contentType: 'image/png' },
      });
    }

    const { data, error } = await supa
      .from('attachments')
      .insert({
        user_id: userId,
        conversation_id: conversationId,
        r2_key: key,
        mime_type: 'image/png',
        byte_size: bytes.length,
        content_sha256: sha,
      })
      .select('id')
      .single();

    // Race fallback: a parallel turn (or a concurrent user upload of
    // the same bytes) hit the partial UNIQUE between our SELECT and
    // INSERT. Re-fetch the winner.
    if (error) {
      if ((error as { code?: string }).code === '23505') {
        const { data: winner } = await supa
          .from('attachments')
          .select('id')
          .eq('user_id', userId)
          .eq('content_sha256', sha)
          .maybeSingle();
        if (winner) return (winner as { id: string }).id;
      }
      console.warn('[bot-reply] generated-image attachment insert', error.message);
      return null;
    }
    return data.id as string;
  } catch (err) {
    console.warn('[bot-reply] persistGeneratedImage failed', err);
    return null;
  }
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
  /// conversations.vision_model_override (0064). NULL = auto. Threaded
  /// through to summarize + read_attachment so the per-conv pin actually
  /// kicks in.
  visionModelOverride?: string | null;
  /// Per-conversation provider pin (slug from llm_providers.slug, e.g.
  /// 'worldrouter' / 'openrouter'). When set, passed to LLMRouter as
  /// preferProvider; the existing fallback chain still kicks in if the
  /// chosen provider 5xxs. NULL = follow the default routing.
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
  // Specialist enumeration is also independent of the prompt; the
  // delegate tool only joins the per-turn list when at least one
  // registered specialist exists. Resolved lazily — failure here
  // shouldn't block the turn, so we swallow and treat as "no targets".
  const delegateTargetsPromise = specialistTargetsForUser(env, userId).catch(
    () => [] as Array<'claude' | 'openai' | 'gemini'>,
  );

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
  const [botMemory, subsBundle, botNote, chatMemo, botViewOfUser, userViewOfBot] =
    await Promise.all([
      input.isSelfChat ? getUserMemory(env, userId) : getBotMemory(env, bot.id),
      resolveSubscriptions(env, supa, userId, conversationId, turnProviderSlug, noop),
      resolveBotNote(env, supa, bot.id, userId, noop),
      resolveChatMemo(env, supa, bot.id, conversationId, noop),
      relational ? getBotViewOfUser(env, bot.id, userId) : Promise.resolve(null),
      relational ? getUserViewOfBot(env, userId, bot.id) : Promise.resolve(null),
    ]);
  const skills = subsBundle.skills.map((s) => ({
    name: s.name,
    description: s.description,
    body: s.body,
  }));
  const allowedTools = new Set<string>(subsBundle.allowedTools);

  // 1.5 Vision/attachment resolution.
  //
  // - mainHasVision: lookup llm_models.capabilities.vision for this conv's
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
    supa,
    {
      bot, botMemory, botViewOfUser, userViewOfBot, skills, botNote, chatMemo,
      lookbacks: activeLookbacks,
      recentContext, newMessage,
      currentImageParts,
      currentFileParts,
      attachmentInventory: inventory,
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
  };

  const emitBubble = async (text: string) => {
    if (!text) return;
    bubbleIndex++;
    const bubbleId = randomUUID();
    const clientMessageId = randomUUID();
    const snapshot = citations.length > 0 ? citations.map((c) => ({ ...c })) : null;
    await supa.from('messages').insert({
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
    });
    bubblesInserted++;
    emit('bubble', {
      id: bubbleId,
      index: bubbleIndex,
      bubble_group_id: bubbleGroupId,
      content: text,
      citations: snapshot,
    });
  };

  // Persist an image the OpenAI image_generation built-in tool produced
  // as its own bot message (attachments jsonb shape: { ids: [...] }).
  //
  // Deliberately does NOT emit an SSE `bubble` event or touch
  // `bubbleIndex`: that counter is kept in lockstep with the splitter's
  // streamed text bubbles so the client can rekey them, and an image
  // bubble has no streamed counterpart. The inserted row reaches the
  // client through the Cloudflare realtime hub (messages-table AFTER
  // INSERT trigger → notify_realtime() → /v1/realtime-internal/notify →
  // RealtimeHubDO WebSocket fan-out). The caller is responsible for
  // resolving the corresponding `tool_result` SSE so the UI chip
  // doesn't sit at "image_generation 中" forever.
  //
  // Returns: ok with the new attachment id, or failed with a reason
  // string so the dispatch site can surface an error chip in the trace
  // UI instead of silently swallowing the result. ("not-persisted"
  // covers persistGeneratedImage returning null — R2 PUT or DB INSERT
  // failed and was logged; "insert-failed" covers the messages.insert.)
  type EmitImageResult =
    | { ok: true; attachmentId: string }
    | { ok: false; reason: string };
  const emitGeneratedImage = async (
    base64: string,
  ): Promise<EmitImageResult> => {
    const attachmentId = await persistGeneratedImage(
      env, supa, userId, conversationId, base64,
    );
    if (!attachmentId) return { ok: false, reason: 'not-persisted' };
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
      attachments: { ids: [attachmentId] },
    });
    if (error) {
      console.warn('[bot-reply] generated-image message insert', error.message);
      return { ok: false, reason: 'insert-failed' };
    }
    bubblesInserted++;
    return { ok: true, attachmentId };
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
  const turnToolsRaw: ChatCompletionTool[] = [
    ...CHAT_TOOLS,
    REQUEST_EXECUTE_CODE_TOOL,
  ];
  if (allowedTools.has('execute_code')) turnToolsRaw.push(EXECUTE_CODE_TOOL);
  if (input.inGroup) turnToolsRaw.push(...GROUP_BOT_TOOLS);
  // Subagent delegation. Only the OpenRouter routing path gets this tool
  // — native-provider bots are the targets, not the callers, so giving
  // a native bot the tool would either no-op (no one to delegate to) or
  // invite recursion. The dynamic enum is the user's actual specialist
  // set; with no specialists registered, the tool simply doesn't ship.
  const delegateTargets = await delegateTargetsPromise;
  if (turnProviderSlug === 'openrouter' && delegateTargets.length > 0) {
    turnToolsRaw.push(buildDelegateTool(delegateTargets));
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
  const nativeFnToolsRaw: ChatCompletionTool[] = [...CHAT_TOOLS];
  if (input.inGroup) nativeFnToolsRaw.push(...GROUP_BOT_TOOLS);
  const nativeFnTools: ChatCompletionTool[] = applyToolRegistry(
    nativeFnToolsRaw,
    toolRegistry,
  );

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
              { model: r.modelToCall, messages, tools: nativeFnTools },
              ac.signal,
            );
            return { stream };
          }
          if (r.provider.apiStyle === 'gemini') {
            const stream = await openGeminiStream(
              r.baseURL,
              r.aigToken,
              { model: r.modelToCall, messages, tools: nativeFnTools },
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
                // tools (web search, code interpreter).
                tools: [
                  ...chatToolsToResponsesTools(nativeFnTools),
                  ...OPENAI_BUILTIN_TOOLS,
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

        if (chunk.usage) {
          const u = usageFromCompletion(chunk.usage, chunk);
          usage.input += u.inputTokens ?? 0;
          usage.output += u.outputTokens ?? 0;
          usage.cacheRead += u.cacheReadTokens ?? 0;
          usage.cacheWrite += u.cacheWriteTokens ?? 0;
          mergeProviderUsageDetails(providerUsage, u);
        }

        // Built-in (server-side) tool activity. web_search / code_interpreter
        // run inside OpenAI — no tool_call for the loop to execute, just
        // mirror progress into the tool-trace UI. A finished
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
          } else {
            emitToolEvent(
              bt.phase === 'started' ? 'tool_call' : 'tool_result',
              { name: bt.kind },
            );
          }
        }
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
        for (const tc of toolCalls) {
          const args = safeParseArgs(tc.function.arguments);
          const result = mcpClient.owns(tc.function.name)
            ? await dispatchMcpTool(env, tc.function.name, args, toolCtx)
            : await runTool(env, tc.function.name, args, toolCtx);
          messages.push({ role: 'tool', tool_call_id: tc.id, content: result });
        }
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
      const fbErr = err instanceof FallbackError ? err : null;
      const auditRoute = fbErr ? fbErr.lastRoute : route;
      const auditTrace = fbErr ? fbErr.routeTrace : routeTrace;
      const errorClass = aborted
        ? null
        : fbErr
          ? fbErr.routeTrace[fbErr.routeTrace.length - 1]?.error_class ?? 'unknown'
          : err instanceof Error
            ? err.name
            : 'unknown';
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
        metadata: { bot_id: bot.id, status, message: message.slice(0, 200) },
      });
    } catch (auditErr) {
      console.warn('[bot-reply] audit on error failed:', auditErr);
    }

    return { finalStatus: status, totalContent, bubblesInserted, droppedLookbackIds: [] };
  } finally {
    signal.removeEventListener('abort', onCallerAbort);
  }
}
