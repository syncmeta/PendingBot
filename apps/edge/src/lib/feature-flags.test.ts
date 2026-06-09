import { afterEach, describe, it, expect } from 'vitest';
import {
  billingEnabled,
  sentryEnabled,
  posthogEnabled,
  langfuseEnabled,
  __resetFlagCacheForTest,
} from './feature-flags';
import type { Env } from '../types';

afterEach(() => __resetFlagCacheForTest());

// env override carrying a MEMORY KV that holds NO override blob, so these
// cases exercise the env-default floor (override ?? env). A fixed `now` is
// passed to the async getters to keep the cache deterministic.
const env = (over: Partial<Env>): Env =>
  ({
    ...over,
    MEMORY: { get: async () => null, put: async () => {} },
  }) as unknown as Env;

describe('feature-flags', () => {
  describe('billingEnabled', () => {
    it('is off when unset (default)', async () => {
      expect(await billingEnabled(env({}), 1)).toBe(false);
    });
    it('is on only for the exact string "true"', async () => {
      expect(await billingEnabled(env({ BILLING_ENABLED: 'true' }), 1)).toBe(true);
    });
    it('treats other truthy-ish strings as off (fail-safe)', async () => {
      for (const v of ['1', 'TRUE', 'yes', 'on', '', 'false']) {
        __resetFlagCacheForTest();
        expect(await billingEnabled(env({ BILLING_ENABLED: v }), 1)).toBe(false);
      }
    });
  });

  describe('per-service observability flags (independent)', () => {
    const cases = [
      { fn: posthogEnabled, key: 'POSTHOG_ENABLED' as const },
      { fn: langfuseEnabled, key: 'LANGFUSE_ENABLED' as const },
    ];
    for (const { fn, key } of cases) {
      describe(key, () => {
        it('is off when unset (default)', async () => {
          __resetFlagCacheForTest();
          expect(await fn(env({}), 1)).toBe(false);
        });
        it('is on only for the exact string "true"', async () => {
          __resetFlagCacheForTest();
          expect(await fn(env({ [key]: 'true' }), 1)).toBe(true);
        });
        it('treats other truthy-ish strings as off (fail-safe)', async () => {
          for (const v of ['1', 'TRUE', 'yes', 'on', '', 'false']) {
            __resetFlagCacheForTest();
            expect(await fn(env({ [key]: v }), 1)).toBe(false);
          }
        });
      });
    }

    // sentryEnabled stays synchronous env-only.
    describe('SENTRY_ENABLED (synchronous, env-only)', () => {
      it('is off when unset (default)', () => {
        expect(sentryEnabled(env({}))).toBe(false);
      });
      it('is on only for the exact string "true"', () => {
        expect(sentryEnabled(env({ SENTRY_ENABLED: 'true' }))).toBe(true);
      });
      it('treats other truthy-ish strings as off (fail-safe)', () => {
        for (const v of ['1', 'TRUE', 'yes', 'on', '', 'false']) {
          expect(sentryEnabled(env({ SENTRY_ENABLED: v }))).toBe(false);
        }
      });
    });

    it('flags are independent — enabling one does not enable the others', async () => {
      const e = env({ SENTRY_ENABLED: 'true' });
      expect(sentryEnabled(e)).toBe(true);
      expect(await posthogEnabled(e, 1)).toBe(false);
      expect(await langfuseEnabled(e, 1)).toBe(false);
    });
  });
});
