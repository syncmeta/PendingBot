import type { Env } from '../../types';
import { WebToolMeter } from '../web-meter';
import type { WebSearchResult } from '../web-types';
import { queryUserRepresentation } from '../honcho';
import { searchChatHistoryTool } from './tools/search-history';
import { createSkillTool } from './tools/create-skill';
import { readAttachmentTool } from './tools/read-attachment';
import {
  setMyGroupNicknameTool,
  setBotGroupDescriptionTool,
} from './tools/group-meta';
import {
  executeCodeTool,
  requestExecuteCodeTool,
} from './tools/code-exec';
import { delegateToSpecialistTool } from './tools/delegate';
import { askFriendTool } from './tools/ask-friend';
import { submitInquiryAnswerTool } from './tools/submit-inquiry-answer';
import { sendImagesTool } from './tools/send-images';
import { promptModelGuessTool } from './tools/prompt-model-guess';

/// Single web-search citation. Stored on each bubble row's `citations`
/// jsonb so iOS can resolve inline `[N]` markers to a tappable link.
export interface Citation {
  url: string;
  title: string;
  snippet?: string;
}

/// Shared per-turn context every tool implementation receives. The
/// runner builds one and threads it through; tools never reach back
/// into runChatTurn directly so their dependencies stay narrow.
export interface ToolCtx {
  signal: AbortSignal;
  emit: (event: string, data: unknown) => void;
  userId: string;
  botId: string;
  conversationId: string;
  /// The user message that triggered this turn — sub-conversations spawned
  /// by delegate_to_specialist pin themselves to it via parent_message_id
  /// so the iOS bubble can deep-link into the child thread.
  parentMessageId: string;
  /// Conv's main model slug — needed by read_attachment to decide whether
  /// to route the tool call to the main model itself (vision-capable) or
  /// fall back to the configured vision model.
  botModelId: string;
  /// Bot's pinned vision model (bots.config.visionModel) — null = auto
  /// fallback chain.
  visionOverride: string | null;
  /// Accumulator shared with runChatTurn — search_web pushes deduped hits
  /// here so the per-turn `[N]` numbering stays stable across rounds.
  citations: Citation[];
  /// Per-turn meter — every web search / read goes through it so the
  /// call lands in audit_web_tool_calls and folds into billing.
  webMeter: WebToolMeter;
  /// True for group turns. query_user_memory uses it to decide whether to
  /// scope the dialectic to this conversation (group → no private-1v1 leak)
  /// or pool across all the (bot, user) pair's sessions (private turn).
  inGroup: boolean;
  /// Insert one bot message carrying these attachment ids (the
  /// send_images tool's terminal effect). Returns true if the row
  /// landed in messages. Implemented as a closure in runChatTurn so
  /// the tool doesn't need to know about bubbleGroupId / sender_bot_id
  /// / model_slug / model_provider plumbing.
  emitImagesMessage: (attachmentIds: string[]) => Promise<boolean>;
  /// Insert a `log_kind='guess_prompt'` message — the blind-box "猜一猜"
  /// interactive card. Returns true if the row landed. Closure in
  /// runChatTurn so the tool needn't know conversation/parent plumbing.
  emitGuessPrompt: () => Promise<boolean>;
}

/// Tolerant JSON parse for tool arg blobs. Models occasionally emit
/// malformed JSON; we fall back to an empty object rather than throwing
/// (the tool implementations downstream all check required-field
/// presence and return a typed error string when missing).
export function safeParseArgs(s: string): Record<string, unknown> {
  try {
    return JSON.parse(s) as Record<string, unknown>;
  } catch {
    return {};
  }
}

