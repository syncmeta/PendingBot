// Vision / multimodal helpers.
//
// Three jobs:
//
//  1. modelSupportsVision(supa, slug) — does this model accept image input?
//     Source of truth is llm_models.capabilities.vision (jsonb). Unknown
//     (passthrough) slugs return false → caller falls back to
//     DEFAULT_VISION_MODEL.
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
//   - explicit conversations.vision_model_override if set
//   - else the conversation's main model if it has vision
//   - else DEFAULT_VISION_MODEL
//
// Image bytes ride to the LLM as base64 data URLs (image_url block, the
// OpenAI/OpenRouter standard form). OpenRouter normalizes that to each
// provider's native vision input shape — we don't need to hand-roll
// Anthropic-native `image` blocks.

import type { ChatCompletionContentPart } from 'openai/resources/chat/completions';
import type { Env } from '../types';
import type { SupabaseClient } from '../lib/supabase';
import { patchCachedAttachment } from '../lib/attachment-cache';
import { recordAudit, withFallback, usageFromCompletion } from './router';

/// When the conversation's main model lacks vision and no
/// per-conversation override is set, fall back to this slug. Picked
/// because kimi-latest is consistently vision-capable, supports tool use,
/// is cheap (~$0.75/M in), and is comfortable with Chinese which is the
/// app's primary language.
export const DEFAULT_VISION_MODEL = 'moonshotai/kimi-latest';

/// Cap how big a base64 data URL we'll send to the model. Beyond this we
/// risk hitting per-image limits at the various providers (Anthropic
/// caps at ~5MB/image post-encoding, several others reject very large
/// payloads outright). Our upload limit is 10MB raw, which expands to
/// ~13.4MB base64 — already too big. So we'd ideally downscale; for now
/// we just reject with summary_status='failed' and log the reason. iOS
/// already pre-compresses to JPEG so most uploads land under this.
const MAX_DATA_URL_BYTES = 5 * 1024 * 1024;

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
  summary: string | null;
  summary_status: string;
  vision_model: string | null;
}

// Isolate-local cache for llm_models.capabilities lookups. The table
// changes only when the admin board edits model pricing/capabilities;
// 5 min TTL bounds drift without putting a Supabase RTT on every turn.
// Per-slug entries so different bots' models stay independent.
const VISION_CAP_TTL_MS = 5 * 60_000;
const visionCapCache = new Map<string, { at: number; value: boolean }>();

export function _resetVisionCapCache(): void {
  visionCapCache.clear();
}

/// Returns true iff llm_models has an entry for this slug with
/// capabilities.vision = true. Unknown slugs (passthrough) return false —
/// conservatively assume no vision so we route through the default model.
///
/// Result cached for 5 min on the worker isolate; an admin edit
/// propagates within ~TTL across all isolates.
export async function modelSupportsVision(
  supa: SupabaseClient,
  slug: string,
): Promise<boolean> {
  if (!slug) return false;
  const now = Date.now();
  const hit = visionCapCache.get(slug);
  if (hit && now - hit.at < VISION_CAP_TTL_MS) return hit.value;
  const { data } = await supa
    .from('llm_models')
    .select('capabilities')
    .eq('slug', slug)
    .eq('enabled', true)
    .maybeSingle();
  let value = false;
  if (data) {
    const caps = (data as { capabilities?: Record<string, unknown> | null })
      .capabilities;
    if (caps && typeof caps === 'object' && caps.vision === true) value = true;
  }
  visionCapCache.set(slug, { at: now, value });
  return value;
}

export interface PickVisionModelInput {
  /// Conversation's effective main model (after model_slug_override).
  mainModelSlug: string;
  /// conversations.vision_model_override — null/absent = auto.
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
  input: PickVisionModelInput & { mainHasVision: boolean },
): PickedVisionModel {
  if (input.override && input.override.trim().length > 0) {
    return { slug: input.override.trim(), reason: 'override' };
  }
  if (input.mainHasVision) {
    return { slug: input.mainModelSlug, reason: 'main_has_vision' };
  }
  return { slug: DEFAULT_VISION_MODEL, reason: 'default_fallback' };
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
  const buf = await obj.arrayBuffer();
  // Workers' btoa accepts a binary string — chunk to dodge "Maximum call
  // stack" on big buffers. 32KB at a time is safe for V8 stack.
  const bytes = new Uint8Array(buf);
  let binary = '';
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  const b64 = btoa(binary);
  const url = `data:${attachment.mime_type};base64,${b64}`;
  return { type: 'image_url', image_url: { url } };
}

