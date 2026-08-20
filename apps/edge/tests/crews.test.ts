// Tests for the Phase 2 /v1/crews + /v1/share-changes surface (see
// apps/edge/src/routes/crews.ts + share-changes.ts). Companion to
// crew.test.ts, which covers the legacy /v1/crew (singular) surface.
//
// Uses the in-memory fake-supabase helper — we stub the RPCs and seed
// the rows the route reads from. The intent is to pin the *route
// contract*: status codes, error code mapping, request/response
// shapes. The RPCs themselves are exercised by the inline migration
// tests on the DB side.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import type { MiddlewareHandler } from 'hono';
import { installFakeSupabaseMock, makeFakeDb, makeFakeEnv } from './_helpers/fake-supabase';
import type { FakeDb } from './_helpers/fake-supabase';
import type { AppBindings } from '../src/types';

// Mock @pendingbot/identity::requireSession the same way crew.test.ts
// does — header `x-test-user-id` sets the caller; missing header → 401.
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
let crewsRoutes: any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let shareChangesRoutes: any;

beforeEach(async () => {
  ({ crewsRoutes } = await import('../src/routes/crews'));
  ({ shareChangesRoutes } = await import('../src/routes/share-changes'));
});

function appFor(db: FakeDb) {
  const app = new Hono<AppBindings>();
  app.route('/v1/crews', crewsRoutes);
  app.route('/v1/share-changes', shareChangesRoutes);
  return {
    request: (path: string, init?: RequestInit) =>
      app.request(path, init, makeFakeEnv(db)),
  };
}

const USER = 'user-1';
const USER_SUBJECT = '11111111-1111-4111-8111-aaaaaaaaaaaa';
const GROUP_SUBJECT = '22222222-2222-4222-8222-bbbbbbbbbbbb';
const CREW_ID = '33333333-3333-4333-8333-cccccccccccc';
const PARENT_CREW_ID = '44444444-4444-4444-8444-dddddddddddd';
const CAPTAIN_BOT_ID = '55555555-5555-4555-8555-eeeeeeeeeeee';
const OTHER_SUBJECT = '66666666-6666-4666-8666-ffffffffffff';
const CHANGE_ID = '77777777-7777-4777-8777-000000000000';

// Seeds the rows that `accessibleSubjectIds` (in crews.ts) reads to
// figure out which crews the caller is allowed to list/see. Without
// these rows GET /v1/crews returns an empty list regardless of the
// crew rows seeded.
function seedSubjectAccess(db: FakeDb) {
  db.rows.subjects = [
    ...(db.rows.subjects ?? []),
    {
      id: USER_SUBJECT,
      kind: 'user_account',
      user_id: USER,
      display_name: '我',
      status: 'active',
    },
    {
      id: GROUP_SUBJECT,
      kind: 'group_account',
      user_id: null,
      display_name: '工程团队',
      status: 'active',
    },
  ];
  db.rows.group_subject_members = [
    ...(db.rows.group_subject_members ?? []),
    {
      subject_id: GROUP_SUBJECT,
      user_id: USER,
      role: 'owner',
    },
  ];
}

describe('POST /v1/crews', () => {
  it('creates a crew via create_crew_with_captain and returns crewId + captainBotId', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      create_crew_with_captain: (args) => {
        expect(args).toMatchObject({
          p_responsible_subject_id: USER_SUBJECT,
          p_title: '工程 Crew',
          p_captain_source: 'system_generated',
        });
        // Seed the meta row the route SELECTs back to recover the
        // captain bot id.
        (db.rows.temporary_group_meta ??= []).push({
          conversation_id: CREW_ID,
          temporary_kind: 'crew',
          captain_bot_id: CAPTAIN_BOT_ID,
        });
        return { data: CREW_ID, error: null };
      },
    };

    const res = await appFor(db).request('/v1/crews', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({
        responsibleSubjectId: USER_SUBJECT,
        title: '工程 Crew',
        captain: { source:'system_generated' },
      }),
    });
    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({
      crewId: CREW_ID,
      captainBotId: CAPTAIN_BOT_ID,
    });
  });

  it('forwards reuse_bot captain.botId to the RPC', async () => {
    const reuseBotId = '88888888-8888-4888-8888-111111111111';
    const db = makeFakeDb();
    let seenArgs: Record<string, unknown> | undefined;
    db.rpcs = {
      create_crew_with_captain: (args) => {
        seenArgs = args;
        (db.rows.temporary_group_meta ??= []).push({
          conversation_id: CREW_ID,
          temporary_kind: 'crew',
          captain_bot_id: reuseBotId,
        });
        return { data: CREW_ID, error: null };
      },
    };
    const res = await appFor(db).request('/v1/crews', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({
        responsibleSubjectId: USER_SUBJECT,
        title: '工程 Crew',
        captain: { source:'reuse_bot', botId: reuseBotId },
      }),
    });
    expect(res.status).toBe(200);
    expect(seenArgs).toMatchObject({
      p_captain_source: 'reuse_bot',
      p_captain_bot_id: reuseBotId,
    });
  });

  it('maps RPC 42501 to 403 forbidden', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      create_crew_with_captain: () => ({
        data: null,
        error: { code: '42501', message: 'forbidden: caller cannot act for responsible subject' },
      }),
    };
    const res = await appFor(db).request('/v1/crews', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({
        responsibleSubjectId: USER_SUBJECT,
        title: '别人的 Crew',
        captain: { source: 'system_generated' },
      }),
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('forbidden');
  });

  it('rejects malformed body with 400 invalid_body', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request('/v1/crews', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ title: 'missing fields' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_body');
  });

  it('returns 401 when no session header is set', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request('/v1/crews', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        responsibleSubjectId: USER_SUBJECT,
        title: 'x',
        captain: { source: 'system_generated' },
      }),
    });
    expect(res.status).toBe(401);
  });
});

