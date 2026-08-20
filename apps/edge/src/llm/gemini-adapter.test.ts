import { afterEach, describe, expect, it, vi } from 'vitest';
import type {
  ChatCompletionMessageParam,
  ChatCompletionTool,
} from 'openai/resources/chat/completions';
import type { LlmStreamChunk } from './responses-adapter';
import { openGeminiStream, toGeminiRequest } from './gemini-adapter';

const NO_TOOLS: ChatCompletionTool[] = [];
const MSGS = [{ role: 'user', content: 'hi' }] as unknown as ChatCompletionMessageParam[];

const FN_TOOL: ChatCompletionTool[] = [
  {
    type: 'function',
    function: { name: 'noop', parameters: { type: 'object', properties: {} } },
  },
];

describe('toGeminiRequest google_search', () => {
  it('attaches no search tool when webSearch is false/undefined', () => {
    expect(toGeminiRequest(MSGS, NO_TOOLS).tools).toBeUndefined();
    expect(toGeminiRequest(MSGS, NO_TOOLS, false).tools).toBeUndefined();
  });

  it('attaches google_search as its own tools entry when enabled', () => {
    const req = toGeminiRequest(MSGS, NO_TOOLS, true);
    expect(req.tools).toEqual([{ google_search: {} }]);
  });

  it('keeps google_search alongside function declarations', () => {
    const req = toGeminiRequest(MSGS, FN_TOOL, true);
    expect(req.tools).toHaveLength(2);
    expect(req.tools?.[0]).toHaveProperty('functionDeclarations');
    expect(req.tools?.[1]).toEqual({ google_search: {} });
  });
});

describe('openGeminiStream grounding parsing', () => {
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

  it('surfaces webSearchQueries + groundingChunks as a search chip + citations', async () => {
    stubFetch({
      candidates: [
        {
          content: { parts: [{ text: 'The answer.' }] },
          groundingMetadata: {
            webSearchQueries: ['tokyo weather', 'tokyo forecast'],
            groundingChunks: [
              { web: { uri: 'https://a.jp', title: 'A' } },
              { web: { uri: 'https://b.jp', title: 'B' } },
            ],
          },
        },
      ],
      usageMetadata: { promptTokenCount: 12, candidatesTokenCount: 8 },
    });
    const stream = await openGeminiStream(
      'https://gw',
      'tok',
      { model: 'gemini-2.5-flash', messages: [], tools: [], webSearch: true },
      new AbortController().signal,
    );
    const chunks = await collect(stream);
    expect(chunks).toContainEqual({
      builtinTool: { kind: 'web_search', phase: 'started', query: 'tokyo weather / tokyo forecast' },
    });
    expect(chunks).toContainEqual({ builtinTool: { kind: 'web_search', phase: 'completed' } });
    expect(chunks).toContainEqual({
      citations: [
        { url: 'https://a.jp', title: 'A' },
        { url: 'https://b.jp', title: 'B' },
      ],
    });
    expect(chunks).toContainEqual({ choices: [{ delta: { content: 'The answer.' } }] });
  });

  it('emits no search chip when groundingMetadata is absent', async () => {
    stubFetch({
      candidates: [{ content: { parts: [{ text: 'plain' }] } }],
      usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1 },
    });
    const stream = await openGeminiStream(
      'https://gw',
      'tok',
      { model: 'gemini-2.5-flash', messages: [], tools: [], webSearch: true },
      new AbortController().signal,
    );
    const chunks = await collect(stream);
    expect(chunks.some((c) => c.builtinTool)).toBe(false);
    expect(chunks.some((c) => c.citations)).toBe(false);
  });

  it('retries search-only when a model rejects google_search plus function declarations', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            error: {
              status: 'INVALID_ARGUMENT',
              message: 'google_search with functionDeclarations is not supported',
            },
          }),
          { status: 400 },
        ),
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            candidates: [{ content: { parts: [{ text: 'searched answer' }] } }],
            usageMetadata: { promptTokenCount: 3, candidatesTokenCount: 2 },
          }),
          { status: 200 },
        ),
      );
    vi.stubGlobal('fetch', fetchMock);

    const stream = await openGeminiStream(
      'https://gw',
      'tok',
      { model: 'gemini-old', messages: MSGS, tools: FN_TOOL, webSearch: true },
      new AbortController().signal,
    );
    const chunks = await collect(stream);
    const firstBody = JSON.parse(fetchMock.mock.calls[0]?.[1]?.body as string);
    const retryBody = JSON.parse(fetchMock.mock.calls[1]?.[1]?.body as string);

    expect(firstBody.tools).toHaveLength(2);
    expect(retryBody.tools).toEqual([{ google_search: {} }]);
    expect(chunks).toContainEqual({ choices: [{ delta: { content: 'searched answer' } }] });
  });
});
