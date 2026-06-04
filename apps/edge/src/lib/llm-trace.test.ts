import { beforeEach, describe, expect, it, vi } from 'vitest';

// Mock the langfuse SDK before importing the helper so `new Langfuse(...)`
// returns our spy — no network, no real ingestion.
const generationMock = vi.fn();
const traceMock = vi.fn(() => ({ generation: generationMock }));
const flushAsyncMock = vi.fn(async () => {});
const ctorMock = vi.fn();
vi.mock('langfuse', () => ({
  Langfuse: class {
    constructor(...args: unknown[]) {
      ctorMock(...args);
    }
    trace = traceMock;
    flushAsync = flushAsyncMock;
  },
}));

import { traceGeneration } from './llm-trace';
import type { Env } from '../types';

const args = {
  name: 'chat_reply',
  model: 'gpt-4o',
  input: 'hi',
  output: 'hello',
  usage: { input: 3, output: 5, total: 8 },
  userId: 'user-1',
};

beforeEach(() => {
  ctorMock.mockClear();
  traceMock.mockClear();
  generationMock.mockClear();
  flushAsyncMock.mockClear();
});

describe('llm-trace traceGeneration()', () => {
  it('is a no-op when LANGFUSE_PUBLIC_KEY is missing', async () => {
    const env = { LANGFUSE_SECRET_KEY: 'sk' } as Env;

    await traceGeneration(env, args);

    expect(ctorMock).not.toHaveBeenCalled();
    expect(traceMock).not.toHaveBeenCalled();
  });

  it('is a no-op when LANGFUSE_SECRET_KEY is missing', async () => {
    const env = { LANGFUSE_PUBLIC_KEY: 'pk' } as Env;

    await traceGeneration(env, args);

    expect(ctorMock).not.toHaveBeenCalled();
    expect(traceMock).not.toHaveBeenCalled();
  });

  it('records a trace + generation and flushes when both keys are set', async () => {
    const env = {
      LANGFUSE_ENABLED: 'true',
      LANGFUSE_PUBLIC_KEY: 'pk',
      LANGFUSE_SECRET_KEY: 'sk',
      LANGFUSE_BASE_URL: 'https://lf.example.com',
    } as Env;

    await traceGeneration(env, args);

    expect(ctorMock).toHaveBeenCalledWith(
      expect.objectContaining({
        publicKey: 'pk',
        secretKey: 'sk',
        baseUrl: 'https://lf.example.com',
      }),
    );
    expect(traceMock).toHaveBeenCalledWith(
      expect.objectContaining({ name: 'chat_reply', userId: 'user-1' }),
    );
    expect(generationMock).toHaveBeenCalledWith(
      expect.objectContaining({ name: 'chat_reply', model: 'gpt-4o', usage: { input: 3, output: 5, total: 8 } }),
    );
    expect(flushAsyncMock).toHaveBeenCalled();
  });
});
