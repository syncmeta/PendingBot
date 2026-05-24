import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import type { MiddlewareHandler } from 'hono';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
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

async function call(
  db: FakeDb,
  userId = 'user-1',
): Promise<{ status: number; body: Record<string, unknown> }> {
  const app = new Hono<AppBindings>();
  app.route('/v1/me', meRoutes);
  const res = await app.request(
    '/v1/me/subject',
    { headers: { 'x-test-user-id': userId } },
    makeFakeEnv(db),
  );
  return {
    status: res.status,
    body: (await res.json()) as Record<string, unknown>,
  };
}

describe('GET /v1/me/subject', () => {
  it('returns the caller personal subject with its wallet', async () => {
    const db = makeFakeDb({
      subjects: [
        {
          id: 'subject-1',
          subject_type: 'user_account',
          user_id: 'user-1',
          display_name: 'Alice',
          status: 'active',
          created_at: '2026-05-24T00:00:00Z',
          updated_at: '2026-05-24T00:00:00Z',
        },
      ],
      subject_wallets: [
        {
          subject_id: 'subject-1',
          balance_credits: 1200,
          lifetime_topup_credits: 2000,
          lifetime_spent_credits: 800,
        },
      ],
    });

    const r = await call(db);

    expect(r.status).toBe(200);
    expect(r.body.subject).toMatchObject({
      id: 'subject-1',
      subject_type: 'user_account',
      display_name: 'Alice',
      status: 'active',
    });
    expect(r.body.wallet).toEqual({
      balance_credits: 1200,
      lifetime_topup_credits: 2000,
      lifetime_spent_credits: 800,
    });
  });

  it('returns a zero wallet when the subject exists but wallet row is hidden', async () => {
    const db = makeFakeDb({
      subjects: [
        {
          id: 'subject-1',
          subject_type: 'user_account',
          user_id: 'user-1',
          display_name: 'Alice',
          status: 'active',
          created_at: '2026-05-24T00:00:00Z',
          updated_at: '2026-05-24T00:00:00Z',
        },
      ],
    });

    const r = await call(db);

    expect(r.status).toBe(200);
    expect(r.body.wallet).toEqual({
      balance_credits: 0,
      lifetime_topup_credits: 0,
      lifetime_spent_credits: 0,
    });
  });

  it('returns 404 when the personal subject has not been initialized', async () => {
    const r = await call(makeFakeDb({ subjects: [] }));

    expect(r.status).toBe(404);
    expect(r.body).toEqual({
      error: {
        code: 'subject_not_found',
        message: '个人责任主体尚未初始化',
      },
    });
  });
});
