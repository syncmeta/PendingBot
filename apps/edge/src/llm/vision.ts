// Vision / multimodal helpers.
//
// Three jobs:
//
//  1. modelSupportsVision(slug) — does this model accept image input?
//     Source of truth is OpenRouter's catalog (architecture.
//     input_modalities). Unknown slugs return false → caller falls back
//     to the 'vision' model-role default.
//
//  2. summarizeAttachment(deps, attachmentId) — generate a 1-2 sentence
//     summary + 3-5 short tags for an image and persist them onto the
//     attachments row. Idempotent: skips if summary_status = 'done'.
//
//  3. readAttachmentForTool(deps, attachmentId, question) — answer a
//     specific question about an image. Used by the read_attachment chat
//     tool when the model needs more detail than the cached summary.
//
// Both (2) and (3) go through the standard router/withFallback so the
// audit log captures cost. The vision-model selection layer
// (pickVisionModel) decides which model to actually call:
//   - the bot's pinned vision model (bots.config.visionModel) if set
//   - else the conversation's main model if it has vision
//   - else the 'vision' model-role default
//
// Image bytes ride to the LLM as base64 data URLs (image_url block, the
// OpenAI/OpenRouter standard form). OpenRouter normalizes that to each
// provider's native vision input shape — we don't need to hand-roll
// Anthropic-native `image` blocks.

import type {
  ChatCompletionContentPart,
  ChatCompletionCreateParamsNonStreaming,
} from 'openai/resources/chat/completions';
import type { Env } from '../types';
import type { SupabaseClient } from '../lib/supabase';
import { patchCachedAttachment } from '../lib/attachment-cache';
import { classifyAttachment } from '../lib/attachments';
import { uuidv7 } from '../lib/ids';
import {
  auditErrorFields,
  enqueueAudit,
  usageFromCompletion,
  withFallback,
} from './router';
import { modelSupportsVision } from './catalog';
import { ensurePromptOverridesLoaded, getPrompt } from './prompt-loader';
import { getModelRole } from '../lib/model-roles';

/// When the conversation's main model lacks vision and no per-conversation
/// override is set, fall back to the 'vision' system model-role
/// (lib/model-roles.ts; board-configurable). Code default = moonshotai/kimi-latest
/// — consistently vision-capable, supports tool use, cheap (~$0.75/M in), and
/// comfortable with Chinese (the app's primary language).

/// Cap how big a base64 data URL we'll send to the model. Beyond this we
/// risk hitting per-image limits at the various providers (Anthropic
/// caps at ~5MB/image post-encoding, several others reject very large
/// payloads outright). Our upload limit is 10MB raw, which expands to
/// ~13.4MB base64 — already too big. So we'd ideally downscale; for now
/// we just reject with summary_status='failed' and log the reason. iOS
/// already pre-compresses to JPEG so most uploads land under this.
const MAX_DATA_URL_BYTES = 5 * 1024 * 1024;

/// Cap on a file (PDF) content part. Files ride to the provider as a
/// base64 data URL too; 25 MB raw (our upload cap) → ~33 MB base64,
/// comfortably under the providers' per-file input limits. Acts as a
/// guard rather than a real gate since it matches MAX_UPLOAD_BYTES.
const MAX_FILE_DATA_URL_BYTES = 25 * 1024 * 1024;

/// Cap on retry when the summarizer fails transiently. We only retry
/// once — most "transient" cases here (provider 429/503) clear up but
/// aren't worth blocking the conversation on. The attachment row keeps
/// summary_status='failed' so a sweeper / manual operator can re-trigger.
const SUMMARY_MAX_ATTEMPTS = 2;

interface AttachmentRow {
  id: string;
  user_id: string;
  conversation_id: string | null;
  r2_key: string;
  mime_type: string;
  byte_size: number;
  filename: string | null;
  summary: string | null;
  summary_status: string;
  vision_model: string | null;
}

/// Base64-encode a byte buffer. Workers' `btoa` takes a binary string,
/// so we chunk to dodge "Maximum call stack" on big buffers — 32 KB at
/// a time is safe for the V8 stack.
function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

