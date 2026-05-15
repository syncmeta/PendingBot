import type { Env } from '../../types';
import { mcpClient } from '../../mcp/client';
import { annotateSearchHits, formatToolError, type ToolCtx } from './tool-runner';
import type { WebSearchResult } from '../web-types';

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

// ── payload parsers ─────────────────────────────────────────────────
// Exa's hosted MCP returns the upstream JSON verbatim in content[0].text.
// We keep parsers tolerant: a server-side formatting drift should
// degrade gracefully rather than break the LLM turn.

function parseExaSearchPayload(text: string): WebSearchResult[] {
  const json = safeJson(text) as {
    results?: Array<{ url?: string; title?: string; text?: string }>;
  } | null;
  if (!json?.results) return [];
  return json.results
    .filter((r): r is { url: string; title?: string; text?: string } => !!r.url)
    .map((r) => ({
      url: r.url,
      title: r.title ?? '',
      snippet: (r.text ?? '').slice(0, 500),
    }));
}

function parseExaFetchPayload(
  reqUrl: string,
  text: string,
): { url: string; title: string; content: string } {
  // Exa's web_fetch_exa returns either a single result object or a
  // results[] array depending on call shape. Handle both.
  const json = safeJson(text) as
    | { url?: string; title?: string; text?: string }
    | { results?: Array<{ url?: string; title?: string; text?: string }> }
    | null;
  if (!json) return { url: reqUrl, title: '', content: '' };
  const single = 'text' in json && json.text !== undefined ? json : null;
  const first = single ?? ((json as { results?: Array<unknown> }).results?.[0] as
    | { url?: string; title?: string; text?: string }
    | undefined);
  return {
    url: first?.url ?? reqUrl,
    title: first?.title ?? '',
    content: first?.text ?? '',
  };
}

function safeJson(text: string): unknown {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