describe('POST /v1/crews/:crewId/attach-parent', () => {
  it('forwards childKeepsBps to crew_attach_as_child and returns ok', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      crew_attach_as_child: (args) => {
        expect(args).toEqual({
          p_child: CREW_ID,
          p_parent: PARENT_CREW_ID,
          p_child_keeps_bps: 4000,
        });
        return { data: null, error: null };
      },
    };
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/attach-parent`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ parentCrewId: PARENT_CREW_ID, childKeepsBps: 4000 }),
    });
    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ ok: true });
  });

  it('maps cycle-guard violation (23514) to 409 crew_cycle', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      crew_attach_as_child: () => ({
        data: null,
        error: { code: '23514', message: 'cycle detected: parent would become own ancestor' },
      }),
    };
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/attach-parent`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ parentCrewId: PARENT_CREW_ID, childKeepsBps: 4000 }),
    });
    expect(res.status).toBe(409);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('crew_cycle');
  });

  it('maps RPC 42501 to 403 crew_attach_forbidden', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      crew_attach_as_child: () => ({
        data: null,
        error: { code: '42501', message: 'forbidden: caller cannot act for child responsible subject' },
      }),
    };
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/attach-parent`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ parentCrewId: PARENT_CREW_ID, childKeepsBps: 4000 }),
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('crew_attach_forbidden');
  });

  it('rejects out-of-range childKeepsBps with 400 invalid_body (pre-RPC)', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/attach-parent`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ parentCrewId: PARENT_CREW_ID, childKeepsBps: 0 }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_body');
  });
});

