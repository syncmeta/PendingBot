// Minimal MCP-over-Streamable-HTTP client for use inside the Cloudflare
// Worker. We don't pull in @modelcontextprotocol/sdk because it targets
// Node and brings far more surface than we need — for the hosted MCP
// endpoints we target (Tavily, Exa) the protocol is just JSON-RPC over
// `fetch`, plus a session-id header round-trip.
//
// Scope of this implementation:
//   • Streamable HTTP transport only (spec date 2025-03-26 / 2025-06-18)
//   • One-shot tools/call usage — every callMcpTool() does the full
//     initialize → notifications/initialized → tools/call sequence on a
//     fresh session. No session caching across requests; the Worker is
//     stateless and tool calls are infrequent enough that an extra
//     ~100ms of handshake is acceptable.
//   • Supports both response modes: server may answer a POST with
//     `application/json` (single response) or `text/event-stream` (SSE
//     stream). Both Tavily's and Exa's hosted MCPs use the JSON mode in
//     practice, but the SSE path is wired for the more general case.
//
// Out of scope: server-initiated SSE (GET /), elicitation, sampling,
// resources, prompts. We only use the tool-call surface.

import type { WebToolMeter, WebToolKind, WebToolProvider } from './web-meter';

const PROTOCOL_VERSION = '2025-06-18';
const CLIENT_INFO = { name: 'pendingbot-edge', version: '1' };

/// Structured content envelope a tool returns. MCP tools always answer
/// with a `content[]` array of typed parts; we expose it raw and let
/// the caller flatten to whatever shape the upstream tool wrapper
/// wants. `isError` distinguishes "tool ran but returned an error
/// message to the model" from a transport failure (transport failures
/// throw McpError instead).
export interface McpToolResult {
  content: Array<{ type: string; text?: string; data?: unknown }>;
  isError?: boolean;
  /// Some servers also include a structuredContent field — passed
  /// through verbatim for callers that want richer parsing than the
  /// text concatenation we default to.
  structuredContent?: unknown;
}

export interface McpClientConfig {
  /// Full MCP endpoint URL. Auth via query param (Tavily) or header
  /// (Exa) is the caller's responsibility — embed the API key into
  /// `url` directly or add it to `headers`.
  url: string;
  /// Extra headers (e.g. Exa wants `x-api-key`). `Content-Type` and
  /// `Accept` are set internally.
  headers?: Record<string, string>;
  signal?: AbortSignal;
}

export class McpError extends Error {
  constructor(message: string, readonly status?: number, readonly responseText?: string) {
    super(message);
    this.name = 'McpError';
  }
}

interface JsonRpcRequest {
  jsonrpc: '2.0';
  id?: number;
  method: string;
  params?: unknown;
}

interface JsonRpcResponse {
  jsonrpc: '2.0';
  id: number;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

/// Call a single tool on a remote MCP server. Returns the structured
/// tool result. Throws McpError on transport / protocol failure;
/// surfaces tool-side errors via `result.isError = true` and the
/// content array (callers should inspect this rather than treat it as
/// a thrown error, matching how MCP clients are expected to behave).
export async function callMcpTool(
  config: McpClientConfig,
  toolName: string,
  args: Record<string, unknown>,
): Promise<McpToolResult> {
  const headers: Record<string, string> = {
    ...config.headers,
    'Content-Type': 'application/json',
    // Both content types are accepted per spec; server picks.
    Accept: 'application/json, text/event-stream',
    'MCP-Protocol-Version': PROTOCOL_VERSION,
  };

  // ── 1. initialize ────────────────────────────────────────────────
  const initRes = await jsonRpc(config.url, headers, {
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: CLIENT_INFO,
    },
  }, config.signal);

  if (initRes.error) {
    throw new McpError(`mcp initialize failed: ${initRes.error.message}`, undefined, JSON.stringify(initRes.error));
  }

  // Carry forward session id if the server issued one.
  if (initRes.sessionId) {
    headers['Mcp-Session-Id'] = initRes.sessionId;
  }

  // ── 2. notifications/initialized (no response expected) ──────────
  await jsonRpc(config.url, headers, {
    jsonrpc: '2.0',
    method: 'notifications/initialized',
  }, config.signal);

  // ── 3. tools/call ────────────────────────────────────────────────
  const callRes = await jsonRpc(config.url, headers, {
    jsonrpc: '2.0',
    id: 2,
    method: 'tools/call',
    params: { name: toolName, arguments: args },
  }, config.signal);

  if (callRes.error) {
    throw new McpError(`mcp tools/call failed: ${callRes.error.message}`, undefined, JSON.stringify(callRes.error));
  }
  const result = (callRes.result ?? {}) as McpToolResult;
  if (!Array.isArray(result.content)) {
    // Some servers return the result without wrapping content[]; coerce.
    return { content: [{ type: 'text', text: JSON.stringify(callRes.result) }] };
  }
  return result;
}

interface RpcReply {
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
  sessionId?: string;
}

