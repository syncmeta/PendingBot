// Tests for T4.3 P1 — Permission Request HTTP layer
// (apps/edge/src/routes/permission-requests.ts).
//
// Covers:
//   * POST /v1/permission-requests/:id/decide
//     - 400 invalid_id / invalid_body
//     - 404 permission_request_not_found
//     - 403 permission_request_forbidden (cross-subject, non-owner)
//     - 409 permission_request_already_decided
//     - 200 approve/reject happy paths (call shape + response)
//   * PATCH /v1/crews/:crewId/permission-mode
//     - 400 invalid_id / invalid_body
//     - 404 crew_not_found
//     - 403 forbidden when caller can't control the subject
//     - 200 auto/manual happy paths
//   * PATCH /v1/sessions/:sessionId/permission-mode
//     - null clears (inherit crew default)
//     - 200 with auto / manual / null
//     - 403 session_forbidden
//
// Uses the in-memory fake-supabase helper. RPCs are stubbed; we pin the
// route contract (status codes, RPC args, response shapes), not the
// underlying SQL — the SQL ACL is enforced by the RPCs and validated by
// other test suites.

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
let permissionRequestRoutes: any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let crewPermissionModeRoutes: any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let sessionPermissionModeRoutes: any;

beforeEach(async () => {
  ({
    permissionRequestRoutes,
    crewPermissionModeRoutes,
    sessionPermissionModeRoutes,
  } = await import('../src/routes/permission-requests'));
});

function appFor(db: FakeDb) {
  const app = new Hono<AppBindings>();
  app.route('/v1/permission-requests', permissionRequestRoutes);
  app.route('/v1/crews', crewPermissionModeRoutes);
  app.route('/v1/sessions', sessionPermissionModeRoutes);
  return {
    request: (path: string, init?: RequestInit) =>
      app.request(path, init, makeFakeEnv(db)),
  };
}

const USER_ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const USER_BOB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const SUBJECT_ALICE = '11111111-1111-4111-8111-aaaaaaaaaaaa';
const CREW_ID = '33333333-3333-4333-8333-cccccccccccc';
const SESSION_A = '44444444-4444-4444-8444-dddddddddddd';
const REQUEST_PENDING = 'cccccccc-cccc-4ccc-8ccc-000000000001';
const REQUEST_DECIDED = 'cccccccc-cccc-4ccc-8ccc-000000000002';

function seedWithUserAccountSubject(): FakeDb {
  const db = makeFakeDb({
    subjects: [
      {
        id: SUBJECT_ALICE,
        kind: 'user_account',
        user_id: USER_ALICE,
        status: 'active',
      },
    ],
    permission_requests: [
      {
        id: REQUEST_PENDING,
        crew_session_id: SESSION_A,
        responsible_subject_id: SUBJECT_ALICE,
        requested_action: 'rm -rf node_modules',
        risk_level: 'high',
        detail: { command: 'rm -rf node_modules' },
        status: 'pending',
        requested_at: '2026-05-28T00:00:00Z',
        decided_at: null,
        decided_by_user_id: null,
      },
      {
        id: REQUEST_DECIDED,
        crew_session_id: SESSION_A,
        responsible_subject_id: SUBJECT_ALICE,
        requested_action: 'deploy',
        risk_level: 'medium',
        detail: {},
        status: 'approved',
        requested_at: '2026-05-28T00:00:00Z',
        decided_at: '2026-05-28T00:01:00Z',
        decided_by_user_id: USER_ALICE,
      },
    ],
    crew_sessions: [
      {
        id: SESSION_A,
        crew_conversation_id: CREW_ID,
        responsible_subject_id: SUBJECT_ALICE,
        permission_mode_override: null,
        status: 'running',
      },
    ],
    temporary_group_meta: [
      {
        conversation_id: CREW_ID,
        responsible_subject_id: SUBJECT_ALICE,
        temporary_kind: 'crew',
        status: 'active',
        permission_mode: 'auto',
      },
    ],
  });

  // Mirror the SQL ACL: decide_permission_request approves only when the
  // passed p_caller_user_id matches the subject's owner (user_account
  // case). For the test we stub the RPC and gate on p_caller_user_id.
  db.rpcs = {
    decide_permission_request: (args) => {
      const id = args.p_id as string;
      const callerId = args.p_caller_user_id as string;
      const decision = args.p_decision as string;
      const request = (db.rows.permission_requests as Array<Record<string, unknown>>).find((r) => r.id === id);
      if (!request) return { error: { code: 'P0002', message: 'permission request not found' } };
      if (request.status !== 'pending') {
        return { error: { code: '22023', message: 'permission request already decided' } };
      }
      const subjectId = request.responsible_subject_id as string;
      const subject = (db.rows.subjects as Array<Record<string, unknown>>).find((s) => s.id === subjectId);
      if (!subject) return { error: { code: 'P0002', message: 'responsible subject missing' } };
      if (subject.kind === 'user_account' && subject.user_id !== callerId) {
        return { error: { code: '42501', message: 'forbidden: only subject owner can decide' } };
      }
      request.status = decision === 'approve' ? 'approved' : 'denied';
      request.decided_at = '2026-05-28T00:05:00Z';
      request.decided_by_user_id = callerId;
      return { data: null };
    },
  };
  return db;
}

