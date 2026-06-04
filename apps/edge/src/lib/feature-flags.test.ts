import { describe, it, expect } from 'vitest';
import { billingEnabled, sentryEnabled, posthogEnabled, langfuseEnabled } from './feature-flags';
import type { Env } from '../types';

const env = (over: Partial<Env>) => over as Env;

describe('feature-flags', () => {
  describe('billingEnabled', () => {
    it('is off when unset (default)', () => {
      expect(billingEnabled(env({}))).toBe(false);
    });
    it('is on only for the exact string "true"', () => {
      expect(billingEnabled(env({ BILLING_ENABLED: 'true' }))).toBe(true);
    });
    it('treats other truthy-ish strings as off (fail-safe)', () => {
      for (const v of ['1', 'TRUE', 'yes', 'on', '', 'false']) {
        expect(billingEnabled(env({ BILLING_ENABLED: v }))).toBe(false);
      }
    });
  });

  describe('per-service observability flags (independent)', () => {
    const cases = [
      { fn: sentryEnabled, key: 'SENTRY_ENABLED' as const },
      { fn: posthogEnabled, key: 'POSTHOG_ENABLED' as const },
      { fn: langfuseEnabled, key: 'LANGFUSE_ENABLED' as const },
    ];
    for (const { fn, key } of cases) {
      describe(key, () => {
        it('is off when unset (default)', () => {
          expect(fn(env({}))).toBe(false);
        });
        it('is on only for the exact string "true"', () => {
          expect(fn(env({ [key]: 'true' }))).toBe(true);
        });
        it('treats other truthy-ish strings as off (fail-safe)', () => {
          for (const v of ['1', 'TRUE', 'yes', 'on', '', 'false']) {
            expect(fn(env({ [key]: v }))).toBe(false);
          }
        });
      });
    }

    it('flags are independent — enabling one does not enable the others', () => {
      const e = env({ SENTRY_ENABLED: 'true' });
      expect(sentryEnabled(e)).toBe(true);
      expect(posthogEnabled(e)).toBe(false);
      expect(langfuseEnabled(e)).toBe(false);
    });
  });
});