export interface PickVisionModelInput {
  /// The conversation's main model (the bot's bots.model_id).
  mainModelSlug: string;
  /// The bot's pinned vision model (bots.config.visionModel) — null/absent
  /// = auto.
  override: string | null;
}

export interface PickedVisionModel {
  slug: string;
  /// Why this slug was chosen — surfaced in route_trace metadata so the
  /// audit panel can attribute the cost.
  reason: 'override' | 'main_has_vision' | 'default_fallback';
}

/// Decide which model to use for vision calls in a given conversation.
/// Caller must pre-check whether the main model has vision (one query
/// hit) and pass that in via `mainHasVision` to avoid double-querying.
export function pickVisionModel(
  input: PickVisionModelInput & { mainHasVision: boolean; defaultSlug: string },
): PickedVisionModel {
  if (input.override && input.override.trim().length > 0) {
    return { slug: input.override.trim(), reason: 'override' };
  }
  if (input.mainHasVision) {
    return { slug: input.mainModelSlug, reason: 'main_has_vision' };
  }
  return { slug: input.defaultSlug, reason: 'default_fallback' };
}

/// Read an attachment's bytes from R2 and produce an OpenAI-style
/// image_url content part with a base64 data URL payload. Returns null
/// when the object is missing in R2 (already swept) or oversize.
export async function loadAttachmentAsImagePart(
  env: Env,
  attachment: Pick<AttachmentRow, 'r2_key' | 'mime_type' | 'byte_size'>,
): Promise<ChatCompletionContentPart | null> {
  if (attachment.byte_size > MAX_DATA_URL_BYTES) return null;
  const obj = await env.UPLOADS.get(attachment.r2_key);
  if (!obj) return null;
  const b64 = bytesToBase64(new Uint8Array(await obj.arrayBuffer()));
  const url = `data:${attachment.mime_type};base64,${b64}`;
  return { type: 'image_url', image_url: { url } };
}

/// Read an attachment's bytes from R2 and produce an OpenAI-style `file`
/// content part with a base64 data URL payload. Used for PDFs on the
/// current turn so the provider parses the document natively (OpenRouter
/// routes via its file-parser plugin for models lacking native support;
/// OpenAI's gpt models accept PDF file parts directly). Returns null
/// when the object is missing in R2 or oversize.
export async function loadAttachmentAsFilePart(
  env: Env,
  attachment: Pick<AttachmentRow, 'r2_key' | 'mime_type' | 'byte_size' | 'filename'>,
): Promise<ChatCompletionContentPart | null> {
  if (attachment.byte_size > MAX_FILE_DATA_URL_BYTES) return null;
  const obj = await env.UPLOADS.get(attachment.r2_key);
  if (!obj) return null;
  const b64 = bytesToBase64(new Uint8Array(await obj.arrayBuffer()));
  return {
    type: 'file',
    file: {
      filename: attachment.filename || 'attachment.pdf',
      file_data: `data:${attachment.mime_type};base64,${b64}`,
    },
  };
}

interface VisionDeps {
  supa: SupabaseClient;
  env: Env;
  /// Conversation context — used for audit_log attribution.
  conversationId: string | null;
  /// User on whose behalf we're making the call (for billing). May be
  /// null for system-triggered work like re-summarization sweeps.
  userId: string | null;
  /// The conversation's main model slug (the bot's bots.model_id).
  /// Caller resolves this once and passes it down so we don't round-trip
  /// the bots table inside every helper.
  mainModelSlug: string;
  /// The bot's pinned vision model (bots.config.visionModel) — null = auto.
  visionOverride: string | null;
}

interface SummaryJson {
  summary: string;
  tags: string[];
}

function parseSummaryJson(text: string): SummaryJson | null {
  // Models occasionally wrap JSON in ```json fences despite being told
  // not to. Strip those before parsing.
  const trimmed = text.trim().replace(/^```(?:json)?\s*|\s*```$/g, '');
  try {
    const parsed = JSON.parse(trimmed) as Partial<SummaryJson>;
    if (typeof parsed.summary !== 'string' || !Array.isArray(parsed.tags)) {
      return null;
    }
    const tags = parsed.tags
      .filter((t): t is string => typeof t === 'string')
      .map((t) => t.trim().slice(0, 32))
      .filter((t) => t.length > 0)
      .slice(0, 5);
    return { summary: parsed.summary.trim().slice(0, 2000), tags };
  } catch {
    return null;
  }
}

