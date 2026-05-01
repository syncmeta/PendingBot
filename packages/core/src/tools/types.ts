import type { z } from 'zod';

// Generic context passed to every tool. Products extend this with their own
// (env, db client, current user, etc.) — Tool<TCtx, ...> is generic over it.
export interface ToolContext {
  userId: string;
  conversationId: string;
}

// Result shape — JSON-serializable, exactly what gets handed back to the LLM
// as the tool-result message. Consumers shape `data` as they please.
export interface ToolResult<TData = unknown> {
  ok: boolean;
  data?: TData;
  error?: string;
}

// The thing you implement when adding a new tool.
export interface Tool<TCtx extends ToolContext = ToolContext, TInput = unknown, TOutput = unknown> {
  readonly name: string;
  readonly description: string;
  readonly version?: string;
  readonly inputSchema: z.ZodType<TInput>;
  execute(ctx: TCtx, args: TInput): Promise<ToolResult<TOutput>>;
}

// A registry is just a name → Tool map. Helper functions build/lookup.
export type ToolRegistry<TCtx extends ToolContext = ToolContext> = Map<string, Tool<TCtx>>;

export function makeRegistry<TCtx extends ToolContext>(
  tools: Tool<TCtx>[],
): ToolRegistry<TCtx> {
  return new Map(tools.map(t => [t.name, t]));
}
