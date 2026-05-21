import { describe, expect, it } from 'vitest';
import type {
  ChatCompletionMessageParam,
  ChatCompletionTool,
} from 'openai/resources/chat/completions';
import { toAnthropicRequest } from './anthropic-adapter';

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
