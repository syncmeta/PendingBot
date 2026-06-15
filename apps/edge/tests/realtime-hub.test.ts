// Tests for the realtime-hub read-side route auth gate
// (apps/edge/src/routes/realtime-hub.ts).
//
// Focus: the conv topic now accepts BOTH a Supabase JWT (membership via
// resolveConv) AND a PendingCrew device-grant (`pdg_*`), where the grant's
// subject must match the crew's responsible_subject_id. The /user topic stays
// JWT-only (device-grant has no user dimension).
//
// The WebSocket upgrade itself is forwarded to the RealtimeHubDO; here we mock
// REALTIME_HUB with a capturing stub so a successful auth pass is observable as
// a 101 with the topic key + X-Hub-User-Id header it forwarded. We pin the
// auth/forward contract, not the DO fan-out (that's hub.ts's own concern).

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

// requireSession stub — supabase_jwt branch picks up x-test-user-id. Mirrors
// crew-comms.test.ts so the device-grant-vs-JWT split runs through the real
// requireSubjectAuth (which falls back to this stub for non-pdg_ tokens).
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
let realtimeHubRoutes: any;

beforeEach(async () => {
  ({ realtimeHubRoutes } = await import('../src/routes/realtime-hub'));
});

const USER = 'user-1';
const SUBJECT = '11111111-1111-4111-8111-aaaaaaaaaaaa';
const OTHER_SUBJECT = '22222222-2222-4222-8222-bbbbbbbbbbbb';
const CREW_ID = '33333333-3333-4333-8333-cccccccccccc';

// Captures every handoff to the hub DO: which topic key (idFromName) and which
// X-Hub-User-Id header the worker stamped. The real DO answers a WS upgrade
// with a 101, but node's undici rejects `new Response(null, { status: 101 })`
// (status must be 200–599), so the stub returns a 200 marker — reaching it at
// all is the signal that the auth gate passed and forwarding happened.
interface HubCapture {
  keys: string[];
  hubUserIds: string[];
}
const FORWARDED = 200;

function envWithHub(db: FakeDb): { env: ReturnType<typeof makeFakeEnv>; hub: HubCapture } {
  const hub: HubCapture = { keys: [], hubUserIds: [] };
  const env = makeFakeEnv(db);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (env as any).REALTIME_HUB = {
    idFromName: (name: string) => ({ __key: name }),
    get: (id: { __key: string }) => ({
      fetch: (req: Request) => {
        hub.keys.push(id.__key);
        hub.hubUserIds.push(req.headers.get('X-Hub-User-Id') ?? '');
        return Promise.resolve(new Response('forwarded', { status: FORWARDED }));
      },
    }),
  };
  return { env, hub };
}

