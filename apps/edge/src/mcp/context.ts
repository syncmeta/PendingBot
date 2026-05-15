// Per-call context threaded from bot-reply through MCP `_meta` into every tool handler.
// The MCP spec lets `_meta` carry arbitrary namespaced keys (see CallToolRequest.params._meta),
// so PendingBot stashes its turn-scoped identity under a single namespaced key.

export type McpContext = {
  userId: string;
  conversationId: string;
  botId?: string;
  userJwt?: string;
};

const META_KEY = 'pendingbot/ctx';

export function contextToMeta(ctx: McpContext): Record<string, unknown> {
  return { [META_KEY]: ctx };
}

export function metaToContext(meta: Record<string, unknown> | undefined): McpContext | undefined {
  if (!meta) return undefined;
  const v = meta[META_KEY];
  if (!v || typeof v !== 'object') return undefined;
  return v as McpContext;
}
