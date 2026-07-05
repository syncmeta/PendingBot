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
  headers: HeadersInit = {},
): Promise<{ status: number; body: Record<string, unknown> }> {
  const app = new Hono<AppBindings>();
  app.route('/v1/me', meRoutes);
  const res = await app.request(
    '/v1/me/family-credential',
    { method: 'POST', headers },
    makeFakeEnv(db),
  );
  return {
    status: res.status,
    body: (await res.json()) as Record<string, unknown>,
  };
}

const ALICE_SUBJECT = {
  id: 'subject-1',
  kind: 'user_account',
  user_id: 'user-1',
  display_name: 'Alice',
  status: 'active',
};

describe('POST /v1/me/family-credential', () => {
  it('issues a pfa_ token bound to the personal subject', async () => {
    const issued: Record<string, unknown>[] = [];
    const db = makeFakeDb({
      subjects: [ALICE_SUBJECT],
    });
    db.rpcs = {
      issue_family_sso_credential: (args) => {
        issued.push(args);
        return { data: args.p_id };
      },
    };

    const r = await call(db, { 'x-test-user-id': 'user-1' });

    expect(r.status).toBe(200);
    const cred = r.body.familyCredential as Record<string, unknown>;
    expect(typeof cred.token).toBe('string');
    expect(cred.token as string).toMatch(/^pfa_/);
    expect(cred.subjectId).toBe('subject-1');
    // RPC got the hashed token (never the raw one) + default device name.
    expect(issued).toHaveLength(1);
    expect(issued[0].p_user_id).toBe('user-1');
    expect(issued[0].p_device_name).toBe('Mac');
    expect(issued[0].p_token_hash).not.toContain('pfa_');
    expect(issued[0].p_token_hash).toMatch(/^[0-9a-f]{64}$/);
  });

  it('returns 401 without a session', async () => {
    const r = await call(makeFakeDb({ subjects: [ALICE_SUBJECT] }));
    expect(r.status).toBe(401);
  });

  it('returns 404 when the personal subject is missing', async () => {
    const db = makeFakeDb({ subjects: [] });
    db.rpcs = {
      issue_family_sso_credential: () => ({ data: 'x' }),
    };
    const r = await call(db, { 'x-test-user-id': 'user-1' });
    expect(r.status).toBe(404);
    expect((r.body.error as Record<string, unknown>).code).toBe('subject_not_found');
  });
});