/// Send one JSON-RPC message. For requests (`id` set) returns the
/// matching response by extracting it from JSON body or SSE stream.
/// For notifications (no `id`) returns `{}` after the POST completes;
/// the server replies with HTTP 202 Accepted in this case.
async function jsonRpc(
  url: string,
  headers: Record<string, string>,
  message: JsonRpcRequest,
  signal?: AbortSignal,
): Promise<RpcReply> {
  const isNotification = message.id === undefined;
  const res = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify(message),
    signal,
  });

  // 202 Accepted for notifications, or any 2xx with empty body.
  if (isNotification) {
    if (!res.ok && res.status !== 202) {
      const body = await safeText(res);
      throw new McpError(`mcp ${message.method} HTTP ${res.status}`, res.status, body);
    }
    return {};
  }

  if (!res.ok) {
    const body = await safeText(res);
    throw new McpError(`mcp ${message.method} HTTP ${res.status}`, res.status, body);
  }

  const sessionId = res.headers.get('Mcp-Session-Id') ?? undefined;
  const contentType = res.headers.get('content-type') ?? '';

  if (contentType.includes('text/event-stream')) {
    const reply = await readSseResponse(res, message.id!);
    return { ...reply, sessionId };
  }

  // Default: application/json body containing a single JsonRpcResponse.
  const json = (await res.json()) as JsonRpcResponse;
  if (json.id !== message.id) {
    throw new McpError(`mcp ${message.method} id mismatch: expected ${message.id}, got ${json.id}`);
  }
  return { result: json.result, error: json.error, sessionId };
}

/// Stream-parse a text/event-stream until we see the JSON-RPC response
/// matching `targetId`. SSE frames are `event:`/`data:` blocks separated
/// by `\n\n`; we only care about `data:` payloads carrying a
/// JsonRpcResponse. Other event types (e.g. notifications/progress)
/// are skipped — we don't expose progress to callers yet.
async function readSseResponse(res: Response, targetId: number): Promise<RpcReply> {
  if (!res.body) {
    throw new McpError('mcp sse response had no body');
  }
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      let sep: number;
      while ((sep = buffer.indexOf('\n\n')) !== -1) {
        const frame = buffer.slice(0, sep);
        buffer = buffer.slice(sep + 2);
        const dataLine = frame
          .split('\n')
          .find((l) => l.startsWith('data:'));
        if (!dataLine) continue;
        const payload = dataLine.slice(5).trim();
        if (!payload || payload === '[DONE]') continue;
        try {
          const parsed = JSON.parse(payload) as JsonRpcResponse;
          if (parsed.id === targetId) {
            return { result: parsed.result, error: parsed.error };
          }
        } catch {
          // Skip non-JSON SSE comments / heartbeats silently.
        }
      }
    }
  } finally {
    reader.releaseLock();
  }

  throw new McpError(`mcp sse stream ended without response id ${targetId}`);
}

async function safeText(res: Response): Promise<string> {
  try {
    const t = await res.text();
    return t.slice(0, 300);
  } catch {
    return '';
  }
}

// ── Helpers for the search/scrape integration ────────────────────────

/// Flatten an MCP tool's content[] into one string. MCP tools that wrap
/// REST APIs typically return a single text part whose body is the
/// upstream JSON response stringified, but the contract is content[] of
/// typed parts; this helper picks the first text part.
export function flattenMcpText(result: McpToolResult): string {
  if (!result.content) return '';
  for (const part of result.content) {
    if (part.type === 'text' && typeof part.text === 'string') {
      return part.text;
    }
  }
  return '';
}

/// Light wrapper that meters an MCP tool call as a web tool entry.
/// Mirrors the runWebSearch / runWebScrape contract in web.ts so the
/// audit_web_tool_calls row lands with the same shape regardless of
/// whether the underlying transport is direct HTTP or MCP. `provider`
/// and `kind` must be a (provider, kind) pair registered in
/// web_tool_prices; the local price book remains the authoritative
/// billing source even when responses come from an MCP server that
/// doesn't pass cost through.
export async function callMcpToolMetered(
  config: McpClientConfig & {
    meter: WebToolMeter;
    provider: WebToolProvider;
    kind: WebToolKind;
    target: string;
  },
  toolName: string,
  args: Record<string, unknown>,
): Promise<McpToolResult> {
  const startedAt = Date.now();
  try {
    const result = await callMcpTool(config, toolName, args);
    config.meter.record({
      provider: config.provider,
      kind: config.kind,
      target: config.target,
      status: result.isError ? 'error' : 'success',
      latencyMs: Date.now() - startedAt,
      errorClass: result.isError ? 'tool_error' : undefined,
    });
    return result;
  } catch (err) {
    config.meter.record({
      provider: config.provider,
      kind: config.kind,
      target: config.target,
      status: 'error',
      latencyMs: Date.now() - startedAt,
      errorClass: errorClassFor(err),
    });
    throw err;
  }
}

function errorClassFor(err: unknown): string {
  if (err instanceof McpError) {
    if (err.status === 401 || err.status === 403) return 'auth';
    if (err.status === 429) return 'rate_limit';
    if (err.status && err.status >= 500) return 'server_error';
    if (err.status && err.status >= 400) return 'bad_request';
    return 'mcp';
  }
  if (err && typeof err === 'object') {
    const e = err as { name?: string; message?: string };
    if (e.name === 'AbortError') return 'abort';
    const msg = (e.message ?? '').toLowerCase();
    if (msg.includes('timeout')) return 'timeout';
    return e.name ?? 'unknown';
  }
  return 'unknown';
}
