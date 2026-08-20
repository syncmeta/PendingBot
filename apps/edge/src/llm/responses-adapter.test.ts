import { describe, expect, it } from 'vitest';
import type OpenAI from 'openai';
import type { ChatCompletionMessageParam, ChatCompletionTool } from 'openai/resources/chat/completions';
import type { ResponseStreamEvent } from 'openai/resources/responses/responses';
import {
  chatMessagesToResponsesInput,
  chatToolsToResponsesTools,
  openResponsesStream,
  type LlmStreamChunk,
} from './responses-adapter';

describe('chatToolsToResponsesTools', () => {
  it('flattens the {type,function} shape into a flat function tool', () => {
    const tools: ChatCompletionTool[] = [
      {
        type: 'function',
        function: {
          name: 'search',
          description: 'find things',
          parameters: { type: 'object', properties: { q: { type: 'string' } } },
        },
      },
    ];
    const out = chatToolsToResponsesTools(tools);
    expect(out).toEqual([
      {
        type: 'function',
        name: 'search',
        description: 'find things',
        parameters: { type: 'object', properties: { q: { type: 'string' } } },
        strict: false,
      },
    ]);
  });

  it('defaults missing parameters to an empty schema', () => {
    const out = chatToolsToResponsesTools([
      { type: 'function', function: { name: 'noop' } },
    ]);
    expect(out[0].parameters).toEqual({});
    expect(out[0].strict).toBe(false);
  });
});

describe('chatMessagesToResponsesInput', () => {
  it('routes the system message to instructions and strips cache_control', () => {
    const messages: ChatCompletionMessageParam[] = [
      {
        role: 'system',
        // builder.ts emits the Anthropic content-block array form
        content: [
          { type: 'text', text: 'you are a bot', cache_control: { type: 'ephemeral' } },
        ] as unknown as string,
      },
      { role: 'user', content: 'hi' },
    ];
    const { instructions, input } = chatMessagesToResponsesInput(messages);
    expect(instructions).toBe('you are a bot');
    expect(input).toEqual([{ role: 'user', content: 'hi' }]);
  });

  it('maps assistant tool calls and tool results to function_call items', () => {
    const messages: ChatCompletionMessageParam[] = [
      {
        role: 'assistant',
        content: 'let me check',
        tool_calls: [
          {
            id: 'call_1',
            type: 'function',
            function: { name: 'search', arguments: '{"q":"x"}' },
          },
        ],
      },
      { role: 'tool', tool_call_id: 'call_1', content: '{"count":3}' },
    ];
    const { input } = chatMessagesToResponsesInput(messages);
    expect(input).toEqual([
      { role: 'assistant', content: 'let me check' },
      { type: 'function_call', call_id: 'call_1', name: 'search', arguments: '{"q":"x"}' },
      { type: 'function_call_output', call_id: 'call_1', output: '{"count":3}' },
    ]);
  });

  it('translates image content parts into input_image items', () => {
    const messages: ChatCompletionMessageParam[] = [
      {
        role: 'user',
        content: [
          { type: 'text', text: 'what is this' },
          { type: 'image_url', image_url: { url: 'data:image/png;base64,AAA' } },
        ],
      },
    ];
    const { input } = chatMessagesToResponsesInput(messages);
    expect(input).toEqual([
      {
        role: 'user',
        content: [
          { type: 'input_text', text: 'what is this' },
          { type: 'input_image', image_url: 'data:image/png;base64,AAA', detail: 'auto' },
        ],
      },
    ]);
  });

  it('omits an assistant message with no text but keeps its tool calls', () => {
    const messages: ChatCompletionMessageParam[] = [
      {
        role: 'assistant',
        content: null,
        tool_calls: [
          { id: 'call_9', type: 'function', function: { name: 'noop', arguments: '{}' } },
        ],
      },
    ];
    const { input } = chatMessagesToResponsesInput(messages);
    expect(input).toEqual([
      { type: 'function_call', call_id: 'call_9', name: 'noop', arguments: '{}' },
    ]);
  });
});

// Build a fake OpenAI client whose responses.create yields the given
// event sequence (or throws), so openResponsesStream can be exercised
// without a network call.
function fakeClient(
  events: ResponseStreamEvent[] | (() => never),
): OpenAI {
  return {
    responses: {
      create: async () => {
        if (typeof events === 'function') events();
        return (async function* () {
          for (const ev of events as ResponseStreamEvent[]) yield ev;
        })();
      },
    },
  } as unknown as OpenAI;
}

async function collect(stream: AsyncIterable<LlmStreamChunk>): Promise<LlmStreamChunk[]> {
  const out: LlmStreamChunk[] = [];
  for await (const c of stream) out.push(c);
  return out;
}

