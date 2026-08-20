import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import type { MiddlewareHandler } from 'hono';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
  type FakeWallet,
} from './_helpers/fake-supabase';
import type { AppBindings } from '../src/types';

vi.mock('@pendingbot/identity', () => ({
  requireSession: (): MiddlewareHandler<{
    Bindings: { SUPABASE_URL: string; SUPABASE_JWT_SECRET: string };
    Variables: { userId?: string; userJwt?: string };
  }> => async (c, next) => {
    const u = c.req.header('x-test-user-id');
    if (!u) return c.json({ error: { code: 'unauthorized' } }, 401);
    c.set('userId', u);
    c.set('userJwt', 'test-jwt');
    await next();
  },
}));

installFakeSupabaseMock();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let meRoutes: any;

beforeEach(async () => {
  ({ meRoutes } = await import('../src/routes/me'));
});

async function callWalletV2(
  db: FakeDb,
  userId: string,
  w: FakeWallet,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const app = new Hono<AppBindings>();
  app.route('/v1/me', meRoutes);
  const res = await app.request(
    '/v1/me/wallet/v2',
    { headers: { 'x-test-user-id': userId } },
    makeFakeEnv(db, { wallet: w }),
  );
  return { status: res.status, body: (await res.json()) as Record<string, unknown> };
}

describe('GET /v1/me/wallet/v2 主体键', () => {
  it('余额与账本都按 user_account subject 读,不是 auth user id', async () => {
    const db = makeFakeDb({
      subjects: [{ id: 'alice-sub', user_id: 'alice', kind: 'user_account' }],
      pnc_ledger: [
        {
          id: 'l1',
          subject_id: 'alice-sub',
          kind: 'topup',
          source: 'polar_checkout',
          delta_pnc_micros: 100_000_000,
          created_at: '2026-08-18T04:44:00Z',
        },
        // auth user id 名下不可能有行(pnc_ledger.subject_id 外键指向 subjects),
        // 放一条假的:读错键就会把它读出来。
        { id: 'l2', subject_id: 'alice', kind: 'topup', source: 'wrong-key', delta_pnc_micros: 1, created_at: '2026-08-18T05:00:00Z' },
      ],
    });
    const w: FakeWallet = { calls: [], balances: { 'alice-sub': 100_000_000, alice: 0 } };

    const { status, body } = await callWalletV2(db, 'alice', w);

    expect(status).toBe(200);
    expect(body.total_pnc_micros).toBe(100_000_000);
    expect(w.calls.map((c) => c.subjectId)).toEqual(['alice-sub']);
    const ledger = body.recent_ledger as Array<{ id: string }>;
    expect(ledger.map((l) => l.id)).toEqual(['l1']);
  });

  it('解析不到主体 → 404 subject_not_found(不返回一个误导人的 0 余额)', async () => {
    const db = makeFakeDb({ subjects: [] });
    const w: FakeWallet = { calls: [], balances: {} };

    const { status, body } = await callWalletV2(db, 'ghost', w);

    expect(status).toBe(404);
    expect((body.error as { code?: string })?.code).toBe('subject_not_found');
    expect(w.calls).toEqual([]);
  });
});
