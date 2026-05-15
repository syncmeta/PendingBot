import type { Env } from '../../types';
import { mcpClient } from '../../mcp/client';
import { parseExaFetchPayload, parseExaSearchPayload } from '../../mcp/parsers';
import { annotateSearchHits, formatToolError, type ToolCtx } from './tool-runner';

// Tool reply truncation — matches the old read_url path so the model
// doesn't see bigger fetches via the MCP route than it used to via the
// direct-HTTP wrapper.
const READ_TRUNCATE_CHARS = 6000;

// Dispatch for tools sourced from mcpClient (currently Exa hosted MCP).
// Mirrors runTool's contract: returns a JSON string envelope that the
// outer agent loop pushes onto messages as `role: 'tool'`. Errors are
// caught and folded into the envelope so the turn keeps going.
//
// Tool-name-specific shaping (citation accumulation for search,
// truncation for fetch) lives here so the MCP client itself stays
// transport-only and unaware of bot-reply's SSE/citation protocol.
export async function dispatchMcpTool(
  env: Env,
  name: string,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  try {
    if (name === 'web_search_exa') {
      const query = String(args.query ?? '').trim();
      if (!query) return JSON.stringify({ error: 'empty query' });
      ctx.emit('tool_call', { name, query });
      const { text, isError } = await mcpClient.callTool(name, args, {
        env,
        meter: ctx.webMeter,
        signal: ctx.signal,
      });
      if (isError) {
        ctx.emit('tool_result', { name, error: text });
        return JSON.stringify({ error: text || 'search failed' });
      }
      const hits = parseExaSearchPayload(text);
      return annotateSearchHits(ctx, name, hits);
    }

    if (name === 'web_fetch_exa') {
      const url = String(args.url ?? '').trim();
      if (!url) return JSON.stringify({ error: 'empty url' });
      ctx.emit('tool_call', { name, url });
      const { text, isError } = await mcpClient.callTool(name, args, {
        env,
        meter: ctx.webMeter,
        signal: ctx.signal,
      });
      if (isError) {
        ctx.emit('tool_result', { name, error: text });
        return JSON.stringify({ error: text || 'fetch failed' });
      }
      const page = parseExaFetchPayload(url, text);
      ctx.emit('tool_result', { name, title: page.title });
      return JSON.stringify({
        url: page.url,
        title: page.title,
        content: page.content.slice(0, READ_TRUNCATE_CHARS),
      });
    }

    return JSON.stringify({ error: `mcp tool not handled: ${name}` });
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

