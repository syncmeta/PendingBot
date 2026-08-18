import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
  type FakeWallet,
} from './_helpers/fake-supabase';
import type { AppBindings } from '../src/types';

// Polar 打桩:这里只验"用了哪个主体键",不打网络。
const grantCreditsMock = vi.fn(async (_id: string, _pnc: number, _g: unknown) => undefined);
vi.mock('../src/billing/polar-client', () => ({
  polarFromEnv: () => ({
    grantCredits: (id: string, pnc: number, g: unknown) => grantCreditsMock(id, pnc, g),
    reduceCredits: vi.fn(async () => undefined),
    ensureCustomer: vi.fn(async () => undefined),
  }),
}));

vi.mock('../src/lib/board-audit', () => ({
  recordBoardAudit: vi.fn(async () => undefined),
}));

installFakeSupabaseMock();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let boardBillingRoutes: any;

beforeEach(async () => {
  grantCreditsMock.mockClear();
  ({ boardBillingRoutes } = await import('../src/routes/board-billing'));
});

const USER = '746b0b4f-d294-4844-b968-65ea6f4d5214';
const SUBJECT = '019eddb6-8449-71f8-a6cf-1c6d2cc9a500';

function seed(extra: Record<string, Array<Record<string, unknown>>> = {}): FakeDb {
  return makeFakeDb({
    users: [{ id: USER, email: 'alice@example.com' }],
    subjects: [{ id: SUBJECT, user_id: USER, kind: 'user_account' }],
    ...extra,
  });
}

async function call(
  db: FakeDb,
  path: string,
  w: FakeWallet,
  init?: RequestInit,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const app = new Hono<AppBindings>();
  app.route('/v1/board/billing', boardBillingRoutes);
  const env = makeFakeEnv(db, { wallet: w });
  (env as unknown as Record<string, string>).POLAR_ACCESS_TOKEN = 't';
  (env as unknown as Record<string, string>).POLAR_PNC_METER_ID = 'm';
  const res = await app.request(`/v1/board/billing${path}`, init, env);
  return { status: res.status, body: (await res.json()) as Record<string, unknown> };
}

describe('board /billing/wallet 主体键', () => {
  it('余额与账本按 user_account subject 读,响应仍报 user id', async () => {
    const db = seed({
      pnc_ledger: [
        { id: 'l1', subject_id: SUBJECT, kind: 'topup', source: 'polar_checkout', external_ref: 'x', delta_pnc_micros: 100_000_000, created_at: '2026-08-18T04:44:00Z' },
      ],
    });
    const w: FakeWallet = { calls: [], balances: { [SUBJECT]: 100_000_000, [USER]: 0 } };

    const { status, body } = await call(db, '/wallet?q=alice@example.com', w);

    expect(status).toBe(200);
    const data = body.data as Record<string, unknown>;
    expect(data.user_id).toBe(USER);
    expect(data.balance_pnc_micros).toBe(100_000_000);
    expect(w.calls.map((c) => c.subjectId)).toEqual([SUBJECT]);
    expect((data.recent_ledger as Array<{ id: string }>).map((l) => l.id)).toEqual(['l1']);
  });

  it('查得到用户但没有 user_account 主体 → 404(不是一个假的 0 余额)', async () => {
    const ghost = 'ffffffff-0000-4000-8000-000000000011';
    const db = makeFakeDb({ users: [{ id: ghost, email: 'ghost@example.com' }], subjects: [] });
    const w: FakeWallet = { calls: [], balances: {} };

    const { status, body } = await call(db, '/wallet?q=ghost@example.com', w);

    expect(status).toBe(404);
    expect((body.error as { code?: string })?.code).toBe('subject_not_found');
    expect(w.calls).toEqual([]);
  });
});

describe('board /billing/grant 主体键', () => {
  it('发放写在 subject 名下(pnc_ledger 外键指向 subjects,写 user id 会违反外键)', async () => {
    const db = seed();
    const w: FakeWallet = { calls: [], balances: {} };

    const { status } = await call(db, '/grant', w, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ q: 'alice@example.com', pnc: 100, reason: '补发' }),
    });

    expect(status).toBe(200);
    const ledger = db.inserts.find((i) => i.table === 'pnc_ledger')?.row;
    expect(ledger?.subject_id).toBe(SUBJECT);
    expect(grantCreditsMock.mock.calls[0][0]).toBe(SUBJECT);
    const credit = w.calls.find((c) => c.path === '/credit');
    expect(credit?.subjectId).toBe(SUBJECT);
  });

  it('没有 user_account 主体 → 404,不写账本不动 Polar', async () => {
    const ghost = 'ffffffff-0000-4000-8000-000000000012';
    const db = makeFakeDb({ users: [{ id: ghost, email: 'ghost2@example.com' }], subjects: [] });
    const w: FakeWallet = { calls: [], balances: {} };

    const { status } = await call(db, '/grant', w, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ q: 'ghost2@example.com', pnc: 100, reason: '补发' }),
    });

    expect(status).toBe(404);
    expect(db.inserts).toHaveLength(0);
    expect(grantCreditsMock).not.toHaveBeenCalled();
  });
});
