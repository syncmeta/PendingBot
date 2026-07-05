// Tests for the /v1/machines surface (see apps/edge/src/routes/machines.ts).
//
// Uses the in-memory fake-supabase helper — we stub the
// upsert_self_machine RPC and seed the subjects + machine rows the
// routes read. Intent is to pin the route contract: status codes,
// request/response shapes, and the subject scoping.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import type { MiddlewareHandler } from 'hono';
import { installFakeSupabaseMock, makeFakeDb, makeFakeEnv } from './_helpers/fake-supabase';
import type { FakeDb } from './_helpers/fake-supabase';
import type { AppBindings } from '../src/types';

// Mock @pendingbot/identity::requireSession the same way crews.test.ts
// does — header `x-test-user-id` sets the caller; missing header → 401.
// requireSubjectAuth (in device-grants.ts) wraps this for non-`pdg_`
// bearers, so a plain JWT caller lands here and gets authKind:
// 'supabase_jwt' + userId set.
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

// Lazy-import so the mocks above wire up first.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let machinesRoutes: any;

beforeEach(async () => {
  ({ machinesRoutes } = await import('../src/routes/machines'));
});

function appFor(db: FakeDb) {
  const app = new Hono<AppBindings>();
  app.route('/v1/machines', machinesRoutes);
  return {
    request: (path: string, init?: RequestInit) =>
      app.request(path, init, makeFakeEnv(db)),
  };
}

const USER = 'user-1';
const USER_SUBJECT = '11111111-1111-4111-8111-aaaaaaaaaaaa';
const MACHINE_ID = '33333333-3333-4333-8333-cccccccccccc';
const OTHER_SUBJECT = '66666666-6666-4666-8666-ffffffffffff';

// Seeds the caller's user_account subject, which the routes resolve to
// scope machine rows. Without it GET returns [] and register-self 404s.
function seedOwnSubject(db: FakeDb) {
  db.rows.subjects = [
    ...(db.rows.subjects ?? []),
    {
      id: USER_SUBJECT,
      kind: 'user_account',
      user_id: USER,
      display_name: '我',
      status: 'active',
    },
  ];
}

describe('GET /v1/machines', () => {
  it('returns the caller-subject machines, camelCased and ordered by created_at', async () => {
    const db = makeFakeDb({
      machine: [
        {
          id: MACHINE_ID,
          subject_id: USER_SUBJECT,
          kind: 'computer',
          device_id: 'dev-abc',
          display_name: '我的 MacBook',
          fly_machine_id: null,
          status: 'online',
          last_seen_at: '2026-06-14T00:00:00Z',
          created_at: '2026-06-14T00:00:00Z',
        },
        {
          // Machine on another subject — must not leak.
          id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          subject_id: OTHER_SUBJECT,
          kind: 'fly',
          device_id: null,
          display_name: '别人的 Fly',
          fly_machine_id: 'fly-x',
          status: 'online',
          last_seen_at: null,
          created_at: '2026-06-14T00:01:00Z',
        },
      ],
    });
    seedOwnSubject(db);

    const res = await appFor(db).request('/v1/machines', {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { machines: Array<Record<string, unknown>> };
    expect(body.machines).toEqual([
      {
        id: MACHINE_ID,
        kind: 'computer',
        deviceId: 'dev-abc',
        displayName: '我的 MacBook',
        flyMachineId: null,
        status: 'online',
        lastSeenAt: '2026-06-14T00:00:00Z',
      },
    ]);
  });

  it('returns an empty list when the caller has no user_account subject', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request('/v1/machines', {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ machines: [] });
  });

  it('returns 401 when no session header is set', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request('/v1/machines');
    expect(res.status).toBe(401);
  });
});

describe('POST /v1/machines/register-self', () => {
  it('upserts via upsert_self_machine and returns machineId', async () => {
    const db = makeFakeDb();
    seedOwnSubject(db);
    let seen: Record<string, unknown> | undefined;
    db.rpcs = {
      upsert_self_machine: (args) => {
        seen = args;
        return { data: MACHINE_ID, error: null };
      },
    };

    const res = await appFor(db).request('/v1/machines/register-self', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ deviceId: 'dev-abc', displayName: '我的 MacBook' }),
    });
    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ machineId: MACHINE_ID });
    expect(seen).toMatchObject({
      p_subject_id: USER_SUBJECT,
      p_device_id: 'dev-abc',
      p_display_name: '我的 MacBook',
    });
  });

  it('rejects a missing field with 400 invalid_body', async () => {
    const db = makeFakeDb();
    seedOwnSubject(db);
    const res = await appFor(db).request('/v1/machines/register-self', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ deviceId: 'dev-abc' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_body');
  });

  it('returns 404 subject_not_found when the caller has no user_account subject', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request('/v1/machines/register-self', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ deviceId: 'dev-abc', displayName: '我的 MacBook' }),
    });
    expect(res.status).toBe(404);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('subject_not_found');
  });
});
