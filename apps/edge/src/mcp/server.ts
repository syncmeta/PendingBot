import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type CallToolResult,
  type Tool,
} from '@modelcontextprotocol/sdk/types.js';
import { metaToContext, type McpContext } from './context';

// Low-level handler for one tool. The MCP `_meta` on the call request is
// surfaced as a typed McpContext (PendingBot's per-turn identity).
export type ToolHandler = (
  args: Record<string, unknown>,
  ctx: McpContext | undefined,
) => CallToolResult | Promise<CallToolResult>;

// Plain object table: tool name → { metadata for tools/list, handler for tools/call }.
// Phase 2/3 add to this; the low-level Server then dispatches into it.
//
// We use the low-level Server (not McpServer) because the high-level
// registerTool/tool generics route through a v3+v4 zod-compat union that
// blows past TS's type instantiation budget. Plain JSON-schema definitions
// here sidestep that entirely and give us a uniform shape regardless of
// whether the tool's source is internal or a third-party MCP we re-expose.
type ToolEntry = { tool: Tool; handler: ToolHandler };
const registry = new Map<string, ToolEntry>();

export function registerTool(tool: Tool, handler: ToolHandler): void {
  if (registry.has(tool.name)) {
    throw new Error(`mcp: duplicate tool registration: ${tool.name}`);
  }
  registry.set(tool.name, { tool, handler });
}

// Module-scoped singleton internal MCP server. mcp/client.ts pairs this
// with an InMemoryTransport so the bot-reply loop reaches it through the
// same MCP interface used for external (Tavily, Exa) servers.
export const internalMcpServer = new Server(
  { name: 'pendingbot-internal', version: '0.1.0' },
  { capabilities: { tools: {} } },
);

internalMcpServer.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [...registry.values()].map((e) => e.tool),
}));

internalMcpServer.setRequestHandler(CallToolRequestSchema, async (req, extra) => {
  const entry = registry.get(req.params.name);
  if (!entry) {
    return {
      isError: true,
      content: [{ type: 'text', text: `unknown tool: ${req.params.name}` }],
    };
  }
  const ctx = metaToContext(extra._meta);
  return await entry.handler(req.params.arguments ?? {}, ctx);
});

// Health-check tool to validate the transport roundtrip. Kept here (not
// in a Phase 2/3 file) because it has no real backend; just exercises the
// in-memory pair.
registerTool(
  {
    name: 'ping',
    description: 'Health-check tool used by tests to validate the MCP transport roundtrip.',
    inputSchema: {
      type: 'object',
      properties: { message: { type: 'string' } },
    },
  },
  async (args, ctx) => {
    const message = typeof args.message === 'string' ? args.message : '';
    const suffix = ctx ? ` (user=${ctx.userId})` : '';
    return { content: [{ type: 'text', text: `pong: ${message}${suffix}` }] };
  },
);