function appFor(env: ReturnType<typeof makeFakeEnv>) {
  const app = new Hono<AppBindings>();
  app.route('/v1/realtime-hub', realtimeHubRoutes);
  const executionCtx = {
    waitUntil: () => {},
    passThroughOnException: () => {},
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any;
  return {
    request: (path: string, init?: RequestInit) =>
      app.request(path, init, env, executionCtx),
  };
}

const DEVICE_TOKEN = 'pdg_test_token';
async function seedDeviceGrant(db: FakeDb, subjectId: string, scopes = ['crew:read', 'crew:write']) {
  const bytes = new TextEncoder().encode(DEVICE_TOKEN);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  const tokenHash = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
  db.rows.subject_device_grants = [
    {
      id: 'grant-1',
      token_hash: tokenHash,
      subject_id: subjectId,
      granted_by_user_id: USER,
      grant_kind: 'mac_app',
      scopes,
      app_kind: 'pendingcrew',
      status: 'active',
      expires_at: null,
    },
  ];
}

function seedCrewConv(db: FakeDb) {
  // The conv topic key is the crew conversation id; the device-grant gate
  // resolves responsible_subject_id off temporary_group_meta. The JWT path
  // reads the conversations row (group type → resolveConv RLS).
  db.rows.temporary_group_meta = [
    { conversation_id: CREW_ID, responsible_subject_id: SUBJECT, captain_bot_id: null },
  ];
  db.rows.conversations = [
    { id: CREW_ID, conversation_type: 'group', bot_id: null, user_id: null, round_count: 0, current_model_slug: null, current_model_provider: null },
  ];
}

const WS = { Upgrade: 'websocket' };

// ── device-grant on conv topic ──────────────────────────────────────

describe('GET /v1/realtime-hub/conv/:id — device-grant', () => {
  it('forwards to the hub when the grant subject matches the crew', async () => {
    const db = makeFakeDb();
    seedCrewConv(db);
    await seedDeviceGrant(db, SUBJECT);
    const { env, hub } = envWithHub(db);
    const res = await appFor(env).request(`/v1/realtime-hub/conv/${CREW_ID}`, {
      headers: { ...WS, authorization: `Bearer ${DEVICE_TOKEN}` },
    });
    expect(res.status).toBe(FORWARDED);
    expect(hub.keys).toEqual([`conv:${CREW_ID}`]);
    // X-Hub-User-Id under a device grant is the granting user (stable, never
    // crashes the DO which only uses it as a label).
    expect(hub.hubUserIds).toEqual([USER]);
  });

  it('rejects a device-grant whose subject does not own the crew (403)', async () => {
    const db = makeFakeDb();
    seedCrewConv(db);
    await seedDeviceGrant(db, OTHER_SUBJECT);
    const { env, hub } = envWithHub(db);
    const res = await appFor(env).request(`/v1/realtime-hub/conv/${CREW_ID}`, {
      headers: { ...WS, authorization: `Bearer ${DEVICE_TOKEN}` },
    });
    expect(res.status).toBe(403);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('forbidden');
    expect(hub.keys).toEqual([]);
  });

  it('returns 404 when the conv is not a crew (no temporary_group_meta) for a device-grant', async () => {
    const db = makeFakeDb();
    // No temporary_group_meta row — device-grant can only reach crew topics.
    await seedDeviceGrant(db, SUBJECT);
    const { env, hub } = envWithHub(db);
    const res = await appFor(env).request(`/v1/realtime-hub/conv/${CREW_ID}`, {
      headers: { ...WS, authorization: `Bearer ${DEVICE_TOKEN}` },
    });
    expect(res.status).toBe(404);
    expect(hub.keys).toEqual([]);
  });
});

// ── JWT on conv topic (regression: behaviour unchanged) ─────────────

describe('GET /v1/realtime-hub/conv/:id — supabase JWT', () => {
  it('still forwards a member (resolveConv resolves) to the hub', async () => {
    const db = makeFakeDb();
    // Single-owner conv owned by USER → resolveConv local membership passes.
    db.rows.conversations = [
      { id: CREW_ID, conversation_type: 'user_bot', bot_id: 'b1', user_id: USER, round_count: 0, current_model_slug: null, current_model_provider: null },
    ];
    const { env, hub } = envWithHub(db);
    const res = await appFor(env).request(`/v1/realtime-hub/conv/${CREW_ID}`, {
      headers: { ...WS, 'x-test-user-id': USER },
    });
    expect(res.status).toBe(FORWARDED);
    expect(hub.keys).toEqual([`conv:${CREW_ID}`]);
    expect(hub.hubUserIds).toEqual([USER]);
  });

  it('returns 404 when resolveConv finds no conversation (no access)', async () => {
    // The fake DB has no RLS, so "non-member" is expressed as resolveConv → null
    // (no conversations row matches). The JWT branch still 404s, unchanged.
    const db = makeFakeDb();
    const { env, hub } = envWithHub(db);
    const res = await appFor(env).request(`/v1/realtime-hub/conv/${CREW_ID}`, {
      headers: { ...WS, 'x-test-user-id': USER },
    });
    expect(res.status).toBe(404);
    expect(hub.keys).toEqual([]);
  });

  it('rejects a JWT-less, token-less caller with 401', async () => {
    const db = makeFakeDb();
    seedCrewConv(db);
    const { env, hub } = envWithHub(db);
    const res = await appFor(env).request(`/v1/realtime-hub/conv/${CREW_ID}`, {
      headers: { ...WS },
    });
    expect(res.status).toBe(401);
    expect(hub.keys).toEqual([]);
  });
});

// ── /user topic stays JWT-only ──────────────────────────────────────

describe('GET /v1/realtime-hub/user — auth surface', () => {
  it('forwards a JWT caller to their own user hub', async () => {
    const db = makeFakeDb();
    const { env, hub } = envWithHub(db);
    const res = await appFor(env).request('/v1/realtime-hub/user', {
      headers: { ...WS, 'x-test-user-id': USER },
    });
    expect(res.status).toBe(FORWARDED);
    expect(hub.keys).toEqual([`user:${USER}`]);
    expect(hub.hubUserIds).toEqual([USER]);
  });

  it('does NOT widen for a device-grant — pdg_ token is not a valid JWT → 401', async () => {
    const db = makeFakeDb();
    await seedDeviceGrant(db, SUBJECT);
    const { env, hub } = envWithHub(db);
    const res = await appFor(env).request('/v1/realtime-hub/user', {
      headers: { ...WS, authorization: `Bearer ${DEVICE_TOKEN}` },
    });
    expect(res.status).toBe(401);
    expect(hub.keys).toEqual([]);
  });
});