/// Generate + persist a summary for one attachment. Idempotent — if the
/// row already has summary_status='done', returns early without calling
/// the model. Errors are caught and stamped onto the row as 'failed' so
/// callers (the message-create hook, the re-read tool fallback) don't
/// have to handle them.
export async function summarizeAttachment(
  deps: VisionDeps,
  attachmentId: string,
): Promise<void> {
  const { supa, env } = deps;
  const startedAt = Date.now();
  const turnId = uuidv7();
  // Warm the prompt cache so the sync getPrompt('image-summary') below hits
  // memory. This entry point is reached from the message-create hook /
  // re-summarization sweep, neither of which warms prompts upstream.
  await ensurePromptOverridesLoaded(env);

  // Cast through unknown — schema.ts is regenerated lazily after each
  // migration; the new summary_* columns lift in 0064 but the typed
  // client doesn't know yet. Runtime shape is the source of truth.
  const { data: row, error } = await supa
    .from('attachments')
    .select(
      'id, user_id, conversation_id, r2_key, mime_type, byte_size, summary, summary_status, vision_model',
    )
    .eq('id', attachmentId)
    .maybeSingle();
  if (error || !row) {
    console.warn('[vision] summarize: attachment not found', attachmentId);
    return;
  }
  const att = row as unknown as AttachmentRow;

  if (att.summary_status === 'done' || att.summary_status === 'skipped') {
    return;
  }

  // Resolve which model to call.
  const mainHasVision = await modelSupportsVision(deps.mainModelSlug);
  const picked = pickVisionModel({
    mainModelSlug: deps.mainModelSlug,
    override: deps.visionOverride,
    mainHasVision,
    defaultSlug: await getModelRole(env, 'vision'),
  });

  const part = await loadAttachmentAsImagePart(env, att);
  if (!part) {
    await supa
      .from('attachments')
      .update({
        summary_status: 'failed',
        summary_error:
          att.byte_size > MAX_DATA_URL_BYTES
            ? `oversize: ${att.byte_size} bytes (max ${MAX_DATA_URL_BYTES})`
            : 'r2 object missing',
      })
      .eq('id', attachmentId);
    return;
  }

  try {
    const callResult = await withFallback(
      supa,
      env,
      {
        modelSlug: picked.slug,
        taskType: 'attachment_summary',
        maxAttempts: SUMMARY_MAX_ATTEMPTS,
        metadata: { userId: deps.userId, conversationId: deps.conversationId, turnId },
      },
      async (route) => {
        const request = {
          model: route.modelToCall,
          messages: [
            {
              role: 'user',
              content: [
                { type: 'text', text: getPrompt('image-summary') },
                part,
              ],
            },
          ],
          // Belt-and-suspenders for providers that honor it. Many vision
          // models ignore json_object mode but still emit clean JSON when
          // the prompt tells them to.
          response_format: { type: 'json_object' },
          temperature: 0.2,
        } as ChatCompletionCreateParamsNonStreaming;
        const completion = await route.client.chat.completions.create(request);
        return completion;
      },
    );
    const completion = callResult.result;
    const text = completion.choices?.[0]?.message?.content ?? '';
    const usage = usageFromCompletion(completion.usage, completion);
    const parsed = parseSummaryJson(typeof text === 'string' ? text : '');

    // Audit even on parse failure — we did spend tokens.
    await enqueueAudit(env, callResult.route, {
      auditId: turnId,
      userId: deps.userId,
      conversationId: deps.conversationId,
      taskType: 'attachment_summary',
      startedAt,
      generationId:
        ((completion as { id?: string }).id as string | undefined) ?? null,
      status: 'success',
      ...usage,
      routeTrace: callResult.routeTrace,
      metadata: {
        attachment_id: attachmentId,
        vision_model: picked.slug,
        vision_reason: picked.reason,
        parsed: parsed != null,
      },
    });

    if (!parsed) {
      await supa
        .from('attachments')
        .update({
          summary_status: 'failed',
          summary_error: `model returned non-JSON (first 200 chars): ${String(
            text,
          ).slice(0, 200)}`,
          vision_model: picked.slug,
        })
        .eq('id', attachmentId);
      await patchCachedAttachment(deps.env, attachmentId, { summary_status: 'failed' });
      return;
    }

    await supa
      .from('attachments')
      .update({
        summary: parsed.summary,
        tags: parsed.tags,
        vision_model: picked.slug,
        summary_status: 'done',
        summary_error: null,
        summarized_at: new Date().toISOString(),
      })
      .eq('id', attachmentId);
    await patchCachedAttachment(deps.env, attachmentId, {
      summary: parsed.summary,
      tags: parsed.tags,
      summary_status: 'done',
    });
  } catch (err) {
    const message =
      err instanceof Error ? err.message : String(err) || 'unknown error';
    console.warn('[vision] summarize failed', attachmentId, message);
    const audit = auditErrorFields(err);
    await enqueueAudit(env, audit.route, {
      auditId: turnId,
      userId: deps.userId,
      conversationId: deps.conversationId,
      taskType: 'attachment_summary',
      startedAt,
      status: 'error',
      errorClass: audit.errorClass,
      routeTrace: audit.routeTrace,
      metadata: {
        attachment_id: attachmentId,
        vision_model: picked.slug,
        vision_reason: picked.reason,
        error_message: audit.message,
      },
    });
    await supa
      .from('attachments')
      .update({
        summary_status: 'failed',
        summary_error: message.slice(0, 500),
        vision_model: picked.slug,
      })
      .eq('id', attachmentId);
    await patchCachedAttachment(deps.env, attachmentId, { summary_status: 'failed' });
  }
}

