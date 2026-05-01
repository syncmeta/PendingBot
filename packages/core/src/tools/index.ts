// Tools registry — bot-callable functions.
//
// A Tool is a callable with:
//   - identity (name, description, optional version)
//   - input schema (Zod) for type safety + JSON-schema export to LLM tool calls
//   - execute(ctx, args) returning JSON-serializable result
//
// Sources of tools (B0 only defines the interface):
//   builtin   — TS functions in this package or product code
//   mcp       — bridge to a Model Context Protocol server (future)
//   custom    — user-defined Skills can compose existing tools
//
// LLMs see tools through the ToolDefinition.toJSON() (OpenAI function-calling
// or Anthropic tool-use shape, depending on caller).

export * from './types';
