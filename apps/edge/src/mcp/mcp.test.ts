import { describe, expect, it } from 'vitest';
import { mcpClient } from './client';

// Phase 1 smoke test: prove the InMemoryTransport pair between
// internalMcpServer and the loop's Client roundtrips a real tool call,
// and that PendingBot's per-call context survives the _meta hop.

const CTX = { userId: 'user_test', conversationId: 'conv_test' };

describe('mcp transport roundtrip', () => {
  it('lists the ping tool as an OpenAI tool', async () => {
    const tools = await mcpClient.getAITools(CTX);
    const ping = tools.find((t) => t.function.name === 'ping');
    expect(ping).toBeDefined();
    expect(ping?.type).toBe('function');
    expect(ping?.function.description).toMatch(/health/i);
    expect(ping?.function.parameters).toMatchObject({ type: 'object' });
  });

  it('callTool returns content envelope with ctx echoed via _meta', async () => {
    const res = await mcpClient.callTool('ping', { message: 'hello' }, CTX);
    expect(res.isError).toBeFalsy();
    const content = res.content as Array<{ type: string; text: string }>;
    expect(content[0]?.type).toBe('text');
    expect(content[0]?.text).toBe('pong: hello (user=user_test)');
  });

  it('callTool works without message arg', async () => {
    const res = await mcpClient.callTool('ping', {}, CTX);
    const content = res.content as Array<{ type: string; text: string }>;
    expect(content[0]?.text).toBe('pong:  (user=user_test)');
  });
});