describe('GET /v1/crews', () => {
  it('lists crews whose responsible subject the caller can see', async () => {
    const db = makeFakeDb({
      temporary_group_meta: [
        {
          conversation_id: CREW_ID,
          temporary_kind: 'crew',
          responsible_subject_id: USER_SUBJECT,
          captain_bot_id: CAPTAIN_BOT_ID,
          runtime_location: 'local_host',
          tag: 'engineering',
          title: '我的 Crew',
          created_at: '2026-05-28T00:00:00Z',
          updated_at: '2026-05-28T00:01:00Z',
          status: 'active',
        },
        {
          // Crew the caller can't see — different subject, no group
          // membership.
          conversation_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          temporary_kind: 'crew',
          responsible_subject_id: OTHER_SUBJECT,
          captain_bot_id: null,
          runtime_location: 'local_host',
          tag: null,
          title: '别人的 Crew',
          created_at: '2026-05-28T00:00:00Z',
          updated_at: '2026-05-28T00:01:00Z',
          status: 'active',
        },
      ],
    });
    seedSubjectAccess(db);

    const res = await appFor(db).request('/v1/crews', {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { crews: Array<{ id: string }> };
    expect(body.crews.map((c) => c.id)).toEqual([CREW_ID]);
  });

  it('returns an empty list when the caller has no subjects', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request('/v1/crews', {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ crews: [] });
  });
});

describe('GET /v1/crews/:crewId', () => {
  it('returns crew detail with parents, children, shares, and captain', async () => {
    const db = makeFakeDb({
      temporary_group_meta: [
        {
          conversation_id: CREW_ID,
          temporary_kind: 'crew',
          responsible_subject_id: USER_SUBJECT,
          captain_bot_id: CAPTAIN_BOT_ID,
          runtime_location: 'local_host',
          working_directory: '/repos/x',
          tag: 'engineering',
          title: '我的 Crew',
          created_at: '2026-05-28T00:00:00Z',
          updated_at: '2026-05-28T00:01:00Z',
          status: 'active',
        },
        {
          conversation_id: PARENT_CREW_ID,
          temporary_kind: 'crew',
          title: '平台部',
        },
      ],
      crew_parent_links: [
        {
          parent_crew_id: PARENT_CREW_ID,
          child_crew_id: CREW_ID,
          child_share_bps: 6000,
        },
      ],
      crew_responsibility_shares: [
        {
          crew_conversation_id: CREW_ID,
          subject_id: USER_SUBJECT,
          share_bps: 4000,
          is_tiebreaker: false,
        },
        {
          crew_conversation_id: CREW_ID,
          subject_id: GROUP_SUBJECT,
          share_bps: 6000,
          is_tiebreaker: true,
        },
      ],
      subjects: [
        { id: USER_SUBJECT, display_name: '我', kind: 'user_account' },
        { id: GROUP_SUBJECT, display_name: '工程团队', kind: 'group_account' },
      ],
      bots: [
        { id: CAPTAIN_BOT_ID, display_name: '机长' },
      ],
    });
    db.rpcs = {
      can_view_temporary_group: () => ({ data: true, error: null }),
    };

    const res = await appFor(db).request(`/v1/crews/${CREW_ID}`, {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.crew).toMatchObject({
      id: CREW_ID,
      title: '我的 Crew',
      responsibleSubjectId: USER_SUBJECT,
      runtimeLocation: 'local_host',
      captainBotId: CAPTAIN_BOT_ID,
    });
    expect(body.parents).toEqual([
      { crewId: PARENT_CREW_ID, title: '平台部', childShareBps: 6000 },
    ]);
    expect(body.children).toEqual([]);
    expect(body.shares).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          subjectId: USER_SUBJECT,
          shareBps: 4000,
          isTiebreaker: false,
          displayName: '我',
          kind: 'user_account',
        }),
        expect.objectContaining({
          subjectId: GROUP_SUBJECT,
          shareBps: 6000,
          isTiebreaker: true,
          displayName: '工程团队',
          kind: 'group_account',
        }),
      ]),
    );
    expect(body.captain).toEqual({ botId: CAPTAIN_BOT_ID, displayName: '机长' });
  });

  it('returns 404 crew_not_found when the caller cannot view the crew', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      can_view_temporary_group: () => ({ data: false, error: null }),
    };
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}`, {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(404);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('crew_not_found');
  });
});

describe('POST /v1/crews/:crewId/share-changes', () => {
  it('proposes a share change and returns the required subject set', async () => {
    const db = makeFakeDb({
      crew_responsibility_shares: [
        // Existing shares: one subject being kept, one being removed.
        { crew_conversation_id: CREW_ID, subject_id: USER_SUBJECT, share_bps: 5000 },
        { crew_conversation_id: CREW_ID, subject_id: OTHER_SUBJECT, share_bps: 5000 },
      ],
    });
    let seen: Record<string, unknown> | undefined;
    db.rpcs = {
      crew_propose_share_change: (args) => {
        seen = args;
        return { data: CHANGE_ID, error: null };
      },
    };
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/share-changes`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({
        proposedShares: [
          { subjectId: USER_SUBJECT, shareBps: 6000 },
          { subjectId: GROUP_SUBJECT, shareBps: 4000 },
        ],
        reason: '工程团队接管文档输出',
      }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { shareChangeId: string; requiresSubjectApprovals: string[] };
    expect(body.shareChangeId).toBe(CHANGE_ID);
    // Union of proposed + currently-holding subjects.
    expect(body.requiresSubjectApprovals.sort()).toEqual(
      [USER_SUBJECT, GROUP_SUBJECT, OTHER_SUBJECT].sort(),
    );
    expect(seen).toMatchObject({
      p_crew_id: CREW_ID,
      p_proposal_payload: expect.objectContaining({
        proposed_shares: [
          { subject_id: USER_SUBJECT, share_bps: 6000 },
          { subject_id: GROUP_SUBJECT, share_bps: 4000 },
        ],
        reason: '工程团队接管文档输出',
      }),
    });
  });

  it('rejects proposedShares whose share_bps does not sum to 10000', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/share-changes`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({
        proposedShares: [
          { subjectId: USER_SUBJECT, shareBps: 6000 },
          { subjectId: GROUP_SUBJECT, shareBps: 3000 },
        ],
      }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('crew_share_invalid');
  });

  it('maps RPC forbidden (42501) to 403 crew_share_change_forbidden', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      crew_propose_share_change: () => ({
        data: null,
        error: { code: '42501', message: 'forbidden: cannot view crew' },
      }),
    };
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/share-changes`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({
        proposedShares: [
          { subjectId: USER_SUBJECT, shareBps: 5000 },
          { subjectId: GROUP_SUBJECT, shareBps: 5000 },
        ],
      }),
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('crew_share_change_forbidden');
  });
});

