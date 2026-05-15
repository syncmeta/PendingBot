// MCP client manager — per-isolate singleton that owns connections to
// upstream MCP servers and exposes their tools to the bot-reply loop.
//
// The list of servers is loaded from the `mcp_servers` table (cached
// 60s per isolate) so adding a new connector is a row insert + a
// wrangler secret put rather than a code change. Secret *values* stay
// in Cloudflare Workers Secrets — only the env-var name lives in the
// table (`secret_ref`) and we resolve it via `env[secret_ref]` at
// request time.
//
// The model receives upstream tools under their vendor-native names
// with vendor descriptions — no PendingBot rewrapping. bot-reply
// consumes the tool result envelope and decides whether to extract
// citations etc.

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import type { ChatCompletionTool } from 'openai/resources/chat/completions';
import type { Env } from '../types';
import { serviceClient, type SupabaseClient } from '../lib/supabase';
import { WebToolMeter, type WebToolProvider, type WebToolKind } from '../lib/web-meter';

// Vendor MCP tool name → billing dimensions for WebToolMeter. New entries
// here are the only thing required to bill a new tool through the price
// book in `web_tool_prices`.
//
// Once the upcoming `tools` registry lands this map moves to DB too;
// for v1 we keep it as code so the billing contract stays static.
const TOOL_BILLING: Record<string, { provider: WebToolProvider; kind: WebToolKind } | undefined> = {
  web_search_exa: { provider: 'exa', kind: 'search' },
  web_fetch_exa: { provider: 'exa', kind: 'scrape' },
};

interface McpServerConfig {
  name: string;
  url: string;
  transport: 'http' | 'sse';
  auth_kind: 'none' | 'header';
  auth_header_name: string | null;
  secret_ref: string | null;
}

// Module-scope server-registry cache. 60s mirrors web-meter — long
// enough to amortize the DB hit across a chat session, short enough
// that toggling a server in board takes effect within a minute.
const SERVER_REGISTRY_TTL_MS = 60_000;
let serverRegistryCache: { at: number; servers: McpServerConfig[] } | null = null;

async function loadServerRegistry(env: Env): Promise<McpServerConfig[]> {
  const now = Date.now();
  if (serverRegistryCache && now - serverRegistryCache.at < SERVER_REGISTRY_TTL_MS) {
    return serverRegistryCache.servers;
  }
  const supa: SupabaseClient = serviceClient(env);
  const { data, error } = await supa
    .from('mcp_servers')
    .select('name, url, transport, auth_kind, auth_header_name, secret_ref')
    .eq('enabled', true);
  if (error || !data) {
    console.warn('[mcp] registry load failed:', error?.message ?? 'no data');
    // Cache an empty list briefly so we don't pound the DB on every
    // request while the table is misconfigured.
    serverRegistryCache = { at: now, servers: [] };
    return [];
  }
  const servers: McpServerConfig[] = data.map((r) => ({
    name: r.name,
    url: r.url,
    transport: r.transport as 'http' | 'sse',
    auth_kind: r.auth_kind as 'none' | 'header',
    auth_header_name: r.auth_header_name,
    secret_ref: r.secret_ref,
  }));
  serverRegistryCache = { at: now, servers };
  return servers;
}

function resolveAuthHeaders(env: Env, cfg: McpServerConfig): Record<string, string> | undefined {
  if (cfg.auth_kind === 'none') return undefined;
  if (cfg.auth_kind === 'header' && cfg.auth_header_name && cfg.secret_ref) {
    const value = (env as unknown as Record<string, unknown>)[cfg.secret_ref];
    if (typeof value !== 'string' || value.length === 0) return undefined;
    return { [cfg.auth_header_name]: value };
  }
  return undefined;
}

type ConnState =
  | { stage: 'idle' }
  | { stage: 'connecting'; promise: Promise<ReadyState> }
  | ReadyState;

interface ReadyState {
  stage: 'ready';
  client: Client;
  tools: ChatCompletionTool[];
  /** Tool names exposed to the model from this server. */
  toolNames: Set<string>;
}

class McpClientManager {
  private servers = new Map<string, ConnState>();
  /** Tool name → server name; rebuilt on each successful connect. */
  private toolToServer = new Map<string, string>();

  /**
   * Returns the OpenAI-shaped tool list (merged across all enabled
   * servers) to merge into the model's `tools` array. Per-server
   * failures (missing secret, upstream down) degrade to "no tools
   * from that server" — the bot still works with whatever connected.
   */
  async getAITools(env: Env, signal?: AbortSignal): Promise<ChatCompletionTool[]> {
    const registry = await loadServerRegistry(env);
    if (registry.length === 0) return [];
    const results = await Promise.all(
      registry.map(async (cfg) => {
        try {
          const ready = await this.ensureServer(cfg, env, signal);
          return ready.tools;
        } catch (err) {
          console.warn(`[mcp] ${cfg.name} listTools failed:`, errorMessage(err));
          return [] as ChatCompletionTool[];
        }
      }),
    );
    return results.flat();
  }

  /** True iff this tool name routes to an MCP upstream owned by this manager. */
  owns(toolName: string): boolean {
    return this.toolToServer.has(toolName);
  }

