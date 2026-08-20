import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Env } from '../types';

// Control Langfuse responses by mocking the singleton client accessor.
const { getPromptMock } = vi.hoisted(() => ({ getPromptMock: vi.fn() }));
vi.mock('../lib/langfuse-client', () => ({
  getLangfuseClient: () => ({ getPrompt: getPromptMock }),
}));

import {
  ensurePromptOverridesLoaded,
  getPrompt,
  getPromptMeta,
  invalidatePromptCache,
} from './prompt-loader';

function fakeKV(seed: Record<string, string> = {}) {
  const store = new Map<string, string>(Object.entries(seed));
  return {
    store,
    get: vi.fn(async (k: string) => store.get(k) ?? null),
    put: vi.fn(async (k: string, v: string) => {
      store.set(k, v);
    }),
  };
}

function envWith(kv: ReturnType<typeof fakeKV>): Env {
  return {
    PROMPTS_KV: kv,
    LANGFUSE_PUBLIC_KEY: 'pk',
    LANGFUSE_SECRET_KEY: 'sk',
  } as unknown as Env;
}

beforeEach(() => {
  invalidatePromptCache();
  getPromptMock.mockReset();
});

describe('prompt-loader', () => {
  it('serves a KV hit without pulling that prompt from Langfuse', async () => {
    const kv = fakeKV({ 'prompt:system/zh': JSON.stringify({ body: 'kv-system', version: 3 }) });
    getPromptMock.mockRejectedValue(new Error('not found')); // everything else missing
    await ensurePromptOverridesLoaded(envWith(kv));

    expect(getPrompt('system')).toBe('kv-system');
    expect(getPromptMeta('system')).toEqual({ name: 'system/zh', version: 3 });
    // system came from KV, so Langfuse was never asked for it
    expect(getPromptMock).not.toHaveBeenCalledWith('system/zh', undefined, expect.anything());
  });

  it('pulls from Langfuse on KV miss and writes the result back to KV', async () => {
    const kv = fakeKV();
    getPromptMock.mockImplementation(async (name: string) => {
      if (name === 'title/zh') return { prompt: 'lf-title', version: 5 };
      throw new Error('not found');
    });
    await ensurePromptOverridesLoaded(envWith(kv));

    expect(getPrompt('title')).toBe('lf-title');
    expect(getPromptMeta('title')).toEqual({ name: 'title/zh', version: 5 });
    expect(kv.put).toHaveBeenCalledWith(
      'prompt:title/zh',
      JSON.stringify({ body: 'lf-title', version: 5 }),
    );
  });

  it('throws (fail loud) when a prompt is in neither KV nor Langfuse', async () => {
    const kv = fakeKV();
    getPromptMock.mockRejectedValue(new Error('not found'));
    await ensurePromptOverridesLoaded(envWith(kv));

    expect(() => getPrompt('voice')).toThrow(/prompt unavailable/);
  });

  it('falls back to the default-locale version when a locale variant is absent', async () => {
    const kv = fakeKV({
      'prompt:session-world-model/zh': JSON.stringify({ body: 'zh-swm', version: 1 }),
    });
    getPromptMock.mockRejectedValue(new Error('not found')); // no en variant anywhere
    await ensurePromptOverridesLoaded(envWith(kv));

    // en requested, en absent → zh fallback
    expect(getPrompt('session-world-model', 'en')).toBe('zh-swm');
  });
});