describe('POST /v1/share-changes/:id/decision', () => {
  it('approves via crew_approve_share_change and returns the updated row', async () => {
    const db = makeFakeDb({
      crew_pending_share_changes: [
        {
          id: CHANGE_ID,
          crew_id: CREW_ID,
          status: 'approved',
          approvals: { [USER_SUBJECT]: { by_user_id: USER, at: '2026-05-28T00:00:00Z' } },
        },
      ],
    });
    db.rpcs = {
      crew_approve_share_change: (args) => {
        expect(args).toEqual({ p_change_id: CHANGE_ID, p_subject_id: USER_SUBJECT });
        return { data: 'approved', error: null };
      },
    };
    const res = await appFor(db).request(`/v1/share-changes/${CHANGE_ID}/decision`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ decision: 'approved', asSubjectId: USER_SUBJECT }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { status: string };
    expect(body.status).toBe('approved');
  });

  it('rejects pending proposals via service-role update when caller has owner/admin on the subject', async () => {
    const db = makeFakeDb({
      crew_pending_share_changes: [
        {
          id: CHANGE_ID,
          crew_id: CREW_ID,
          status: 'pending',
          approvals: {},
          requires_subject_approvals: [USER_SUBJECT, GROUP_SUBJECT],
        },
      ],
    });
    db.rpcs = {
      subject_user_has_role: (args) => {
        expect(args).toMatchObject({
          p_subject_id: USER_SUBJECT,
          p_user_id: USER,
          p_roles: ['owner', 'admin'],
        });
        return { data: true, error: null };
      },
    };
    const res = await appFor(db).request(`/v1/share-changes/${CHANGE_ID}/decision`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({
        decision: 'rejected',
        asSubjectId: USER_SUBJECT,
        note: '比例与现状不符',
      }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { status: string; approvals: Record<string, unknown> };
    expect(body.status).toBe('rejected');
    expect(body.approvals[USER_SUBJECT]).toMatchObject({
      decision: 'rejected',
      by_user_id: USER,
      note: '比例与现状不符',
    });
    // Verify the row got updated in-place.
    const row = db.rows.crew_pending_share_changes?.[0];
    expect(row?.status).toBe('rejected');
    expect(row?.decided_at).toBeTruthy();
  });

  it('rejects a reject-decision when asSubjectId is not in requires_subject_approvals', async () => {
    const db = makeFakeDb({
      crew_pending_share_changes: [
        {
          id: CHANGE_ID,
          crew_id: CREW_ID,
          status: 'pending',
          approvals: {},
          requires_subject_approvals: [USER_SUBJECT],
        },
      ],
    });
    const res = await appFor(db).request(`/v1/share-changes/${CHANGE_ID}/decision`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({
        decision: 'rejected',
        asSubjectId: OTHER_SUBJECT,
      }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('crew_share_invalid');
  });
});

describe('GET /v1/share-changes/pending', () => {
  it('returns proposals the caller still has to decide on, hydrated with crew title', async () => {
    const db = makeFakeDb({
      crew_pending_share_changes: [
        {
          id: CHANGE_ID,
          crew_id: CREW_ID,
          proposed_by: 'user-2',
          proposal_payload: { proposed_shares: [] },
          approvals: {},
          requires_subject_approvals: [USER_SUBJECT, OTHER_SUBJECT],
          status: 'pending',
          created_at: '2026-05-28T01:00:00Z',
        },
        {
          id: '99999999-9999-4999-8999-000000000000',
          crew_id: CREW_ID,
          proposed_by: 'user-3',
          proposal_payload: {},
          // Caller already recorded a decision → should be filtered out.
          approvals: { [USER_SUBJECT]: { decision: 'approved' } },
          requires_subject_approvals: [USER_SUBJECT],
          status: 'pending',
          created_at: '2026-05-28T00:00:00Z',
        },
        {
          id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          crew_id: CREW_ID,
          proposal_payload: {},
          approvals: {},
          // Caller is not in the required set → filtered.
          requires_subject_approvals: [OTHER_SUBJECT],
          status: 'pending',
          created_at: '2026-05-28T00:00:00Z',
        },
      ],
      temporary_group_meta: [
        { conversation_id: CREW_ID, title: '工程 Crew' },
      ],
    });
    seedSubjectAccess(db);

    const res = await appFor(db).request('/v1/share-changes/pending', {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { pending: Array<{ id: string; crewTitle: string; mySubjectId: string }> };
    expect(body.pending).toHaveLength(1);
    expect(body.pending[0]).toMatchObject({
      id: CHANGE_ID,
      crewTitle: '工程 Crew',
      mySubjectId: USER_SUBJECT,
    });
  });

  it('returns an empty list when the caller has no actionable subjects', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request('/v1/share-changes/pending', {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ pending: [] });
  });
});
