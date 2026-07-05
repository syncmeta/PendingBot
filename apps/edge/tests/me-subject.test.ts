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

// #226 retired the subject_wallets snapshot; /me/subject now sources the
// balance from WalletDO via wallet.gate (same source as /wallet/v2). Mock only
// wallet.gate, keep the rest of the module real.
const gateMock = vi.fn(async (_env: unknown, _id: string) => ({ balanceMicros: 0, thresholdState: 'sufficient' as const }));
vi.mock('../src/billing/wallet-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../src/billing/wallet-client')>();
  return {
    ...actual,
    wallet: {
      ...actual.wallet,
      gate: (env: unknown, id: string) => gateMock(env as never, id as never),
    },
  };
});

installFakeSupabaseMock();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let meRoutes: any;

beforeEach(async () => {
  gateMock.mockReset();
  gateMock.mockResolvedValue({ balanceMicros: 0, thresholdState: 'sufficient' as const });
  ({ meRoutes } = await import('../src/routes/me'));
});

async function call(
  db: FakeDb,
  userId = 'user-1',
): Promise<{ status: number; body: Record<string, unknown> }> {
  return callWithHeaders(db, { 'x-test-user-id': userId });
}

async function callWithHeaders(
  db: FakeDb,
  headers: HeadersInit,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const app = new Hono<AppBindings>();
  app.route('/v1/me', meRoutes);
  const res = await app.request(
    '/v1/me/subject',
    { headers },
    makeFakeEnv(db),
  );
  return {
    status: res.status,
    body: (await res.json()) as Record<string, unknown>,
  };
}

async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

const ALICE = {
  id: 'subject-1',
  kind: 'user_account',
  user_id: 'user-1',
  display_name: 'Alice',
  status: 'active',
  created_at: '2026-05-24T00:00:00Z',
  updated_at: '2026-05-24T00:00:00Z',
};

describe('GET /v1/me/subject', () => {
  it('returns the caller personal subject with its WalletDO balance', async () => {
    gateMock.mockResolvedValue({ balanceMicros: 1200, thresholdState: 'sufficient' as const });
    const db = makeFakeDb({ subjects: [ALICE] });

    const r = await call(db);

    expect(r.status).toBe(200);
    expect(r.body.subject).toMatchObject({
      id: 'subject-1',
      subject_type: 'user_account',
      display_name: 'Alice',
      status: 'active',
    });
    // user_id surfaces the authenticated user (user-JWT path → c.var.userId).
    expect(r.body.user_id).toBe('user-1');
    // balance_credits is now PNC micros from WalletDO; lifetime_* no longer
    // materialized per-subject (ledger detail lives in pnc_ledger), kept 0.
    expect(r.body.wallet).toEqual({
      balance_credits: 1200,
      lifetime_topup_credits: 0,
      lifetime_spent_credits: 0,
    });
  });

  it('returns a zero wallet when WalletDO is unreachable (fail-open)', async () => {
    gateMock.mockRejectedValue(new Error('DO unreachable'));
    const db = makeFakeDb({ subjects: [ALICE] });

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

  it('accepts a device grant and returns the granted subject', async () => {
    gateMock.mockResolvedValue({ balanceMicros: 1200, thresholdState: 'sufficient' as const });
    const token = 'pdg_subject_read_token';
    const db = makeFakeDb({
      subject_device_grants: [
        {
          id: 'grant-1',
          subject_id: 'subject-1',
          granted_by_user_id: 'user-1',
          token_hash: await sha256Hex(token),
          grant_kind: 'pendingcrew_control',
          scopes: ['subject:read'],
          app_kind: 'pendingcrew_macos',
          status: 'active',
          expires_at: '2099-01-01T00:00:00Z',
          last_used_at: null,
        },
      ],
      subjects: [ALICE],
    });

    const r = await callWithHeaders(db, { authorization: `Bearer ${token}` });

    expect(r.status).toBe(200);
    expect(r.body.subject).toMatchObject({
      id: 'subject-1',
      subject_type: 'user_account',
      display_name: 'Alice',
      status: 'active',
    });
    // device-grant path surfaces granted_by_user_id (the PendingCrew user).
    expect(r.body.user_id).toBe('user-1');
    expect(r.body.wallet).toEqual({
      balance_credits: 1200,
      lifetime_topup_credits: 0,
      lifetime_spent_credits: 0,
    });
  });
});