/// Fire summaries for a list of attachment ids. Used by the message-create
/// hook to kick off all attachments on the just-inserted user message.
/// Runs them sequentially to be polite to the upstream provider — typical
/// case is 1-3 images per message.
export async function summarizeAttachments(
  deps: VisionDeps,
  attachmentIds: string[],
): Promise<void> {
  for (const id of attachmentIds) {
    try {
      await summarizeAttachment(deps, id);
    } catch (err) {
      // summarizeAttachment swallows its own errors; this catch is a
      // defensive belt for unexpected throws (e.g. supabase outage).
      console.warn('[vision] summarizeAttachments outer catch', id, err);
    }
  }
}

/// Max characters of a text file returned by the read_attachment tool.
/// A 25 MB file would blow the context window; we hand back a prefix and
/// tell the model it was truncated.
const MAX_FILE_TEXT_CHARS = 100_000;

/// Read a non-image, non-PDF attachment's bytes from R2 and return them
/// as text. Files that aren't valid UTF-8 are reported as binary (with
/// their metadata) rather than returning mojibake. No model call — the
/// calling model reads the content itself.
async function readFileAttachmentAsText(
  env: Env,
  att: AttachmentRow,
): Promise<{ answer: string } | { error: string }> {
  const obj = await env.UPLOADS.get(att.r2_key);
  if (!obj) return { error: 'file unavailable (object missing)' };
  const bytes = new Uint8Array(await obj.arrayBuffer());
  let text: string;
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return {
      answer:
        `这是一个二进制文件（类型 ${att.mime_type}，文件名 ${att.filename ?? '未命名'}，` +
        `大小 ${att.byte_size} 字节），无法作为文本读取。`,
    };
  }
  if (text.length > MAX_FILE_TEXT_CHARS) {
    text =
      text.slice(0, MAX_FILE_TEXT_CHARS) +
      `\n\n…（文件较大，已截断，仅返回前 ${MAX_FILE_TEXT_CHARS} 个字符）`;
  }
  return { answer: text };
}

