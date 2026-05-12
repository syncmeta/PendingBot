import type { Env } from '../../types';
import { runWebScrape, runWebSearch } from '../web';
import { WebToolMeter } from '../web-meter';
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

// Truncate Firecrawl scrape results so tool replies don't blow past the
// model's context. Plenty for a typical article.
const READ_TRUNCATE_CHARS = 6000;

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
  /// Conv's main model slug — needed by read_attachment to decide whether
  /// to route the tool call to the main model itself (vision-capable) or
  /// fall back to the configured vision model.
  botModelId: string;
  /// conversations.vision_model_override — null = auto fallback chain.
  visionOverride: string | null;
  /// Accumulator shared with runChatTurn — search_web pushes deduped hits
  /// here so the per-turn `[N]` numbering stays stable across rounds.
  citations: Citation[];
  /// Per-turn meter — every web search / read goes through it so the
  /// call lands in audit_web_tool_calls and folds into billing.
  webMeter: WebToolMeter;
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
    if (name === 'search_web') {
      const query = String(args.query ?? '').trim();
      if (!query) return JSON.stringify({ error: 'empty query' });
      ctx.emit('tool_call', { name: 'search_web', query });
      const hits = await runWebSearch(env, {
        provider: 'brave',
        query,
        signal: ctx.signal,
        meter: ctx.webMeter,
      });
      // Dedupe by url against prior search calls in this same turn so the
      // model sees stable `n`s — once it learned the New York Times piece is
      // [3], that mapping survives a follow-up search that re-surfaces the
      // same article.
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
      ctx.emit('tool_result', { name: 'search_web', count: annotated.length });
      // Push the cumulative citations list so iOS can resolve `[N]` taps in
      // the live preview before the bubble row hits Realtime.
      ctx.emit('citations', { items: ctx.citations });
      return JSON.stringify({
        results: annotated,
        hint: '若回复里要引用上面某条结果，请在相关说法后跟上 `[N]`（N 对应该条结果的 n）。多个引用可以连写如 `[1][3]`。无须引用就不要写。',
      });
    }
    if (name === 'read_url') {
      const url = String(args.url ?? '').trim();
      if (!url) return JSON.stringify({ error: 'empty url' });
      ctx.emit('tool_call', { name: 'read_url', url });
      const page = await runWebScrape(env, {
        provider: 'firecrawl',
        url,
        signal: ctx.signal,
        meter: ctx.webMeter,
      });
      ctx.emit('tool_result', { name: 'read_url', title: page.title });
      return JSON.stringify({
        url: page.url,
        title: page.title,
        content: page.content.slice(0, READ_TRUNCATE_CHARS),
      });
    }
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
        conversationId: ctx.conversationId,
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
    return JSON.stringify({ error: `unknown tool: ${name}` });
  } catch (err) {
    ctx.emit('tool_result', { name, error: String(err) });
    return JSON.stringify({ error: String(err) });
  }
}
