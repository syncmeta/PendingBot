import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  grantSignupBonus,
  creditRedemptionToPolar,
  normalizeEmail,
  SIGNUP_BONUS_PNC,
  PND_TO_PNC_MICROS,
} from './billing-grant';
import type { Env } from '../types';
import type { SupabaseClient } from './supabase';
import { makeFakeClient, makeFakeDb, type FakeDb } from '../../tests/_helpers/fake-supabase';

// Polar 客户端与 WalletDO 都打桩:这里只验"用了哪个主体键",不验网络。
const ensureCustomerMock = vi.fn(async (_externalId: string, _email: string) => undefined);
const grantCreditsMock = vi.fn(async (_externalId: string, _pnc: number, _g: unknown) => undefined);
vi.mock('../billing/polar-client', () => ({
  polarFromEnv: () => ({
    ensureCustomer: (id: string, email: string) => ensureCustomerMock(id, email),
    grantCredits: (id: string, pnc: number, g: unknown) => grantCreditsMock(id, pnc, g),
  }),
}));

const creditMock = vi.fn(async (_env: unknown, _subjectId: string, _micros: number) => undefined);
vi.mock('../billing/wallet-client', () => ({
  wallet: { credit: (env: unknown, id: string, m: number) => creditMock(env, id, m) },
}));

// A supa that throws on any use — proves the short-circuit never touches the DB.
const explodingSupa = new Proxy({}, {
  get() {
    throw new Error('supa should not be touched');
  },
}) as unknown as SupabaseClient;

const polarEnv = {
  BILLING_ENABLED: 'true',
  POLAR_ACCESS_TOKEN: 't',
  POLAR_PNC_METER_ID: 'm',
} as Env;

/// 线上形态:auth user id 与 user_account subject id 是两个不同的 uuid。
const USER = '746b0b4f-d294-4844-b968-65ea6f4d5214';
const SUBJECT = '019eddb6-8449-71f8-a6cf-1c6d2cc9a500';

function grantDb(extra: Record<string, Array<Record<string, unknown>>> = {}): FakeDb {
  return makeFakeDb({
    subjects: [{ id: SUBJECT, user_id: USER, kind: 'user_account' }],
    users: [{ id: USER, email: 'alice@example.com' }],
    ...extra,
  });
}

describe('billing-grant 主体键(个人钱包统一到 subjects.id)', () => {
  beforeEach(() => {
    ensureCustomerMock.mockClear();
    grantCreditsMock.mockClear();
    creditMock.mockClear();
  });

  it('signup 赠送记在 user_account subject 上,幂等键 external_ref 仍是 signup:<userId>', async () => {
    const db = grantDb();
    await grantSignupBonus(polarEnv, makeFakeClient(db) as unknown as SupabaseClient, USER);

    const ledger = db.inserts.find((i) => i.table === 'pnc_ledger')?.row;
    expect(ledger?.subject_id).toBe(SUBJECT);
    // 幂等键格式不能变 —— 线上已有 signup:<userId> 的历史行,改格式=重复发放。
    expect(ledger?.external_ref).toBe(`signup:${USER}`);
    expect(ledger?.source).toBe('signup');

    // welcome 名额台账、Polar customer、WalletDO 缓存都用同一个键。
    expect(db.inserts.find((i) => i.table === 'welcome_bonus_grants')?.row.subject_id).toBe(SUBJECT);
    expect(ensureCustomerMock).toHaveBeenCalledWith(SUBJECT, 'alice@example.com');
    expect(grantCreditsMock.mock.calls[0][0]).toBe(SUBJECT);
    expect(creditMock.mock.calls[0][1]).toBe(SUBJECT);
  });

  it('已有历史 signup 行(记在 subject 上)→ 不重复发放', async () => {
    const db = grantDb({
      pnc_ledger: [
        {
          id: 'old',
          subject_id: SUBJECT,
          source: 'signup',
          external_ref: `signup:${USER}`,
          delta_pnc_micros: 35_000_000,
        },
      ],
    });
    await grantSignupBonus(polarEnv, makeFakeClient(db) as unknown as SupabaseClient, USER);

    expect(db.inserts.filter((i) => i.table === 'pnc_ledger')).toHaveLength(0);
    expect(grantCreditsMock).not.toHaveBeenCalled();
  });

  it('解析不到主体 → 不发放、不建 Polar customer、留日志', async () => {
    // 用另一个 user id:解析器命中会缓存,复用 USER 会读到上面用例的缓存。
    const ghost = 'ffffffff-0000-4000-8000-000000000001';
    const db = makeFakeDb({ subjects: [], users: [{ id: ghost, email: 'ghost@example.com' }] });
    const err = vi.spyOn(console, 'error').mockImplementation(() => undefined);

    await grantSignupBonus(polarEnv, makeFakeClient(db) as unknown as SupabaseClient, ghost);

    expect(db.inserts).toHaveLength(0);
    expect(ensureCustomerMock).not.toHaveBeenCalled();
    expect(err).toHaveBeenCalled();
    err.mockRestore();
  });

  it('兑换码入账记在 subject 上,external_ref 仍是 code id', async () => {
    const db = grantDb();
    const micros = await creditRedemptionToPolar(
      polarEnv,
      makeFakeClient(db) as unknown as SupabaseClient,
      USER,
      'code_1',
      35,
    );

    expect(micros).toBe(350_000);
    const ledger = db.inserts.find((i) => i.table === 'pnc_ledger')?.row;
    expect(ledger?.subject_id).toBe(SUBJECT);
    expect(ledger?.external_ref).toBe('code_1');
    expect(ensureCustomerMock).toHaveBeenCalledWith(SUBJECT, 'alice@example.com');
    expect(creditMock.mock.calls[0][1]).toBe(SUBJECT);
  });

  it('兑换码:解析不到主体 → 抛(钱进来的路径不许静默吞)', async () => {
    const ghost = 'ffffffff-0000-4000-8000-000000000002';
    const db = makeFakeDb({ subjects: [], users: [{ id: ghost, email: 'a@b.com' }] });
    await expect(
      creditRedemptionToPolar(polarEnv, makeFakeClient(db) as unknown as SupabaseClient, ghost, 'code_2', 35),
    ).rejects.toThrow();
  });
});

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
