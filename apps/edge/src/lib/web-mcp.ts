// Web tool wrappers that invoke the *official hosted* MCP servers for
// Tavily and Exa instead of hitting their REST APIs directly. We use
// these to give the bot specialized search/extract tools layered on
// top of the generic search_web / read_url, so a prompt like "find
// recent reporting on …" routes to Tavily and "find papers about …"
// routes to Exa.
//
// Why MCP at all if we already have direct HTTP wrappers in web.ts?
// Because the user explicitly asked for "use each provider's official
// MCP" as the source of truth for the integration. We pay the cost of
// an extra initialize/notifications/initialized round-trip per call
// (the Worker is stateless, no session caching) in exchange for not
// owning the request/response shape ourselves.
//
// Notable trade-off: the upstream cost fields (Tavily's
// `usage.credits`, Exa's `costDollars.total`) are NOT propagated by
// these MCP servers — they return only the tool's `content[]` text.
// So billing for these tools still uses the local price book
// (web_tool_prices), same as the direct-HTTP path. The MCP transport
// gives us no additional cost-tracking visibility; if anything it
// hides it. See the inline note on each wrapper.

import type { Env } from '../types';
import { callMcpToolMetered, flattenMcpText } from './mcp-client';
import type { WebToolMeter } from './web-meter';
import type { WebSearchResult, WebReadResult } from './web-types';

// Hosted MCP endpoints. Auth differs per vendor:
//   • Tavily — API key in query param `tavilyApiKey`
//   • Exa    — API key in header `x-api-key`
const TAVILY_MCP_BASE = 'https://mcp.tavily.com/mcp/';
const EXA_MCP_URL = 'https://mcp.exa.ai/mcp';

function tavilyUrl(env: Env): string {
  if (!env.TAVILY_API_KEY) throw new Error('TAVILY_API_KEY missing');
  const u = new URL(TAVILY_MCP_BASE);
  u.searchParams.set('tavilyApiKey', env.TAVILY_API_KEY);
  return u.toString();
}

function exaHeaders(env: Env): Record<string, string> {
  if (!env.EXA_API_KEY) throw new Error('EXA_API_KEY missing');
  return { 'x-api-key': env.EXA_API_KEY };
}

// ── Tavily ───────────────────────────────────────────────────────────

export interface RunTavilyMcpSearchOpts {
  query: string;
  meter: WebToolMeter;
  /// 'basic' is 1 credit, 'advanced' is 2 credits. Maps to the
  /// `search_depth` arg on tavily-search.
  depth?: 'basic' | 'advanced';
  signal?: AbortSignal;
}

/**
 * Tavily web search via the hosted MCP `tavily-search` tool.
 *
 * MCP response shape (observed): content[0].text is the stringified
 * JSON of the upstream `/search` response. We parse and normalize to
 * the same WebSearchResult shape the direct path produces so callers
 * can treat both transports interchangeably.
 */
export async function runTavilyMcpSearch(
  env: Env,
  opts: RunTavilyMcpSearchOpts,
): Promise<WebSearchResult[]> {
  const result = await callMcpToolMetered(
    {
      url: tavilyUrl(env),
      signal: opts.signal,
      meter: opts.meter,
      provider: 'tavily',
      kind: 'search',
      target: opts.query,
    },
    'tavily-search',
    {
      query: opts.query,
      max_results: 8,
      search_depth: opts.depth ?? 'basic',
    },
  );
  return parseTavilySearchPayload(flattenMcpText(result));
}

export interface RunTavilyMcpExtractOpts {
  url: string;
  meter: WebToolMeter;
  signal?: AbortSignal;
}

export async function runTavilyMcpExtract(
  env: Env,
  opts: RunTavilyMcpExtractOpts,
): Promise<WebReadResult> {
  const result = await callMcpToolMetered(
    {
      url: tavilyUrl(env),
      signal: opts.signal,
      meter: opts.meter,
      provider: 'tavily',
      kind: 'scrape',
      target: opts.url,
    },
    'tavily-extract',
    { urls: [opts.url] },
  );
  return parseTavilyExtractPayload(opts.url, flattenMcpText(result));
}

// ── Exa ──────────────────────────────────────────────────────────────

export interface RunExaMcpSearchOpts {
  query: string;
  meter: WebToolMeter;
  signal?: AbortSignal;
}

/**
 * Exa semantic search via the hosted MCP `web_search_exa` tool. The
 * tool name uses underscores (not the snake-vs-kebab quirk that
 * Tavily has).
 */
export async function runExaMcpSearch(
  env: Env,
  opts: RunExaMcpSearchOpts,
): Promise<WebSearchResult[]> {
  const result = await callMcpToolMetered(
    {
      url: EXA_MCP_URL,
      headers: exaHeaders(env),
      signal: opts.signal,
      meter: opts.meter,
      provider: 'exa',
      kind: 'search',
      target: opts.query,
    },
    'web_search_exa',
    {
      query: opts.query,
      numResults: 8,
    },
  );
  return parseExaSearchPayload(flattenMcpText(result));
}

export interface RunExaMcpFetchOpts {
  url: string;
  meter: WebToolMeter;
  signal?: AbortSignal;
}

export async function runExaMcpFetch(
  env: Env,
  opts: RunExaMcpFetchOpts,
): Promise<WebReadResult> {
  const result = await callMcpToolMetered(
    {
      url: EXA_MCP_URL,
      headers: exaHeaders(env),
      signal: opts.signal,
      meter: opts.meter,
      provider: 'exa',
      kind: 'scrape',
      target: opts.url,
    },
    'web_fetch_exa',
    { url: opts.url },
  );
  return parseExaFetchPayload(opts.url, flattenMcpText(result));
}

// ── Response parsers ─────────────────────────────────────────────────
// Each MCP wrapper above hands its content[0].text down here. The
// hosted servers stringify the upstream JSON verbatim, but we keep
// parsers tolerant: if a server changes its formatting we'd rather
// degrade to an empty list than throw and break the LLM turn.

function parseTavilySearchPayload(text: string): WebSearchResult[] {
  const json = safeJson(text) as {
    results?: Array<{ url?: string; title?: string; content?: string }>;
  } | null;
  if (!json?.results) return [];
  return json.results
    .filter((r): r is { url: string; title?: string; content?: string } => !!r.url)
    .map((r) => ({
      url: r.url,
      title: r.title ?? '',
      snippet: r.content ?? '',
    }));
}

function parseTavilyExtractPayload(reqUrl: string, text: string): WebReadResult {
  const json = safeJson(text) as {
    results?: Array<{ url?: string; raw_content?: string }>;
  } | null;
  const first = json?.results?.[0];
  return {
    url: first?.url ?? reqUrl,
    title: '',
    content: first?.raw_content ?? '',
  };
}

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

function parseExaFetchPayload(reqUrl: string, text: string): WebReadResult {
  // Exa's web_fetch_exa returns either a single result object or a
  // results[] array, depending on the call shape. Handle both.
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
