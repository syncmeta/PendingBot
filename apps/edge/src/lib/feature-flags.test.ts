import { describe, it, expect } from 'vitest';
import { billingEnabled, observabilityEnabled } from './feature-flags';
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

  describe('observabilityEnabled', () => {
    it('is off when unset (default)', () => {
      expect(observabilityEnabled(env({}))).toBe(false);
    });
    it('is on only for the exact string "true"', () => {
      expect(observabilityEnabled(env({ OBSERVABILITY_ENABLED: 'true' }))).toBe(true);
    });
    it('treats other truthy-ish strings as off (fail-safe)', () => {
      for (const v of ['1', 'TRUE', 'yes', 'on', '', 'false']) {
        expect(observabilityEnabled(env({ OBSERVABILITY_ENABLED: v }))).toBe(false);
      }
    });
  });
});
