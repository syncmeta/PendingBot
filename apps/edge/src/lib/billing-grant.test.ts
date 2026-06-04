import { describe, expect, it, vi } from 'vitest';
import {
  grantSignupBonus,
  creditRedemptionToPolar,
  normalizeEmail,
  SIGNUP_BONUS_PNC,
  PND_TO_PNC_MICROS,
} from './billing-grant';
import type { Env } from '../types';
import type { SupabaseClient } from './supabase';

// A supa that throws on any use — proves the short-circuit never touches the DB.
const explodingSupa = new Proxy({}, {
  get() {
    throw new Error('supa should not be touched');
  },
}) as unknown as SupabaseClient;

describe('billing-grant', () => {
  it('exposes the locked welcome amount + PND→PNC conversion factor', () => {
    expect(SIGNUP_BONUS_PNC).toBe(35);
    expect(PND_TO_PNC_MICROS).toBe(10_000);
  });

  describe('grantSignupBonus', () => {
    it('is a no-op when billing kill-switch is off (never touches DB/Polar)', async () => {
      const env = { POLAR_ACCESS_TOKEN: 't', POLAR_PNC_METER_ID: 'm' } as Env; // BILLING off
      await expect(grantSignupBonus(env, explodingSupa, 'u1')).resolves.toBeUndefined();
    });

    it('is a no-op when Polar is unconfigured even if billing is on', async () => {
      const env = { BILLING_ENABLED: 'true' } as Env; // no POLAR_*
      await expect(grantSignupBonus(env, explodingSupa, 'u1')).resolves.toBeUndefined();
    });

    it('swallows downstream errors (best-effort, never throws into /me)', async () => {
      const env = { BILLING_ENABLED: 'true', POLAR_ACCESS_TOKEN: 't', POLAR_PNC_METER_ID: 'm' } as Env;
      const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
      // supa.from(...).select(...).eq(...)... throws → caught, logged, no throw.
      await expect(grantSignupBonus(env, explodingSupa, 'u1')).resolves.toBeUndefined();
      warn.mockRestore();
    });
  });

  describe('normalizeEmail (welcome-bonus anti-abuse, #252)', () => {
    it('lowercases and trims', () => {
      expect(normalizeEmail('  Foo@Example.COM ')).toBe('foo@example.com');
    });

    it('strips +tag sub-addressing on any domain', () => {
      expect(normalizeEmail('foo+anything@example.com')).toBe('foo@example.com');
      expect(normalizeEmail('foo+a+b@example.com')).toBe('foo@example.com');
    });

    it('collapses gmail dot + plus tricks to one identity', () => {
      const canonical = 'foobar@gmail.com';
      expect(normalizeEmail('foo.bar@gmail.com')).toBe(canonical);
      expect(normalizeEmail('f.o.o.b.a.r@gmail.com')).toBe(canonical);
      expect(normalizeEmail('foo.bar+promo@gmail.com')).toBe(canonical);
      expect(normalizeEmail('FooBar@googlemail.com')).toBe(canonical); // googlemail → gmail
    });

    it('does NOT strip dots for non-gmail domains (dots are significant there)', () => {
      expect(normalizeEmail('foo.bar@outlook.com')).toBe('foo.bar@outlook.com');
    });

    it('returns lowercased input unchanged when there is no @', () => {
      expect(normalizeEmail('notanemail')).toBe('notanemail');
    });
  });

  describe('creditRedemptionToPolar', () => {
    it('converts PND→PNC micros and skips side effects when Polar is unconfigured', async () => {
      const env = {} as Env; // polar not ready
      const micros = await creditRedemptionToPolar(env, explodingSupa, 'u1', 'code_1', 35);
      expect(micros).toBe(35 * 10_000); // 350_000 micros = 35 PND → 0.35 PNC
    });

    it('returns 0 for non-positive credits (no grant)', async () => {
      const env = { POLAR_ACCESS_TOKEN: 't', POLAR_PNC_METER_ID: 'm' } as Env;
      expect(await creditRedemptionToPolar(env, explodingSupa, 'u1', 'c', 0)).toBe(0);
    });
  });
});
