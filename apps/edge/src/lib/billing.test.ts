import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  InsufficientBalanceError,
  RedemptionError,
  _resetMarkupCache,
  _resetThresholdCache,
  getMarkup,
  redeemCode,
  requireBalance,
  usdToPnd,
} from './billing';
import type { SupabaseClient } from './supabase';
import type { Env } from '../types';

// Minimal Env stub for tests that call requireBalance. The MEMORY KV
// always misses, forcing the balance/threshold reads to fall through
// to the Supabase stub (which is what these tests actually verify).
function fakeEnv(): Env {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return {
    MEMORY: {
      get: async () => null,
      put: async () => undefined,
      delete: async () => undefined,
    },
  } as any;
}

// Shape of the chained Supabase query we use throughout. A real
// SupabaseClient ships ~200 methods we don't touch; mock only what the
// code under test actually awaits.
function stubSupa(
  handlers: Partial<{
    billing_config: (key: string) => { data: unknown; error?: { message: string } | null };
    users: (
      userId: string,
    ) => { data: { balance_credits: number; lifetime_topup_credits?: number; lifetime_spent_credits?: number } | null };
    rpc: (fn: string, args: Record<string, unknown>) => { data?: unknown; error?: { code?: string; message?: string } | null };
  }>,
): SupabaseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client: any = {
    from(table: string) {
      return {
        select() {
          return this;
        },
        eq(_col: string, value: unknown) {
          (this as { _eq?: unknown })._eq = value;
          return this;
        },
        async maybeSingle() {
          if (table === 'billing_config' && handlers.billing_config) {
            return handlers.billing_config((this as { _eq?: string })._eq as string);
          }
          if (table === 'users' && handlers.users) {
            return handlers.users((this as { _eq?: string })._eq as string);
          }
          return { data: null, error: null };
        },
      };
    },
    async rpc(fn: string, args: Record<string, unknown>) {
      if (handlers.rpc) return handlers.rpc(fn, args);
      return { data: null, error: null };
    },
  };
  return client as SupabaseClient;
}

afterEach(() => {
  _resetMarkupCache();
  _resetThresholdCache();
  vi.useRealTimers();
});

describe('usdToPnd', () => {
  // 1 USD = 2700 PND headline; the markup multiplies on top. The
  // function ceils so a fractional debit never silently rounds DOWN
  // (which would leak free LLM tokens at scale).
  it('multiplies USD by 2700 × markup and ceils', () => {
    // $0.001 × 2700 × 2.5 = 6.75 → ceil → 7
    expect(usdToPnd(0.001, 2.5)).toBe(7);
    // $1 × 2700 × 2.5 = 6750
    expect(usdToPnd(1, 2.5)).toBe(6750);
    // $0.0001 × 2700 × 2 = 0.54 → ceil → 1 (smallest billable unit)
    expect(usdToPnd(0.0001, 2)).toBe(1);
  });

  it('returns 0 for null / 0 / negative cost', () => {
    expect(usdToPnd(null, 2.5)).toBe(0);
    expect(usdToPnd(undefined, 2.5)).toBe(0);
    expect(usdToPnd(0, 2.5)).toBe(0);
    expect(usdToPnd(-1, 2.5)).toBe(0);
  });

  it('returns 0 for non-positive / non-finite markup (no free passes)', () => {
    // If markup somehow comes through as 0 / NaN / Infinity we'd
    // otherwise either zero out billing or blow up arithmetic — both
    // bad. Returning 0 means a fallback path can still run while ops
    // notices the unbilled rows.
    expect(usdToPnd(1, 0)).toBe(0);
    expect(usdToPnd(1, -1)).toBe(0);
    expect(usdToPnd(1, Number.NaN)).toBe(0);
    expect(usdToPnd(1, Number.POSITIVE_INFINITY)).toBe(0);
  });
});

describe('getMarkup', () => {
  it('reads billing_config.markup when present', async () => {
    const supa = stubSupa({
      billing_config: () => ({ data: { value: 3 }, error: null }),
    });
    expect(await getMarkup(supa)).toBe(3);
  });

  it('falls back to DEFAULT_MARKUP (2.5) when key is missing', async () => {
    const supa = stubSupa({
      billing_config: () => ({ data: null, error: null }),
    });
    expect(await getMarkup(supa)).toBe(2.5);
  });

  it('falls back to DEFAULT_MARKUP on DB error', async () => {
    // A transient Supabase outage must not zero out billing — fallback
    // keeps the call path alive on the documented seed value.
    const supa = stubSupa({
      billing_config: () => ({ data: null, error: { message: 'connection refused' } }),
    });
    expect(await getMarkup(supa)).toBe(2.5);
  });

  it('caches for 60s and refreshes after expiry', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-01-01T00:00:00Z'));
    let calls = 0;
    const supa = stubSupa({
      billing_config: () => {
        calls += 1;
        return { data: { value: 2 + calls }, error: null }; // 3, 4, 5...
      },
    });
    expect(await getMarkup(supa)).toBe(3);
    // 30s later — still cached
    vi.advanceTimersByTime(30_000);
    expect(await getMarkup(supa)).toBe(3);
    expect(calls).toBe(1);
    // 31s later (61s total) — refreshed
    vi.advanceTimersByTime(31_000);
    expect(await getMarkup(supa)).toBe(4);
    expect(calls).toBe(2);
  });
});