describe('POST /v1/permission-requests/:id/decide', () => {
  it('400 invalid_id for non-uuid', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request('/v1/permission-requests/not-uuid/decide', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
      body: JSON.stringify({ decision: 'approve' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_id');
  });

  it('400 invalid_body when decision is missing', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request(`/v1/permission-requests/${REQUEST_PENDING}/decide`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_body');
  });

  it('404 permission_request_not_found for unknown id', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request(
      '/v1/permission-requests/dddddddd-dddd-4ddd-8ddd-000000000099/decide',
      {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
        body: JSON.stringify({ decision: 'approve' }),
      },
    );
    expect(res.status).toBe(404);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('permission_request_not_found');
  });

  it('403 permission_request_forbidden when caller is not the subject owner', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request(`/v1/permission-requests/${REQUEST_PENDING}/decide`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_BOB },
      body: JSON.stringify({ decision: 'approve' }),
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('permission_request_forbidden');
  });

  it('409 permission_request_already_decided when row.status != pending', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request(`/v1/permission-requests/${REQUEST_DECIDED}/decide`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
      body: JSON.stringify({ decision: 'reject' }),
    });
    expect(res.status).toBe(409);
    const body = (await res.json()) as { error: { code: string; detail?: { status: string } } };
    expect(body.error.code).toBe('permission_request_already_decided');
    expect(body.error.detail?.status).toBe('approved');
  });

  it('approve happy path stamps decided_at + status=approved + returns the row', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request(`/v1/permission-requests/${REQUEST_PENDING}/decide`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
      body: JSON.stringify({ decision: 'approve' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      permissionRequest: { id: string; status: string; decided_by_user_id: string };
    };
    expect(body.permissionRequest.id).toBe(REQUEST_PENDING);
    expect(body.permissionRequest.status).toBe('approved');
    expect(body.permissionRequest.decided_by_user_id).toBe(USER_ALICE);
  });

  it('reject happy path stamps status=denied', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request(`/v1/permission-requests/${REQUEST_PENDING}/decide`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
      body: JSON.stringify({ decision: 'reject' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { permissionRequest: { status: string } };
    expect(body.permissionRequest.status).toBe('denied');
  });
});

describe('PATCH /v1/crews/:crewId/permission-mode', () => {
  it('400 invalid_id for non-uuid', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request('/v1/crews/not-uuid/permission-mode', {
      method: 'PATCH',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
      body: JSON.stringify({ mode: 'manual' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_id');
  });

  it('400 invalid_body for unknown mode value', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/permission-mode`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
      body: JSON.stringify({ mode: 'wild' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_body');
  });

  it('404 crew_not_found when crew row missing', async () => {
    const db = seedWithUserAccountSubject();
    db.rows.temporary_group_meta = [];
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/permission-mode`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
      body: JSON.stringify({ mode: 'manual' }),
    });
    expect(res.status).toBe(404);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('crew_not_found');
  });

  it('403 forbidden when caller is not the subject owner', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/permission-mode`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_BOB },
      body: JSON.stringify({ mode: 'manual' }),
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('forbidden');
  });

  it('updates permission_mode to manual and returns it', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/permission-mode`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
      body: JSON.stringify({ mode: 'manual' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { crewId: string; permissionMode: string };
    expect(body.crewId).toBe(CREW_ID);
    expect(body.permissionMode).toBe('manual');
  });
});

describe('PATCH /v1/sessions/:sessionId/permission-mode', () => {
  it('accepts null to clear the override', async () => {
    const db = seedWithUserAccountSubject();
    // Seed session with an existing override so we can see it cleared.
    (db.rows.crew_sessions as Array<Record<string, unknown>>)[0].permission_mode_override = 'manual';

    const res = await appFor(db).request(`/v1/sessions/${SESSION_A}/permission-mode`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
      body: JSON.stringify({ mode: null }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      sessionId: string;
      permissionModeOverride: string | null;
    };
    expect(body.sessionId).toBe(SESSION_A);
    expect(body.permissionModeOverride).toBeNull();
  });

  it('updates to manual', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request(`/v1/sessions/${SESSION_A}/permission-mode`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
      body: JSON.stringify({ mode: 'manual' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { permissionModeOverride: string };
    expect(body.permissionModeOverride).toBe('manual');
  });

  it('403 session_forbidden when caller is not the subject owner', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request(`/v1/sessions/${SESSION_A}/permission-mode`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_BOB },
      body: JSON.stringify({ mode: 'manual' }),
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('session_forbidden');
  });

  it('404 session_not_found when session missing', async () => {
    const db = seedWithUserAccountSubject();
    db.rows.crew_sessions = [];
    const res = await appFor(db).request(`/v1/sessions/${SESSION_A}/permission-mode`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
      body: JSON.stringify({ mode: 'auto' }),
    });
    expect(res.status).toBe(404);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('session_not_found');
  });

  it('400 invalid_body for unknown mode value', async () => {
    const db = seedWithUserAccountSubject();
    const res = await appFor(db).request(`/v1/sessions/${SESSION_A}/permission-mode`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER_ALICE },
      body: JSON.stringify({ mode: 'whatever' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_body');
  });
});
