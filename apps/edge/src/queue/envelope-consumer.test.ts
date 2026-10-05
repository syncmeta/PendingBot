import { describe, expect, it, vi } from 'vitest';
import { consumeEnvelopeBatch } from './envelope-consumer';
import type { EnvelopeMessage } from './envelope-types';
import type { Env } from '../types';

function msg(body: EnvelopeMessage) {
  return { body, ack: vi.fn(), retry: vi.fn() };
}

const body: EnvelopeMessage = {
  envelopeRunId: 'run-1',
  conversationId: 'conv-1',
  userId: 'user-1',
  botId: 'bot-1',
  settings: { turnCap: 15 } as EnvelopeMessage['settings'],
};

describe('consumeEnvelopeBatch', () => {
  it('runs the envelope with the consumer env and acks', async () => {
    const env = {} as Env;
    const m = msg(body);
    const run = vi.fn().mockResolvedValue(undefined);
    await consumeEnvelopeBatch({ messages: [m] } as never, env, run);
    expect(run).toHaveBeenCalledWith({ env, ...body });
    expect(m.ack).toHaveBeenCalled();
    expect(m.retry).not.toHaveBeenCalled();
  });

  it('acks instead of retrying when the run throws', async () => {
    const m = msg(body);
    const run = vi.fn().mockRejectedValue(new Error('boom'));
    vi.spyOn(console, 'error').mockImplementation(() => {});
    await consumeEnvelopeBatch({ messages: [m] } as never, {} as Env, run);
    expect(m.ack).toHaveBeenCalled();
    expect(m.retry).not.toHaveBeenCalled();
  });
});
