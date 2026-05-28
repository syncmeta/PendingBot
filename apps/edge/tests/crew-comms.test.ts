// Tests for the T4.1 session-↔-crew comms surface
// (apps/edge/src/routes/crew-comms.ts).
//
// Covers:
//   * POST /v1/crews/:crewId/messages  — mention resolution + RPC fan-out
//   * GET  /v1/sessions/:id/inbox      — visibility gating, whiteboard+mailbox+meta
//   * POST /v1/sessions/:id/inbox/mark-delivered — happy path + 403 cross-subject
//
// Uses the in-memory fake-supabase helper. RPCs are stubbed; we pin the
// route contract (status codes, RPC args, response shapes), not the
// underlying SQL — that's covered by inline migration tests on the DB
// side (crew_phase2_inline_tests etc).

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

// requireSession stub — supabase_jwt branch picks up x-test-user-id.
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
let crewMessagesRoutes: any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let sessionInboxRoutes: any;

beforeEach(async () => {
  ({ crewMessagesRoutes, sessionInboxRoutes } = await import('../src/routes/crew-comms'));
});

function appFor(db: FakeDb) {
  const app = new Hono<AppBindings>();
  app.route('/v1/crews', crewMessagesRoutes);
  app.route('/v1/sessions', sessionInboxRoutes);
  return {
    request: (path: string, init?: RequestInit) =>
      app.request(path, init, makeFakeEnv(db)),
  };
}

const USER = 'user-1';
const SUBJECT = '11111111-1111-4111-8111-aaaaaaaaaaaa';
const OTHER_SUBJECT = '22222222-2222-4222-8222-bbbbbbbbbbbb';
const CREW_ID = '33333333-3333-4333-8333-cccccccccccc';
const SESSION_A = '44444444-4444-4444-8444-dddddddddddd';
const SESSION_B = '55555555-5555-4555-8555-eeeeeeeeeeee';
const CAPTAIN_BOT_ID = '66666666-6666-4666-8666-ffffffffffff';
const CAPTAIN_MEMBER_ID = '77777777-7777-4777-8777-000000000001';
const ANNOUNCEMENT_ID = '88888888-8888-4888-8888-000000000002';

