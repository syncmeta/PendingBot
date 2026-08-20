import { afterEach, describe, expect, it, vi } from 'vitest';
import type {
  ChatCompletionMessageParam,
  ChatCompletionTool,
} from 'openai/resources/chat/completions';
import type { LlmStreamChunk } from './responses-adapter';
import { openAnthropicStream, toAnthropicRequest } from './anthropic-adapter';

// The builder attaches cache_control to text blocks via withCacheControl.
// The OpenAI ContentPart type doesn't model it, so the builder casts; mirror
// that here with a small helper that produces the same shape.
function cached(text: string) {
  return [{ type: 'text', text, cache_control: { type: 'ephemeral' } }];
}

const NO_TOOLS: ChatCompletionTool[] = [];

describe('toAnthropicRequest cache_control', () => {
  it('preserves the cache breakpoint on the system prefix', () => {
    const messages = [
      { role: 'system', content: cached('stable persona') },
      { role: 'user', content: 'hi' },
    ] as unknown as ChatCompletionMessageParam[];

    const req = toAnthropicRequest('claude-sonnet-4-6', messages, NO_TOOLS);

    expect(Array.isArray(req.system)).toBe(true);
    expect(req.system).toEqual([
      { type: 'text', text: 'stable persona', cache_control: { type: 'ephemeral' } },
    ]);
  });

  it('preserves the cache breakpoint on a history message', () => {
    const messages = [
      { role: 'system', content: cached('persona') },
      { role: 'user', content: cached('older turn') },
      { role: 'assistant', content: 'reply' },
      { role: 'user', content: 'newest turn' },
    ] as unknown as ChatCompletionMessageParam[];

    const req = toAnthropicRequest('claude-sonnet-4-6', messages, NO_TOOLS);

    const firstUser = req.messages[0];
    expect(firstUser.role).toBe('user');
    expect(firstUser.content[0]).toEqual({
      type: 'text',
      text: 'older turn',
      cache_control: { type: 'ephemeral' },
    });
    // A plain (uncached) turn carries no cache_control.
    const newest = req.messages.at(-1);
    expect(newest?.content[0]).toEqual({ type: 'text', text: 'newest turn' });
  });

  it('leaves plain string content uncached', () => {
    const messages = [
      { role: 'system', content: 'plain system' },
      { role: 'user', content: 'hi' },
    ] as unknown as ChatCompletionMessageParam[];

    const req = toAnthropicRequest('claude-sonnet-4-6', messages, NO_TOOLS);

    expect(req.system).toEqual([{ type: 'text', text: 'plain system' }]);
  });
});

describe('toAnthropicRequest web search', () => {
  const msgs = [{ role: 'user', content: 'hi' }] as unknown as ChatCompletionMessageParam[];

  it('attaches no web_search tool when webSearch is null', () => {
    const req = toAnthropicRequest('claude-sonnet-4-6', msgs, NO_TOOLS, null);
    expect(req.tools).toBeUndefined();
  });

  it('attaches the server web_search tool when enabled', () => {
    const req = toAnthropicRequest('claude-sonnet-4-6', msgs, NO_TOOLS, {});
    expect(req.tools).toEqual([
      { type: 'web_search_20250305', name: 'web_search', max_uses: 5 },
    ]);
  });

  it('maps allowedDomains to allowed_domains', () => {
    const req = toAnthropicRequest('claude-sonnet-4-6', msgs, NO_TOOLS, {
      allowedDomains: ['example.com'],
    });
    expect(req.tools?.[0]).toMatchObject({ allowed_domains: ['example.com'] });
  });

  it('maps excludedDomains to blocked_domains (allowed takes precedence)', () => {
    const blockedOnly = toAnthropicRequest('claude-sonnet-4-6', msgs, NO_TOOLS, {
      excludedDomains: ['spam.com'],
    });
    expect(blockedOnly.tools?.[0]).toMatchObject({ blocked_domains: ['spam.com'] });

    const both = toAnthropicRequest('claude-sonnet-4-6', msgs, NO_TOOLS, {
      allowedDomains: ['ok.com'],
      excludedDomains: ['spam.com'],
    });
    expect(both.tools?.[0]).toMatchObject({ allowed_domains: ['ok.com'] });
    expect(both.tools?.[0]).not.toHaveProperty('blocked_domains');
  });
});

describe('openAnthropicStream web search parsing', () => {
  afterEach(() => vi.unstubAllGlobals());

  function stubFetch(body: unknown) {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response(JSON.stringify(body), { status: 200 })),
    );
  }

  async function collect(stream: AsyncIterable<LlmStreamChunk>): Promise<LlmStreamChunk[]> {
    const out: LlmStreamChunk[] = [];
    for await (const c of stream) out.push(c);
    return out;
  }

  it('emits the query, completion, and citations from search blocks', async () => {
    stubFetch({
      content: [
        { type: 'server_tool_use', id: 'srvtoolu_1', name: 'web_search', input: { query: 'cf workers' } },
        {
          type: 'web_search_tool_result',
          tool_use_id: 'srvtoolu_1',
          content: [
            { type: 'web_search_result', url: 'https://x.com', title: 'X', page_age: '1d' },
            { type: 'web_search_result', url: 'https://y.com', title: 'Y' },
          ],
        },
        { type: 'text', text: 'Here is the answer.' },
      ],
      usage: { input_tokens: 10, output_tokens: 5 },
    });
    const stream = await openAnthropicStream(
      'https://gw',
      'tok',
      { model: 'claude-sonnet-4-6', messages: [], tools: [], webSearch: {} },
      new AbortController().signal,
    );
    const chunks = await collect(stream);
    expect(chunks).toContainEqual({
      builtinTool: { kind: 'web_search', phase: 'started', query: 'cf workers' },
    });
    expect(chunks).toContainEqual({ builtinTool: { kind: 'web_search', phase: 'completed' } });
    expect(chunks).toContainEqual({
      citations: [
        { url: 'https://x.com', title: 'X' },
        { url: 'https://y.com', title: 'Y' },
      ],
    });
    expect(chunks).toContainEqual({ choices: [{ delta: { content: 'Here is the answer.' } }] });
  });

  it('skips citations when the search returns an error object', async () => {
    stubFetch({
      content: [
        { type: 'server_tool_use', id: 's1', name: 'web_search', input: { query: 'x' } },
        {
          type: 'web_search_tool_result',
          tool_use_id: 's1',
          content: { type: 'web_search_tool_result_error', error_code: 'max_uses_exceeded' },
        },
      ],
    });
    const stream = await openAnthropicStream(
      'https://gw',
      'tok',
      { model: 'claude-sonnet-4-6', messages: [], tools: [], webSearch: {} },
      new AbortController().signal,
    );
    const chunks = await collect(stream);
    expect(chunks).toContainEqual({ builtinTool: { kind: 'web_search', phase: 'completed' } });
    expect(chunks.some((c) => c.citations)).toBe(false);
  });
});
