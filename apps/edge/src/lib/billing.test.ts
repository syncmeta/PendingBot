import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  InsufficientBalanceError,
  RedemptionError,
  getBalanceGateState,
  redeemCode,
  requireBalance,
} from './billing';
import type { SupabaseClient } from './supabase';
import type { Env } from '../types';
import {
  makeFakeClient,
  makeFakeDb,
  makeFakeEnv,
  type FakeWallet,
} from '../../tests/_helpers/fake-supabase';

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
  vi.useRealTimers();
});

// usdToPnd / getMarkup 测试已删:billing-v1 markup 换算退役(语音成本预览
// 已切到 usdToPncMicros 同口径),对应函数从 billing.ts 删除。

// 计费 P2: the pre-call gate reads the subject's strong-consistent WalletDO
// cached balance (env.WALLET, one DO per subject) and blocks ONLY when
// exhausted (≤ 0). min_threshold is always 0; balance_credits carries PNC
// micros. This env stub makes wallet.gate(env, userId) reply with a fixed
// balance. supa is no longer touched by the gate (passed for signature).
function walletEnv(balanceMicros: number): Env {
  const fetchImpl = async () =>
    new Response(
      JSON.stringify({
        balanceMicros,
        thresholdState: balanceMicros > 0 ? 'sufficient' : 'exhausted',
      }),
      { headers: { 'content-type': 'application/json' } },
    );
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return {
    // requireBalance is gated by the billing kill-switch — enable it so these
    // tests exercise the live gate path.
    BILLING_ENABLED: 'true',
    WALLET: {
      idFromName: (n: string) => n,
      get: () => ({ fetch: fetchImpl }),
    },
  } as any;
}
// 门禁要把 auth user id 解析成 user_account subject id 才知道读哪个 WalletDO
// (个人钱包主体键统一,见 billing/subject-key.ts),所以 supa 不再是可有可无的。
const subjectDb = makeFakeDb({
  subjects: [{ id: 'u1-sub', user_id: 'u1', kind: 'user_account' }],
});
const noSupa = makeFakeClient(subjectDb) as unknown as SupabaseClient;

describe('requireBalance (WalletDO gate)', () => {
  it('snapshot reports WalletDO micros, threshold 0, allowed when positive', async () => {
    await expect(getBalanceGateState(walletEnv(70_000_000), noSupa, 'u1')).resolves.toEqual({
      balance_credits: 70_000_000,
      min_threshold: 0,
      allowed: true,
    });
  });

  it('passes when the subject has any positive balance', async () => {
    await expect(requireBalance(walletEnv(1), noSupa, 'u1')).resolves.toBeUndefined();
  });

  it('throws InsufficientBalanceError when exhausted (zero balance)', async () => {
    await expect(requireBalance(walletEnv(0), noSupa, 'u1')).rejects.toBeInstanceOf(
      InsufficientBalanceError,
    );
  });

  it('throws when balance is negative (overdrawn)', async () => {
    await expect(requireBalance(walletEnv(-100), noSupa, 'u1')).rejects.toBeInstanceOf(
      InsufficientBalanceError,
    );
  });

  it('error carries the (zero) balance and threshold for client copy', async () => {
    try {
      await requireBalance(walletEnv(0), noSupa, 'u1');
      expect.fail('should have thrown');
    } catch (err) {
      expect(err).toBeInstanceOf(InsufficientBalanceError);
      const e = err as InsufficientBalanceError;
      expect(e.balance).toBe(0);
      expect(e.threshold).toBe(0);
    }
  });

  it('fails open (allows) when the WalletDO read errors — never hard-stop a paying user', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const env = {
      WALLET: {
        idFromName: (n: string) => n,
        get: () => ({ fetch: async () => { throw new Error('DO unreachable'); } }),
      },
    } as any;
    await expect(getBalanceGateState(env, noSupa, 'u1')).resolves.toEqual({
      balance_credits: 0,
      min_threshold: 0,
      allowed: true,
    });
  });
});

describe('getBalanceGateState 主体键(个人钱包统一到 subjects.id)', () => {
  it('读的是该用户 user_account subject 的钱包,不是 auth user id 那个', async () => {
    const db = makeFakeDb({
      subjects: [{ id: 'sub-x', user_id: 'user-x', kind: 'user_account' }],
    });
    const w: FakeWallet = { calls: [], balances: { 'sub-x': 70_000_000, 'user-x': 0 } };
    const env = makeFakeEnv(db, { wallet: w });
    const r = await getBalanceGateState(env, makeFakeClient(db) as unknown as SupabaseClient, 'user-x');
    expect(r).toEqual({ balance_credits: 70_000_000, min_threshold: 0, allowed: true });
    expect(w.calls.map((c) => c.subjectId)).toEqual(['sub-x']);
  });

  it('解析不到主体 → fail-open + 记日志(绝不静默判成余额耗尽)', async () => {
    const db = makeFakeDb({ subjects: [] });
    const w: FakeWallet = { calls: [], balances: {} };
    const env = makeFakeEnv(db, { wallet: w });
    const err = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const r = await getBalanceGateState(env, makeFakeClient(db) as unknown as SupabaseClient, 'user-y');
    expect(r.allowed).toBe(true);
    expect(w.calls).toEqual([]); // 没去碰任何钱包
    expect(err).toHaveBeenCalled();
  });
});

// subject billing helpers 测试已删(#226):getSubjectBalance/subject_wallets
// 退役,主体余额走 WalletDO;扣费 billingDebitSubject 早前已删。

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