describe('POST /v1/crews/:crewId/messages', () => {
  it('fans out to all sessions when no mentions are given', async () => {
    const db = makeFakeDb();
    let seenArgs: Record<string, unknown> | undefined;
    db.rpcs = {
      create_crew_announcement: (args) => {
        seenArgs = args;
        return { data: ANNOUNCEMENT_ID, error: null };
      },
    };

    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'hello crew' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      announcementId: string;
      recipientSessionIds: string[];
    };
    expect(body.announcementId).toBe(ANNOUNCEMENT_ID);
    expect(body.recipientSessionIds).toEqual([]);
    expect(seenArgs).toMatchObject({
      p_crew_conversation_id: CREW_ID,
      p_recipient_session_ids: [],
      p_recipient_member_ids: [],
      p_message_kind: 'instruction',
      p_summary: 'hello crew',
    });
  });

  it('translates @session mention into recipient_session_ids', async () => {
    const db = makeFakeDb();
    let seenArgs: Record<string, unknown> | undefined;
    db.rpcs = {
      create_crew_announcement: (args) => {
        seenArgs = args;
        return { data: ANNOUNCEMENT_ID, error: null };
      },
    };

    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({
        content: 'hey worker',
        mentions: [{ kind: 'session', target_id: SESSION_A }],
      }),
    });
    expect(res.status).toBe(200);
    expect(seenArgs?.p_recipient_session_ids).toEqual([SESSION_A]);
    const body = (await res.json()) as { recipientSessionIds: string[] };
    expect(body.recipientSessionIds).toEqual([SESSION_A]);
  });

  it('resolves @captain into the captain bot member\'s active session', async () => {
    const db = makeFakeDb();
    db.rows.temporary_group_meta = [
      {
        conversation_id: CREW_ID,
        temporary_kind: 'crew',
        captain_bot_id: CAPTAIN_BOT_ID,
      },
    ];
    db.rows.temporary_group_members = [
      {
        id: CAPTAIN_MEMBER_ID,
        conversation_id: CREW_ID,
        bot_id: CAPTAIN_BOT_ID,
        status: 'active',
      },
    ];
    db.rows.crew_sessions = [
      {
        id: SESSION_B,
        crew_conversation_id: CREW_ID,
        assigned_to_member_id: CAPTAIN_MEMBER_ID,
        status: 'running',
        responsible_subject_id: SUBJECT,
      },
    ];

    let seenArgs: Record<string, unknown> | undefined;
    db.rpcs = {
      create_crew_announcement: (args) => {
        seenArgs = args;
        return { data: ANNOUNCEMENT_ID, error: null };
      },
    };

    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({
        content: 'captain wake up',
        mentions: [{ kind: 'captain' }],
      }),
    });
    expect(res.status).toBe(200);
    expect(seenArgs?.p_recipient_session_ids).toEqual([SESSION_B]);
  });

  it('rejects malformed body with 400 invalid_body', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: '' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_body');
  });

  it('rejects invalid crewId format with 400 invalid_id', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request('/v1/crews/not-a-uuid/messages', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'hi' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_id');
  });

  it('maps RPC forbidden into 403 forbidden', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      create_crew_announcement: () => ({
        data: null,
        error: { code: '42501', message: 'forbidden: not an active crew member' },
      }),
    };
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'hi' }),
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('forbidden');
  });

  it('maps "system" message_kind to announcement (DB enum)', async () => {
    const db = makeFakeDb();
    let seenArgs: Record<string, unknown> | undefined;
    db.rpcs = {
      create_crew_announcement: (args) => {
        seenArgs = args;
        return { data: ANNOUNCEMENT_ID, error: null };
      },
    };
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'crew kickoff', message_kind: 'system' }),
    });
    expect(res.status).toBe(200);
    expect(seenArgs?.p_message_kind).toBe('announcement');
  });
});