interface VisionDeps {
  supa: SupabaseClient;
  env: Env;
  /// Conversation context — used for audit_log attribution and to look
  /// up the conversation's vision_model_override + main model slug.
  conversationId: string | null;
  /// User on whose behalf we're making the call (for billing). May be
  /// null for system-triggered work like re-summarization sweeps.
  userId: string | null;
  /// The conversation's effective main model slug (post override).
  /// Caller resolves this once and passes it down so we don't round-trip
  /// the bots/conversations table inside every helper.
  mainModelSlug: string;
  /// conversations.vision_model_override — null = auto.
  visionOverride: string | null;
}

const SUMMARY_PROMPT =
  '请观察这张图片，输出严格的 JSON（不要 markdown 代码块），格式：' +
  '{"summary":"一两句中文描述，包含画面主体和氛围","tags":["3-5 个短标签","每个不超过 8 个字"]}。' +
  '若图片包含明显文字（截图、文档、海报等），把关键文字一并写入 summary。';

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
  const mainHasVision = await modelSupportsVision(supa, deps.mainModelSlug);
  const picked = pickVisionModel({
    mainModelSlug: deps.mainModelSlug,
    override: deps.visionOverride,
    mainHasVision,
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
      },
      async (route) => {
        const completion = await route.client.chat.completions.create({
          model: route.modelToCall,
          messages: [
            {
              role: 'user',
              content: [
                { type: 'text', text: SUMMARY_PROMPT },
                part,
              ],
            },
          ],
          // Belt-and-suspenders for providers that honor it. Many vision
          // models ignore json_object mode but still emit clean JSON when
          // the prompt tells them to.
          response_format: { type: 'json_object' },
          temperature: 0.2,
        });
        return completion;
      },
    );
    const completion = callResult.result;
    const text = completion.choices?.[0]?.message?.content ?? '';
    const usage = usageFromCompletion(completion.usage);
    const parsed = parseSummaryJson(typeof text === 'string' ? text : '');

    // Audit even on parse failure — we did spend tokens.
    await recordAudit(supa, callResult.route, {
      userId: deps.userId,
      conversationId: deps.conversationId,
      taskType: 'attachment_summary',
      startedAt,
      generationId:
        ((completion as { id?: string }).id as string | undefined) ?? null,
      status: 'success',
      ...usage,
      routeTrace: callResult.routeTrace,
      env,
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

/// Tool-side: answer a specific question about an image. Returns the
/// model's free-form text answer. Distinct from summarize because the
/// caller (the bot reply loop) controls the question — typically
/// something like "图中文字内容是什么" or "人物服饰的细节描述".
export async function readAttachmentForTool(
  deps: VisionDeps,
  attachmentId: string,
  question: string,
): Promise<{ answer: string } | { error: string }> {
  const { supa, env } = deps;
  const startedAt = Date.now();

  const { data: row, error } = await supa
    .from('attachments')
    .select('id, user_id, conversation_id, r2_key, mime_type, byte_size')
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

  const part = await loadAttachmentAsImagePart(env, att);
  if (!part) return { error: 'image unavailable (oversize or missing)' };

  const mainHasVision = await modelSupportsVision(supa, deps.mainModelSlug);
  const picked = pickVisionModel({
    mainModelSlug: deps.mainModelSlug,
    override: deps.visionOverride,
    mainHasVision,
  });

  const userQuestion = question.trim().slice(0, 500) || '请详细描述这张图片。';

  try {
    const callResult = await withFallback(
      supa,
      env,
      {
        modelSlug: picked.slug,
        taskType: 'attachment_read',
        maxAttempts: SUMMARY_MAX_ATTEMPTS,
      },
      async (route) =>
        route.client.chat.completions.create({
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
        }),
    );
    const completion = callResult.result;
    const text = completion.choices?.[0]?.message?.content ?? '';
    const usage = usageFromCompletion(completion.usage);
    await recordAudit(supa, callResult.route, {
      userId: deps.userId,
      conversationId: deps.conversationId,
      taskType: 'attachment_read',
      startedAt,
      generationId:
        ((completion as { id?: string }).id as string | undefined) ?? null,
      status: 'success',
      ...usage,
      routeTrace: callResult.routeTrace,
      env,
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
    return { error: message };
  }
}