/// Tool-side: answer a specific question about an attachment. For images
/// and PDFs a model parses the bytes and answers; for other file types
/// the raw text content is returned directly. Distinct from summarize
/// because the caller (the bot reply loop) controls the question.
export async function readAttachmentForTool(
  deps: VisionDeps,
  attachmentId: string,
  question: string,
): Promise<{ answer: string } | { error: string }> {
  const { supa, env } = deps;
  const startedAt = Date.now();
  const turnId = uuidv7();

  const { data: row, error } = await supa
    .from('attachments')
    .select('id, user_id, conversation_id, r2_key, mime_type, byte_size, filename')
    .eq('id', attachmentId)
    .maybeSingle();
  if (error) return { error: `database: ${error.message}` };
  if (!row) return { error: 'attachment not found' };
  const att = row as AttachmentRow;

  // Cross-conversation gate. The model only sees attachment ids that
  // appeared in this conversation's history; this is defense in depth in
  // case it hallucinates an id that belongs to another conv.
  if (
    deps.conversationId &&
    att.conversation_id &&
    att.conversation_id !== deps.conversationId
  ) {
    return { error: 'attachment does not belong to this conversation' };
  }

  const kind = classifyAttachment(att.mime_type);

  // Plain files (not image, not PDF) — return the raw text straight
  // from R2, no model round-trip. The calling model reads it itself.
  if (kind === 'file') {
    return readFileAttachmentAsText(env, att);
  }

  // Image or PDF → a model parses the bytes and answers. Images ride as
  // an image_url part; PDFs as a file part the provider parses natively.
  const part =
    kind === 'pdf'
      ? await loadAttachmentAsFilePart(env, att)
      : await loadAttachmentAsImagePart(env, att);
  if (!part) {
    return {
      error:
        kind === 'pdf'
          ? 'file unavailable (oversize or missing)'
          : 'image unavailable (oversize or missing)',
    };
  }

  const mainHasVision = await modelSupportsVision(deps.mainModelSlug);
  const picked = pickVisionModel({
    mainModelSlug: deps.mainModelSlug,
    override: deps.visionOverride,
    mainHasVision,
    defaultSlug: await getModelRole(env, 'vision'),
  });

  const userQuestion =
    question.trim().slice(0, 500) ||
    (kind === 'pdf' ? '请概述这个文件的内容。' : '请详细描述这张图片。');

  try {
    const callResult = await withFallback(
      supa,
      env,
      {
        modelSlug: picked.slug,
        taskType: 'attachment_read',
        maxAttempts: SUMMARY_MAX_ATTEMPTS,
        metadata: { userId: deps.userId, conversationId: deps.conversationId, turnId },
      },
      async (route) => {
        const request = {
          model: route.modelToCall,
          messages: [
            {
              role: 'user',
              content: [
                { type: 'text', text: userQuestion },
                part,
              ],
            },
          ],
          temperature: 0.3,
        } as ChatCompletionCreateParamsNonStreaming;
        return route.client.chat.completions.create(request);
      },
    );
    const completion = callResult.result;
    const text = completion.choices?.[0]?.message?.content ?? '';
    const usage = usageFromCompletion(completion.usage, completion);
    await enqueueAudit(env, callResult.route, {
      auditId: turnId,
      userId: deps.userId,
      conversationId: deps.conversationId,
      taskType: 'attachment_read',
      startedAt,
      generationId:
        ((completion as { id?: string }).id as string | undefined) ?? null,
      status: 'success',
      ...usage,
      routeTrace: callResult.routeTrace,
      metadata: {
        attachment_id: attachmentId,
        vision_model: picked.slug,
        vision_reason: picked.reason,
      },
    });
    const answer = typeof text === 'string' ? text : '';
    return { answer: answer || '(模型未返回文本)' };
  } catch (err) {
    const message =
      err instanceof Error ? err.message : String(err) || 'unknown error';
    const audit = auditErrorFields(err);
    await enqueueAudit(env, audit.route, {
      auditId: turnId,
      userId: deps.userId,
      conversationId: deps.conversationId,
      taskType: 'attachment_read',
      startedAt,
      status: 'error',
      errorClass: audit.errorClass,
      routeTrace: audit.routeTrace,
      metadata: {
        attachment_id: attachmentId,
        vision_model: picked.slug,
        vision_reason: picked.reason,
        error_message: audit.message,
      },
    });
    return { error: message };
  }
}
