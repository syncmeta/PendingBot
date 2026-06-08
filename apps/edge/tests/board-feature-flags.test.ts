import { afterEach, describe, expect, it } from 'vitest';
import {
  billingEnabled,
  posthogEnabled,
  __resetFlagCacheForTest,
} from '../src/lib/feature-flags';
import type { Env } from '../src/types';

afterEach(() => __resetFlagCacheForTest());

// Minimal env: env defaults + a controllable MEMORY KV.
function envWith(opts: {
  billingEnv?: string;
  kv?: Record<string, unknown>;
  kvThrows?: boolean;
}): Env {
  const store = opts.kv ?? {};
  return {
    BILLING_ENABLED: opts.billingEnv,
    POSTHOG_ENABLED: undefined,
    LANGFUSE_ENABLED: undefined,
    MEMORY: {
      get: async (key: string, _type?: string) => {
        if (opts.kvThrows) throw new Error('kv down');
        return store[key] ?? null;
      },
      put: async () => {},
    },
  } as unknown as Env;
}

describe('feature flag: KV override ?? env default', () => {
  it('uses env default when no KV override', async () => {
    const env = envWith({ billingEnv: 'true', kv: {} });
    expect(await billingEnabled(env, 1)).toBe(true);
  });

  it('KV override wins over env default', async () => {
    const env = envWith({ billingEnv: 'true', kv: { 'cfg:feature-flags': { billing: false } } });
    expect(await billingEnabled(env, 1)).toBe(false); // override false beats env true
  });

  it('falls back to env when KV read throws (never blocks)', async () => {
    const env = envWith({ billingEnv: 'true', kvThrows: true });
    expect(await billingEnabled(env, 1)).toBe(true); // KV down → env true
    expect(await posthogEnabled(env, 1)).toBe(false); // env undefined → false
  });
});