describe('requireBalance', () => {
  it('passes when balance >= threshold', async () => {
    const supa = stubSupa({
      users: () => ({ data: { balance_credits: 1000 } }),
      billing_config: () => ({ data: { value: 100 }, error: null }),
    });
    await expect(requireBalance(fakeEnv(), supa, 'u1')).resolves.toBeUndefined();
  });

  it('passes when threshold is 0 (no gate)', async () => {
    // 0 means "don't gate anyone" per the seed value semantics.
    const supa = stubSupa({
      users: () => ({ data: { balance_credits: -50 } }),
      billing_config: () => ({ data: { value: 0 }, error: null }),
    });
    await expect(requireBalance(fakeEnv(), supa, 'u1')).resolves.toBeUndefined();
  });

  it('throws InsufficientBalanceError when balance < threshold', async () => {
    const supa = stubSupa({
      users: () => ({ data: { balance_credits: 5 } }),
      billing_config: () => ({ data: { value: 100 }, error: null }),
    });
    await expect(requireBalance(fakeEnv(), supa, 'u1')).rejects.toBeInstanceOf(InsufficientBalanceError);
  });

  it('error carries actual balance + threshold (so client can render copy)', async () => {
    const supa = stubSupa({
      users: () => ({ data: { balance_credits: 5 } }),
      billing_config: () => ({ data: { value: 100 }, error: null }),
    });
    try {
      await requireBalance(fakeEnv(), supa, 'u1');
      expect.fail('should have thrown');
    } catch (err) {
      expect(err).toBeInstanceOf(InsufficientBalanceError);
      const e = err as InsufficientBalanceError;
      expect(e.balance).toBe(5);
      expect(e.threshold).toBe(100);
    }
  });

  it('treats missing user row as balance 0', async () => {
    const supa = stubSupa({
      users: () => ({ data: null }),
      billing_config: () => ({ data: { value: 1 }, error: null }),
    });
    await expect(requireBalance(fakeEnv(), supa, 'u1')).rejects.toBeInstanceOf(InsufficientBalanceError);
  });
});

describe('redeemCode error mapping', () => {
  // Postgres SQLSTATE codes the RPC raises map to typed RedemptionError
  // kinds so iOS can branch on .kind rather than parsing error.message.
  it('42501 → not_authenticated', async () => {
    const supa = stubSupa({
      rpc: () => ({ data: null, error: { code: '42501', message: 'permission denied' } }),
    });
    await expect(redeemCode(supa, 'CODE'))
      .rejects.toMatchObject({ kind: 'not_authenticated' });
  });

  it('P0002 → not_found', async () => {
    const supa = stubSupa({
      rpc: () => ({ data: null, error: { code: 'P0002', message: 'no row' } }),
    });
    await expect(redeemCode(supa, 'CODE'))
      .rejects.toMatchObject({ kind: 'not_found' });
  });

  it('P0001 → already_used', async () => {
    const supa = stubSupa({
      rpc: () => ({ data: null, error: { code: 'P0001', message: 'used' } }),
    });
    await expect(redeemCode(supa, 'CODE'))
      .rejects.toMatchObject({ kind: 'already_used' });
  });

  it('unknown PG code → unknown', async () => {
    const supa = stubSupa({
      rpc: () => ({ data: null, error: { code: '08006', message: 'connection failure' } }),
    });
    await expect(redeemCode(supa, 'CODE'))
      .rejects.toMatchObject({ kind: 'unknown' });
  });

  it('happy path returns the redeem payload', async () => {
    const supa = stubSupa({
      rpc: () => ({ data: { credits: 1000, new_balance: 2500 }, error: null }),
    });
    const r = await redeemCode(supa, 'CODE');
    expect(r).toEqual({ credits: 1000, new_balance: 2500 });
  });
});

describe('RedemptionError', () => {
  it('preserves kind on rethrow', () => {
    const e = new RedemptionError('not_found', 'whoops');
    expect(e.kind).toBe('not_found');
    expect(e.name).toBe('RedemptionError');
    expect(e.message).toBe('whoops');
  });
});