describe('openResponsesStream', () => {
  const baseParams = {
    model: 'gpt-5.5',
    instructions: 'sys',
    input: [],
    tools: [],
  };

  it('re-emits text deltas and the response id as chat-shaped chunks', async () => {
    const events = [
      { type: 'response.created', response: { id: 'resp_1' }, sequence_number: 0 },
      { type: 'response.output_text.delta', delta: 'hel', item_id: 'm', output_index: 0, content_index: 0, sequence_number: 1 },
      { type: 'response.output_text.delta', delta: 'lo', item_id: 'm', output_index: 0, content_index: 0, sequence_number: 2 },
    ] as unknown as ResponseStreamEvent[];
    const chunks = await collect(
      await openResponsesStream(fakeClient(events), baseParams, new AbortController().signal),
    );
    expect(chunks[0]).toEqual({ id: 'resp_1' });
    expect(chunks[1].choices?.[0]?.delta?.content).toBe('hel');
    expect(chunks[2].choices?.[0]?.delta?.content).toBe('lo');
  });

  it('bridges function-call item ids to positional tool-call indexes', async () => {
    const events = [
      {
        type: 'response.output_item.added',
        output_index: 0,
        sequence_number: 0,
        item: { type: 'function_call', id: 'fc_a', call_id: 'call_a', name: 'search', arguments: '' },
      },
      {
        type: 'response.function_call_arguments.delta',
        item_id: 'fc_a',
        output_index: 0,
        sequence_number: 1,
        delta: '{"q":',
      },
      {
        type: 'response.function_call_arguments.delta',
        item_id: 'fc_a',
        output_index: 0,
        sequence_number: 2,
        delta: '"hi"}',
      },
    ] as unknown as ResponseStreamEvent[];
    const chunks = await collect(
      await openResponsesStream(fakeClient(events), baseParams, new AbortController().signal),
    );
    const added = chunks[0].choices?.[0]?.delta?.tool_calls?.[0];
    expect(added).toEqual({ index: 0, id: 'call_a', function: { name: 'search' } });
    expect(chunks[1].choices?.[0]?.delta?.tool_calls?.[0]).toEqual({
      index: 0,
      function: { arguments: '{"q":' },
    });
    expect(chunks[2].choices?.[0]?.delta?.tool_calls?.[0]).toEqual({
      index: 0,
      function: { arguments: '"hi"}' },
    });
  });

  it('reshapes the completed usage into chat-completion usage', async () => {
    const events = [
      {
        type: 'response.completed',
        sequence_number: 0,
        response: {
          id: 'resp_1',
          usage: {
            input_tokens: 120,
            output_tokens: 30,
            total_tokens: 150,
            input_tokens_details: { cached_tokens: 100 },
            output_tokens_details: { reasoning_tokens: 0 },
          },
        },
      },
    ] as unknown as ResponseStreamEvent[];
    const chunks = await collect(
      await openResponsesStream(fakeClient(events), baseParams, new AbortController().signal),
    );
    expect(chunks[0].usage).toEqual({
      prompt_tokens: 120,
      completion_tokens: 30,
      total_tokens: 150,
      prompt_tokens_details: { cached_tokens: 100 },
    });
  });

  it('throws when the stream emits a failure event', async () => {
    const events = [
      {
        type: 'response.failed',
        sequence_number: 0,
        response: { id: 'r', error: { code: 'server_error', message: 'boom' } },
      },
    ] as unknown as ResponseStreamEvent[];
    const stream = await openResponsesStream(
      fakeClient(events),
      baseParams,
      new AbortController().signal,
    );
    await expect(collect(stream)).rejects.toThrow('boom');
  });

  it('surfaces the web_search query on the started chip', async () => {
    const events = [
      {
        type: 'response.output_item.added',
        output_index: 0,
        sequence_number: 0,
        item: { type: 'web_search_call', id: 'ws_1', status: 'in_progress', action: { type: 'search', query: 'weather tokyo' } },
      },
      { type: 'response.web_search_call.in_progress', item_id: 'ws_1', output_index: 0, sequence_number: 1 },
      { type: 'response.web_search_call.completed', item_id: 'ws_1', output_index: 0, sequence_number: 2 },
    ] as unknown as ResponseStreamEvent[];
    const chunks = await collect(
      await openResponsesStream(fakeClient(events), baseParams, new AbortController().signal),
    );
    // in_progress is swallowed; started rides on output_item.added with query.
    expect(chunks).toEqual([
      { builtinTool: { kind: 'web_search', phase: 'started', query: 'weather tokyo' } },
      { builtinTool: { kind: 'web_search', phase: 'completed' } },
    ]);
  });

  it('buffers url_citation annotations and flushes them at completion', async () => {
    const events = [
      {
        type: 'response.output_text_annotation.added',
        item_id: 'm', output_index: 0, content_index: 0, annotation_index: 0, sequence_number: 0,
        annotation: { type: 'url_citation', url: 'https://a.com', title: 'A', start_index: 0, end_index: 4 },
      },
      {
        type: 'response.output_text_annotation.added',
        item_id: 'm', output_index: 0, content_index: 0, annotation_index: 1, sequence_number: 1,
        // duplicate URL — deduped
        annotation: { type: 'url_citation', url: 'https://a.com', title: 'A again' },
      },
      {
        type: 'response.output_text_annotation.added',
        item_id: 'm', output_index: 0, content_index: 0, annotation_index: 2, sequence_number: 2,
        annotation: { type: 'url_citation', url: 'https://b.com', title: 'B' },
      },
      { type: 'response.completed', sequence_number: 3, response: { id: 'r' } },
    ] as unknown as ResponseStreamEvent[];
    const chunks = await collect(
      await openResponsesStream(fakeClient(events), baseParams, new AbortController().signal),
    );
    const cited = chunks.find((c) => c.citations);
    expect(cited?.citations).toEqual([
      { url: 'https://a.com', title: 'A' },
      { url: 'https://b.com', title: 'B' },
    ]);
  });
});
