import { describe, expect, it, vi } from 'vitest';
import {
  grantSignupBonus,
  creditRedemptionToPolar,
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