  /**
   * Invokes an MCP tool and records the call against the per-turn meter.
   * Returns the upstream tool's text payload (flattened from content[]),
   * which the caller treats as opaque (typically JSON the model will
   * read).  Throws on transport / RPC failure; the bot-reply loop's
   * own try/catch turns that into a tool_result error envelope.
   */
  async callTool(
    name: string,
    args: Record<string, unknown>,
    opts: { env: Env; meter: WebToolMeter; signal?: AbortSignal },
  ): Promise<{ text: string; isError: boolean }> {
    const billing = TOOL_BILLING[name];
    if (!billing) {
      throw new Error(`mcp: tool not registered for billing: ${name}`);
    }
    const serverName = this.toolToServer.get(name);
    if (!serverName) {
      // Tool was advertised earlier but the routing map got cleared
      // (registry refreshed, server disabled). Force a re-connect of
      // whichever server still owns this billing entry.
      throw new Error(`mcp: no server currently owns tool ${name}`);
    }
    const registry = await loadServerRegistry(opts.env);
    const cfg = registry.find((s) => s.name === serverName);
    if (!cfg) {
      throw new Error(`mcp: server ${serverName} no longer enabled`);
    }
    const target = pickMeterTarget(args);
    const startedAt = Date.now();
    try {
      const ready = await this.ensureServer(cfg, opts.env, opts.signal);
      const res = await ready.client.callTool(
        { name, arguments: args },
        undefined,
        opts.signal ? { signal: opts.signal } : undefined,
      );
      const text = flattenContentText(res);
      const isError = !!res.isError;
      opts.meter.record({
        provider: billing.provider,
        kind: billing.kind,
        target,
        status: isError ? 'error' : 'success',
        errorClass: isError ? 'tool_isError' : null,
        latencyMs: Date.now() - startedAt,
        resultCount: billing.kind === 'search' ? countExaResults(text) : undefined,
      });
      return { text, isError };
    } catch (err) {
      opts.meter.record({
        provider: billing.provider,
        kind: billing.kind,
        target,
        status: 'error',
        errorClass: errorClassOf(err),
        latencyMs: Date.now() - startedAt,
      });
      throw err;
    }
  }

  private async ensureServer(
    cfg: McpServerConfig,
    env: Env,
    signal?: AbortSignal,
  ): Promise<ReadyState> {
    const state = this.servers.get(cfg.name) ?? { stage: 'idle' };
    if (state.stage === 'ready') return state;
    if (state.stage === 'connecting') return await state.promise;

    const promise = this.connectServer(cfg, env, signal);
    this.servers.set(cfg.name, { stage: 'connecting', promise });
    try {
      const ready = await promise;
      this.servers.set(cfg.name, ready);
      for (const n of ready.toolNames) this.toolToServer.set(n, cfg.name);
      return ready;
    } catch (err) {
      this.servers.set(cfg.name, { stage: 'idle' });
      throw err;
    }
  }

  private async connectServer(
    cfg: McpServerConfig,
    env: Env,
    signal?: AbortSignal,
  ): Promise<ReadyState> {
    if (cfg.transport !== 'http') {
      throw new Error(`mcp: transport ${cfg.transport} not implemented`);
    }
    const headers = resolveAuthHeaders(env, cfg);
    if (cfg.auth_kind === 'header' && !headers) {
      throw new Error(`mcp: ${cfg.name} secret ${cfg.secret_ref} missing or empty`);
    }
    const transport = new StreamableHTTPClientTransport(new URL(cfg.url), {
      requestInit: headers ? { headers } : undefined,
    });
    const client = new Client(
      { name: 'pendingbot-edge', version: '0.1.0' },
      { capabilities: {} },
    );
    await client.connect(transport);
    const listed = await client.listTools(undefined, signal ? { signal } : undefined);
    const tools = listed.tools
      .filter((t) => TOOL_BILLING[t.name])
      .map<ChatCompletionTool>((t) => ({
        type: 'function',
        function: {
          name: t.name,
          description: t.description ?? '',
          parameters: t.inputSchema as Record<string, unknown>,
        },
      }));
    const toolNames = new Set(tools.map((t) => t.function.name));
    return { stage: 'ready', client, tools, toolNames };
  }
}

// Per-isolate singleton. Lazy init — first call to getAITools/callTool
// drives the upstream handshake.
export const mcpClient = new McpClientManager();

// ── helpers ─────────────────────────────────────────────────────────

function flattenContentText(
  res: Awaited<ReturnType<Client['callTool']>>,
): string {
  const content = (res as { content?: Array<{ type?: string; text?: string }> }).content;
  if (!Array.isArray(content)) return '';
  const parts: string[] = [];
  for (const c of content) {
    if (c && c.type === 'text' && typeof c.text === 'string') parts.push(c.text);
  }
  return parts.join('\n');
}

function pickMeterTarget(args: Record<string, unknown>): string {
  // Exa tools use `query` (search) or `url` (fetch).
  const q = args.query ?? args.url ?? '';
  return typeof q === 'string' ? q : JSON.stringify(q);
}

function countExaResults(text: string): number | undefined {
  if (!text) return undefined;
  try {
    const json = JSON.parse(text) as { results?: unknown[] };
    return Array.isArray(json.results) ? json.results.length : undefined;
  } catch {
    return undefined;
  }
}

function errorMessage(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}

function errorClassOf(err: unknown): string {
  if (err instanceof Error) return err.name || 'Error';
  return 'unknown';
}