describe('GET /v1/sessions/:sessionId/inbox', () => {
  it('returns whiteboard + mailbox + crew metadata when caller can view crew', async () => {
    const db = makeFakeDb();
    db.rows.crew_sessions = [
      {
        id: SESSION_A,
        crew_conversation_id: CREW_ID,
        responsible_subject_id: SUBJECT,
        runner_host_id: null,
        runner_kind: 'local_claude_code',
        status: 'running',
        task_brief: 'do the thing',
        progress_summary: null,
        last_context_cursor: null,
        started_at: '2026-05-28T00:00:00Z',
        finished_at: null,
        created_at: '2026-05-28T00:00:00Z',
        updated_at: '2026-05-28T00:00:00Z',
        assigned_to_member_id: null,
        initiating_member_id: 'm-1',
      },
    ];
    db.rows.temporary_group_meta = [
      {
        conversation_id: CREW_ID,
        responsible_subject_id: SUBJECT,
        captain_bot_id: CAPTAIN_BOT_ID,
        runtime_kind: 'crew',
        runtime_location: 'local_host',
        working_directory: '/Users/me/proj',
        title: 'Test Crew',
        status: 'active',
        parent_temporary_group_id: null,
        root_temporary_group_id: null,
      },
    ];
    db.rows.temporary_group_members = [
      {
        id: 'm-1',
        conversation_id: CREW_ID,
        member_kind: 'human',
        user_id: USER,
        display_name: '我',
        role: 'owner',
        status: 'active',
      },
    ];
    db.rows.crew_responsibility_shares = [
      {
        crew_conversation_id: CREW_ID,
        subject_id: SUBJECT,
        share_bps: 10_000,
        is_tiebreaker: true,
      },
    ];
    db.rows.session_mailbox_items = [
      {
        id: 'mb-1',
        recipient_session_id: SESSION_A,
        crew_conversation_id: CREW_ID,
        sender_kind: 'human',
        message_kind: 'instruction',
        summary: 'check this out',
        payload: {},
        status: 'unread',
        created_at: '2026-05-28T00:00:01Z',
      },
      {
        id: 'mb-2',
        recipient_session_id: SESSION_A,
        crew_conversation_id: CREW_ID,
        sender_kind: 'human',
        message_kind: 'status',
        summary: 'already-processed-row',
        payload: {},
        status: 'processed',
        created_at: '2026-05-27T00:00:00Z',
      },
    ];

    db.rpcs = {
      can_view_temporary_group: () => ({ data: true, error: null }),
      get_crew_whiteboard: () => ({
        data: [
          { id: 'a-1', summary: 'announcement one', created_at: '2026-05-28T00:00:00Z' },
        ],
        error: null,
      }),
    };

    const res = await appFor(db).request(`/v1/sessions/${SESSION_A}/inbox`, {
      method: 'GET',
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      session: { id: string };
      crew: { meta: unknown; members: unknown[]; shares: unknown[] };
      whiteboard: unknown[];
      mailbox: unknown[];
    };
    expect(body.session.id).toBe(SESSION_A);
    expect(body.crew.meta).toBeTruthy();
    expect(body.crew.members.length).toBe(1);
    expect(body.crew.shares.length).toBe(1);
    expect(body.whiteboard.length).toBe(1);
    // Only the unread row should come back — 'processed' rows are filtered.
    expect(body.mailbox.length).toBe(1);
    expect((body.mailbox[0] as { id: string }).id).toBe('mb-1');
  });

  it('returns 404 session_not_found for unknown session', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request(`/v1/sessions/${SESSION_A}/inbox`, {
      method: 'GET',
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(404);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('session_not_found');
  });

  it('returns 403 session_forbidden when caller cannot view crew', async () => {
    const db = makeFakeDb();
    db.rows.crew_sessions = [
      {
        id: SESSION_A,
        crew_conversation_id: CREW_ID,
        responsible_subject_id: OTHER_SUBJECT,
        runner_kind: 'local_claude_code',
        status: 'running',
        task_brief: 'private',
      },
    ];
    db.rpcs = {
      can_view_temporary_group: () => ({ data: false, error: null }),
    };
    const res = await appFor(db).request(`/v1/sessions/${SESSION_A}/inbox`, {
      method: 'GET',
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('session_forbidden');
  });

  it('rejects bad sessionId with 400 invalid_id', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request('/v1/sessions/not-uuid/inbox', {
      method: 'GET',
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_id');
  });
});

describe('POST /v1/sessions/:sessionId/inbox/mark-delivered', () => {
  it('forwards item_ids to the RPC and returns updated count', async () => {
    const db = makeFakeDb();
    db.rows.crew_sessions = [
      {
        id: SESSION_A,
        crew_conversation_id: CREW_ID,
        responsible_subject_id: SUBJECT,
      },
    ];
    let seenArgs: Record<string, unknown> | undefined;
    db.rpcs = {
      mark_session_mailbox_delivered: (args) => {
        seenArgs = args;
        return { data: 2, error: null };
      },
    };
    const res = await appFor(db).request(`/v1/sessions/${SESSION_A}/inbox/mark-delivered`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ item_ids: ['11111111-1111-4111-8111-000000000001', '22222222-2222-4222-8222-000000000002'] }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { updated: number };
    expect(body.updated).toBe(2);
    expect(seenArgs).toMatchObject({
      p_session_id: SESSION_A,
      p_item_ids: ['11111111-1111-4111-8111-000000000001', '22222222-2222-4222-8222-000000000002'],
    });
  });

  it('rejects empty item_ids with 400 invalid_body', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request(`/v1/sessions/${SESSION_A}/inbox/mark-delivered`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ item_ids: [] }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_body');
  });

  it('returns 404 session_not_found when session does not exist', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request(`/v1/sessions/${SESSION_A}/inbox/mark-delivered`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ item_ids: ['11111111-1111-4111-8111-000000000001'] }),
    });
    expect(res.status).toBe(404);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('session_not_found');
  });
});
