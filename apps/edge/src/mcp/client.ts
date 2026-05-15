// MCP client manager — per-isolate singleton that owns connections to
// upstream MCP servers and exposes their tools to the bot-reply loop.
//
// Current scope (v1): Exa hosted MCP (https://mcp.exa.ai/mcp). Tavily
// will be plumbed via the future skill mechanism, not the default tool
// surface.
//
// The model receives Exa tools under their vendor-native names
// (web_search_exa, web_fetch_exa) with vendor descriptions — no
// PendingBot rewrapping. bot-reply consumes the tool result envelope
// and decides whether to extract citations etc.

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import type { ChatCompletionTool } from 'openai/resources/chat/completions';
import type { Env } from '../types';
import { WebToolMeter, type WebToolProvider, type WebToolKind } from '../lib/web-meter';

// Vendor MCP tool name → billing dimensions for WebToolMeter. New entries
// here are the only thing required to bill a new tool through the price
// book in `web_tool_prices`.
const TOOL_BILLING: Record<string, { provider: WebToolProvider; kind: WebToolKind } | undefined> = {
  web_search_exa: { provider: 'exa', kind: 'search' },
  web_fetch_exa: { provider: 'exa', kind: 'scrape' },
};

const EXA_MCP_URL = 'https://mcp.exa.ai/mcp';

type ExaConnState =
  | { stage: 'idle' }
  | { stage: 'connecting'; promise: Promise<ExaReadyState> }
  | ExaReadyState;

type ExaReadyState = { stage: 'ready'; client: Client; tools: ChatCompletionTool[] };

// Manager.  One instance per worker isolate (see module-bottom export).
class McpClientManager {
  private exa: ExaConnState = { stage: 'idle' };
  /** Names exposed to the model. Built once on first listTools. */
  private exaToolNames = new Set<string>();

  /**
   * Returns the OpenAI-shaped tool list to merge into the model's `tools`
   * array. Failures (missing key, upstream down) degrade to empty list —
   * the bot still works with internal tools alone.
   */
  async getAITools(env: Env, signal?: AbortSignal): Promise<ChatCompletionTool[]> {
    if (!env.EXA_API_KEY) return [];
    try {
      const ready = await this.ensureExa(env, signal);
      return ready.tools;
    } catch (err) {
      console.warn('[mcp] exa listTools failed:', errorMessage(err));
      return [];
    }
  }

  /** True iff this tool name routes to an MCP upstream owned by this manager. */
  owns(toolName: string): boolean {
    return this.exaToolNames.has(toolName);
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
    const target = pickMeterTarget(args);
    const startedAt = Date.now();
    try {
      const ready = await this.ensureExa(opts.env, opts.signal);
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

  private async ensureExa(env: Env, signal?: AbortSignal): Promise<ExaReadyState> {
    if (this.exa.stage === 'ready') return this.exa;
    if (this.exa.stage === 'connecting') return await this.exa.promise;
    const promise = this.connectExa(env, signal);
    this.exa = { stage: 'connecting', promise };
    try {
      const ready = await promise;
      this.exa = ready;
      return ready;
    } catch (err) {
      this.exa = { stage: 'idle' };
      throw err;
    }
  }

  private async connectExa(env: Env, signal?: AbortSignal): Promise<ExaReadyState> {
    if (!env.EXA_API_KEY) throw new Error('EXA_API_KEY missing');
    const transport = new StreamableHTTPClientTransport(new URL(EXA_MCP_URL), {
      requestInit: { headers: { 'x-api-key': env.EXA_API_KEY } },
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
    this.exaToolNames = new Set(tools.map((t) => t.function.name));
    return { stage: 'ready', client, tools };
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
