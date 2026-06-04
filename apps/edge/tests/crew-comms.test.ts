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
import type { mapMessageToEntry as MapMessageToEntry } from '../src/routes/crew-comms';

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

// crew-comms now imports dispatchGroupTurn (to wake the captain on a crew
// message). Mock it so the test doesn't transitively pull the bot-reply +
// prompt-loader chain, and so we can assert the captain wake without an LLM turn.
const dispatchGroupTurnMock = vi.fn().mockResolvedValue({ status: 'dispatched', bubblesPerBot: [] });
vi.mock('../src/lib/group-dispatch', () => ({
  dispatchGroupTurn: dispatchGroupTurnMock,
}));

installFakeSupabaseMock();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let crewMessagesRoutes: any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let sessionInboxRoutes: any;
let mapMessageToEntry: typeof MapMessageToEntry;

beforeEach(async () => {
  ({ crewMessagesRoutes, sessionInboxRoutes, mapMessageToEntry } = await import('../src/routes/crew-comms'));
});

function appFor(db: FakeDb) {
  const app = new Hono<AppBindings>();
  app.route('/v1/crews', crewMessagesRoutes);
  app.route('/v1/sessions', sessionInboxRoutes);
  // crew message POST uses c.executionCtx.waitUntil (captain wake). Provide a
  // fake executionCtx so it's present in tests; the dispatch promise's creation
  // (and thus the mock call) is synchronous regardless of whether waitUntil runs.
  const executionCtx = {
    waitUntil: () => {},
    passThroughOnException: () => {},
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any;
  return {
    request: (path: string, init?: RequestInit) =>
      app.request(path, init, makeFakeEnv(db), executionCtx),
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

// J (spec §9): the crew chat IS the conversation's `messages`. POST inserts a
// user message + wakes the captain via dispatchGroupTurn (mocked).
describe('POST /v1/crews/:crewId/messages', () => {
  beforeEach(() => dispatchGroupTurnMock.mockClear());

  function seedCrew(db: FakeDb) {
    db.rows.temporary_group_meta = [
      { conversation_id: CREW_ID, responsible_subject_id: SUBJECT, captain_bot_id: CAPTAIN_BOT_ID },
    ];
    db.rpcs = { can_view_temporary_group: () => ({ data: true, error: null }) };
  }

  it('inserts a user message into the crew conversation and wakes the captain', async () => {
    const db = makeFakeDb();
    seedCrew(db);
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'hello crew' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { messageId: string };
    expect(body.messageId).toBeTruthy();
    const msgInsert = db.inserts.find((i) => i.table === 'messages');
    expect(msgInsert?.row).toMatchObject({
      conversation_id: CREW_ID,
      role: 'user',
      content: 'hello crew',
      user_id: USER,
    });
    expect(dispatchGroupTurnMock).toHaveBeenCalledTimes(1);
    expect(dispatchGroupTurnMock.mock.calls[0][0]).toMatchObject({
      conversationId: CREW_ID,
      wakeBotIds: [CAPTAIN_BOT_ID],
      reason: 'mention',
    });
  });

  it('rejects malformed body with 400 invalid_body', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: '' }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('invalid_body');
  });

  it('rejects invalid crewId format with 400 invalid_id', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request('/v1/crews/not-a-uuid/messages', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'hi' }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('invalid_id');
  });

  it('returns 404 when the crew does not exist', async () => {
    const db = makeFakeDb(); // no temporary_group_meta seeded
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'hi' }),
    });
    expect(res.status).toBe(404);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('not_found');
  });

  it('returns 403 when a JWT caller cannot view the crew', async () => {
    const db = makeFakeDb();
    db.rows.temporary_group_meta = [
      { conversation_id: CREW_ID, responsible_subject_id: SUBJECT, captain_bot_id: CAPTAIN_BOT_ID },
    ];
    db.rpcs = { can_view_temporary_group: () => ({ data: false, error: null }) };
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'hi' }),
    });
    expect(res.status).toBe(403);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('forbidden');
  });
});

describe('mapMessageToEntry sender identity', () => {
  const base = { id: 'm1', conversation_id: 'c1', created_at: '2026-06-04T00:00:00Z', log_kind: null, log_payload: null };

  it('user prose carries sender_user_id', () => {
    const e = mapMessageToEntry({ ...base, role: 'user', content: 'hi', user_id: 'u1', sender_bot_id: null } as any);
    expect(e.sender_kind).toBe('user');
    expect(e.sender_user_id).toBe('u1');
    expect(e.sender_bot_id).toBeNull();
  });

  it('bot reply carries sender_bot_id', () => {
    const e = mapMessageToEntry({ ...base, role: 'bot', content: 'yo', user_id: null, sender_bot_id: 'b1' } as any);
    expect(e.sender_kind).toBe('bot');
    expect(e.sender_bot_id).toBe('b1');
    expect(e.sender_user_id).toBeNull();
  });

  it('log/session card pulls session id from log_payload', () => {
    const e = mapMessageToEntry({ ...base, role: 'log', content: null, user_id: null, sender_bot_id: null,
      log_kind: 'interaction', log_payload: { kind: 'interaction', session_id: 's1', question: 'ok?' } } as any);
    expect(e.sender_kind).toBe('session');
    expect(e.sender_session_id).toBe('s1');
  });

  it('passes resolved attachments through; null when none', () => {
    const withAtt = mapMessageToEntry(
      { ...base, role: 'user', content: 'see this', user_id: 'u1', sender_bot_id: null } as any,
      [{ id: 'att-1', kind: 'image', mime: 'image/png', size: 123, width: 10, height: 20, url: '/v1/uploads/att-1', filename: null }],
    );
    expect(withAtt.attachments).toEqual([
      { id: 'att-1', kind: 'image', mime: 'image/png', size: 123, width: 10, height: 20, url: '/v1/uploads/att-1', filename: null },
    ]);

    const noAtt = mapMessageToEntry({ ...base, role: 'user', content: 'plain', user_id: 'u1', sender_bot_id: null } as any);
    expect(noAtt.attachments).toBeNull();
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

    // Whiteboard now reads the crew conversation's `messages` (spec §9 unified
    // store), not the get_crew_whiteboard RPC.
    db.rows.messages = [
      {
        id: 'a-1',
        conversation_id: CREW_ID,
        role: 'user',
        content: 'announcement one',
        user_id: USER,
        log_kind: null,
        log_payload: null,
        status: 'done',
        created_at: '2026-05-28T00:00:00Z',
      },
    ];
    db.rpcs = {
      can_view_temporary_group: () => ({ data: true, error: null }),
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

// post-to-crew endpoint is device-grant-only, which the bare requireSession
// mock doesn't satisfy. We skip the happy-path test (would need to seed a
// real subject_device_grants row + bypass requireSubjectAuth) and only pin
// the "supabase JWT path is rejected" contract — that runs through the
// mocked requireSession and lands in the explicit 403 branch.
describe('POST /v1/sessions/:sessionId/post-to-crew', () => {
  it('rejects supabase JWT (non-device-grant) callers with 403 forbidden', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request(`/v1/sessions/${SESSION_A}/post-to-crew`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'milestone hit' }),
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string; message?: string } };
    expect(body.error.code).toBe('forbidden');
    expect(body.error.message).toMatch(/device grant/i);
  });

  it('rejects bad uuid in path with 400 invalid_id', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request('/v1/sessions/not-uuid/post-to-crew', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'x' }),
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