/// Central dispatcher: name → typed tool function. The implementation
/// returns a string JSON envelope the orchestrator pushes back into
/// the LLM tool-result message. All thrown errors are caught here and
/// returned as `{ error }` envelopes so the tool loop never crashes
/// the turn.
export async function runTool(
  env: Env,
  name: string,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  try {
    if (name === 'query_user_memory') {
      const query = String(args.query ?? '').trim();
      if (!query) return JSON.stringify({ error: 'empty query' });
      if (query.length > 500) {
        return JSON.stringify({ error: 'query exceeds 500 chars' });
      }
      ctx.emit('tool_call', { name: 'query_user_memory', query });
      const answer = await queryUserRepresentation({
        env,
        userId: ctx.userId,
        botId: ctx.botId,
        conversationId: ctx.conversationId,
        inGroup: ctx.inGroup,
        query,
        signal: ctx.signal,
      });
      ctx.emit('tool_result', {
        name: 'query_user_memory',
        chars: answer?.length ?? 0,
      });
      return JSON.stringify({ answer: answer ?? '(no information yet)' });
    }
    if (name === 'search_chat_history') {
      return await searchChatHistoryTool(env, args, ctx);
    }
    if (name === 'create_skill') {
      return await createSkillTool(env, args, ctx);
    }
    if (name === 'read_attachment') {
      return await readAttachmentTool(env, args, ctx);
    }
    if (name === 'execute_code') {
      return await executeCodeTool(env, args, ctx);
    }
    if (name === 'request_execute_code') {
      return await requestExecuteCodeTool(env, args, ctx);
    }
    if (name === 'set_my_group_nickname') {
      return await setMyGroupNicknameTool(env, args, ctx);
    }
    if (name === 'set_bot_group_description') {
      return await setBotGroupDescriptionTool(env, args, ctx);
    }
    if (name === 'delegate_to_specialist') {
      return await delegateToSpecialistTool(env, args, ctx);
    }
    if (name === 'ask_friend') {
      return await askFriendTool(env, args, ctx);
    }
    if (name === 'submit_inquiry_answer') {
      return await submitInquiryAnswerTool(env, args, ctx);
    }
    if (name === 'send_images') {
      return await sendImagesTool(env, args, ctx);
    }
    if (name === 'prompt_model_guess') {
      return await promptModelGuessTool(env, args, ctx);
    }
    return JSON.stringify({ error: `unknown tool: ${name}` });
  } catch (err) {
    const formatted = formatToolError(err);
    ctx.emit('tool_result', {
      name,
      error: formatted.message,
      detail: formatted.detail,
      status: formatted.status,
    });
    return JSON.stringify({
      error: formatted.message,
      detail: formatted.detail,
      status: formatted.status,
    });
  }
}

/// Shared post-processing for any search tool: dedupe hits against prior
/// citations in this turn so `n` numbering stays stable across multiple
/// calls (and across providers — a Tavily hit and a Brave hit pointing
/// at the same article reuse the same n). Emits tool_result + citations
/// SSE events and returns the JSON envelope the LLM consumes.
export function annotateSearchHits(
  ctx: ToolCtx,
  toolName: string,
  hits: WebSearchResult[],
): string {
  const annotated = hits.slice(0, 8).map((h) => {
    const existing = ctx.citations.findIndex((c) => c.url === h.url);
    let n: number;
    if (existing >= 0) {
      n = existing + 1;
    } else {
      ctx.citations.push({ url: h.url, title: h.title, snippet: h.snippet });
      n = ctx.citations.length;
    }
    return { n, url: h.url, title: h.title, snippet: h.snippet };
  });
  ctx.emit('tool_result', { name: toolName, count: annotated.length });
  // Push the cumulative citations list so iOS can resolve `[N]` taps in
  // the live preview before the bubble row hits Realtime.
  ctx.emit('citations', { items: ctx.citations });
  return JSON.stringify({
    results: annotated,
    hint: '若回复里要引用上面某条结果，请在相关说法后跟上 `[N]`（N 对应该条结果的 n）。多个引用可以连写如 `[1][3]`。无须引用就不要写。',
  });
}

export function formatToolError(err: unknown): { message: string; detail?: string; status?: number } {
  if (err instanceof Error) {
    return {
      message: err.message || err.name || 'Error',
      detail: err.stack,
    };
  }
  if (err && typeof err === 'object') {
    try {
      return {
        message: 'tool failed',
        detail: JSON.stringify(err, null, 2),
      };
    } catch {
      return { message: Object.prototype.toString.call(err) };
    }
  }
  return { message: String(err) || 'unknown error' };
}
