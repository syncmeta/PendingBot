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
  // Provide a fake executionCtx so app.request has the 4th arg some Hono
  // helpers expect; crew-comms no longer schedules background work here.
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
// user message; the local runner picks it up via its session mailbox (edge is
// the postman — no edge-bot captain wake, retired with the bot-captain model).
describe('POST /v1/crews/:crewId/messages', () => {
  function seedCrew(db: FakeDb) {
    db.rows.temporary_group_meta = [
      { conversation_id: CREW_ID, responsible_subject_id: SUBJECT, captain_bot_id: CAPTAIN_BOT_ID },
    ];
    db.rpcs = { can_view_temporary_group: () => ({ data: true, error: null }) };
  }

  it('inserts a user message into the crew conversation', async () => {
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

// 定向信箱投递:@ 某个 session / captain 时,除广播外额外往目标 session 的
// 定向信箱投一条(enqueue_session_mailbox RPC)。@broadcast / 无 mention 维持
// 现状(只进 messages 广播,不写信箱)。
describe('POST /v1/crews/:crewId/messages — mention → session mailbox', () => {

  // Capture every enqueue_session_mailbox RPC call so we can assert which
  // sessions got a directed mailbox row (the fake stubs the RPC; the real
  // insert is covered by the migration's inline SQL tests).
  function seedWithMailboxCapture(db: FakeDb): { enqueues: Record<string, unknown>[] } {
    db.rows.temporary_group_meta = [
      { conversation_id: CREW_ID, responsible_subject_id: SUBJECT, captain_bot_id: CAPTAIN_BOT_ID, temporary_kind: 'crew' },
    ];
    const enqueues: Record<string, unknown>[] = [];
    db.rpcs = {
      can_view_temporary_group: () => ({ data: true, error: null }),
      enqueue_session_mailbox: (args) => {
        enqueues.push(args);
        return { data: crypto.randomUUID(), error: null };
      },
    };
    return { enqueues };
  }

  it('@session enqueues a directed mailbox row for that session only + still inserts the message', async () => {
    const db = makeFakeDb();
    const { enqueues } = seedWithMailboxCapture(db);
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: '@A 看下这个', mentions: [{ kind: 'session', target_id: SESSION_A }] }),
    });
    expect(res.status).toBe(200);
    const { messageId } = (await res.json()) as { messageId: string };

    // The human message still lands in the crew conversation's messages.
    const msgInsert = db.inserts.find((i) => i.table === 'messages');
    expect(msgInsert?.row).toMatchObject({ conversation_id: CREW_ID, role: 'user', content: '@A 看下这个' });

    // Exactly one directed mailbox enqueue, for SESSION_A, linked back to the
    // inserted message id.
    expect(enqueues.length).toBe(1);
    expect(enqueues[0]).toMatchObject({
      p_session_id: SESSION_A,
      p_source_message_id: messageId,
    });
    // No other session received a directed row.
    expect(enqueues.some((e) => e.p_session_id === SESSION_B)).toBe(false);
  });

  it('deduplicates: a session mentioned twice only gets one mailbox row', async () => {
    const db = makeFakeDb();
    const { enqueues } = seedWithMailboxCapture(db);
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({
        content: 'double mention',
        mentions: [
          { kind: 'session', target_id: SESSION_A },
          { kind: 'session', target_id: SESSION_A },
        ],
      }),
    });
    expect(res.status).toBe(200);
    expect(enqueues.length).toBe(1);
    expect(enqueues[0]).toMatchObject({ p_session_id: SESSION_A });
  });

  it('empty mentions → broadcast only, no mailbox enqueue, message still inserted', async () => {
    const db = makeFakeDb();
    const { enqueues } = seedWithMailboxCapture(db);
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'hello everyone' }),
    });
    expect(res.status).toBe(200);
    expect(db.inserts.find((i) => i.table === 'messages')).toBeTruthy();
    expect(enqueues.length).toBe(0);
  });

  it('@broadcast → no mailbox enqueue (fan-out to everyone via the whiteboard)', async () => {
    const db = makeFakeDb();
    const { enqueues } = seedWithMailboxCapture(db);
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'attention all', mentions: [{ kind: 'broadcast' }] }),
    });
    expect(res.status).toBe(200);
    expect(enqueues.length).toBe(0);
  });

  it('@captain resolves to the captain bot\'s active session and enqueues a mailbox row', async () => {
    const db = makeFakeDb();
    const { enqueues } = seedWithMailboxCapture(db);
    // captain bot → active member → its assigned, non-terminal session.
    db.rows.temporary_group_members = [
      { id: CAPTAIN_MEMBER_ID, conversation_id: CREW_ID, bot_id: CAPTAIN_BOT_ID, status: 'active', created_at: '2026-06-01T00:00:00Z' },
    ];
    db.rows.crew_sessions = [
      { id: SESSION_A, crew_conversation_id: CREW_ID, assigned_to_member_id: CAPTAIN_MEMBER_ID, status: 'running' },
    ];
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: '@captain status?', mentions: [{ kind: 'captain' }] }),
    });
    expect(res.status).toBe(200);
    expect(enqueues.length).toBe(1);
    expect(enqueues[0]).toMatchObject({ p_session_id: SESSION_A });
  });

  it('session mention missing target_id → 400 invalid_body', async () => {
    const db = makeFakeDb();
    seedWithMailboxCapture(db);
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      // a session mention with no target_id is a malformed @ — the resolver
      // returns a validation error which the handler surfaces as invalid_body.
      body: JSON.stringify({ content: 'oops', mentions: [{ kind: 'session' }] }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('invalid_body');
  });
});

// 接合 v2 block 3 — relay 信箱:lastCursor / mac_relay 上行标注 / 成员邀请。

// device-grant 路径:seed 一行 subject_device_grants,token_hash 用与
// lib/device-grants.ts 相同的 sha256(hex)。
const DEVICE_TOKEN = 'pdg_test_token';
async function seedDeviceGrant(db: FakeDb, subjectId: string) {
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
      scopes: ['crew:read', 'crew:write'],
      app_kind: 'pendingcrew',
      status: 'active',
      expires_at: null,
    },
  ];
}

describe('GET /v1/crews/:crewId/messages — lastCursor (接合 v2 block 3)', () => {
  function seed(db: FakeDb) {
    db.rows.temporary_group_meta = [
      { conversation_id: CREW_ID, responsible_subject_id: SUBJECT, captain_bot_id: CAPTAIN_BOT_ID },
    ];
    db.rpcs = { can_view_temporary_group: () => ({ data: true, error: null }) };
  }

  it('returns lastCursor = max created_at among returned rows', async () => {
    const db = makeFakeDb();
    seed(db);
    db.rows.messages = [
      { id: 'm1', conversation_id: CREW_ID, role: 'user', content: 'a', user_id: USER, log_kind: null, log_payload: null, attachments: null, status: 'done', created_at: '2026-06-11T00:00:01Z' },
      { id: 'm2', conversation_id: CREW_ID, role: 'bot', content: 'b', user_id: null, sender_bot_id: CAPTAIN_BOT_ID, log_kind: null, log_payload: null, attachments: null, status: 'done', created_at: '2026-06-11T00:00:02Z' },
    ];
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { whiteboard: unknown[]; lastCursor: string | null };
    expect(body.whiteboard.length).toBe(2);
    expect(body.lastCursor).toBe('2026-06-11T00:00:02Z');
  });

  it('returns lastCursor = null when no rows', async () => {
    const db = makeFakeDb();
    seed(db);
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { whiteboard: unknown[]; lastCursor: string | null };
    expect(body.whiteboard.length).toBe(0);
    expect(body.lastCursor).toBeNull();
  });

  // Phase 3:白板读模型透出发送者显示名 —— 人类经 user_id→member.display_name,
  // session 帖经 log_payload.session_id→code_session member.display_name。一次性
  // 把 roster 查出来做 map(不 N+1)。
  it('resolves sender_display_name for human + session rows via the roster', async () => {
    const db = makeFakeDb();
    seed(db);
    db.rows.temporary_group_members = [
      { id: 'mem-human', conversation_id: CREW_ID, member_kind: 'human', user_id: USER,
        display_name: '阿强', status: 'active' },
      { id: 'mem-sess', conversation_id: CREW_ID, member_kind: 'code_session',
        code_session_id: SESSION_A, display_name: '小绿', status: 'active' },
    ];
    db.rows.messages = [
      { id: 'm1', conversation_id: CREW_ID, role: 'user', content: '人类说', user_id: USER,
        sender_bot_id: null, log_kind: null, log_payload: null, attachments: null, status: 'done',
        created_at: '2026-06-11T00:00:01Z' },
      { id: 'm2', conversation_id: CREW_ID, role: 'log', content: '进度', user_id: null,
        sender_bot_id: null, log_kind: 'session_post',
        log_payload: { session_id: SESSION_A, text: '进度' }, attachments: null, status: 'done',
        created_at: '2026-06-11T00:00:02Z' },
    ];
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      whiteboard: Array<{ id: string; sender_kind: string; sender_display_name: string | null; sender_member_id: string | null }>;
    };
    const human = body.whiteboard.find((e) => e.id === 'm1')!;
    const session = body.whiteboard.find((e) => e.id === 'm2')!;
    expect(human.sender_display_name).toBe('阿强');
    expect(human.sender_member_id).toBe('mem-human');
    expect(session.sender_kind).toBe('session');
    expect(session.sender_display_name).toBe('小绿');
    expect(session.sender_member_id).toBe('mem-sess');
  });

  it('leaves sender_display_name null when no roster match', async () => {
    const db = makeFakeDb();
    seed(db);
    // No members seeded → nothing to resolve; entries must still come back.
    db.rows.messages = [
      { id: 'm1', conversation_id: CREW_ID, role: 'user', content: 'orphan', user_id: 'stranger',
        sender_bot_id: null, log_kind: null, log_payload: null, attachments: null, status: 'done',
        created_at: '2026-06-11T00:00:01Z' },
    ];
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      whiteboard: Array<{ sender_display_name: string | null }>;
    };
    expect(body.whiteboard.length).toBe(1);
    expect(body.whiteboard[0].sender_display_name).toBeNull();
  });
});

describe('POST /v1/crews/:crewId/messages — mac_relay 上行标注 (接合 v2 block 3)', () => {
  function seed(db: FakeDb) {
    db.rows.temporary_group_meta = [
      { conversation_id: CREW_ID, responsible_subject_id: SUBJECT, captain_bot_id: CAPTAIN_BOT_ID },
    ];
    db.rpcs = { can_view_temporary_group: () => ({ data: true, error: null }) };
  }

  it('device-grant uplink with senderLabel/localSessionId carries origin mac_relay', async () => {
    const db = makeFakeDb();
    seed(db);
    await seedDeviceGrant(db, SUBJECT);
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${DEVICE_TOKEN}` },
      body: JSON.stringify({ content: 'relayed from mac', senderLabel: '机长', localSessionId: 'local-sess-1' }),
    });
    expect(res.status).toBe(200);
    const msgInsert = db.inserts.find((i) => i.table === 'messages');
    expect(msgInsert?.row).toMatchObject({
      conversation_id: CREW_ID,
      role: 'user',
      content: 'relayed from mac',
      attachments: { origin: 'mac_relay', senderLabel: '机长', localSessionId: 'local-sess-1' },
    });
  });

  it('JWT callers cannot set the mac_relay marker (senderLabel ignored)', async () => {
    const db = makeFakeDb();
    seed(db);
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'hello', senderLabel: 'spoof' }),
    });
    expect(res.status).toBe(200);
    const msgInsert = db.inserts.find((i) => i.table === 'messages');
    expect(msgInsert?.row.attachments ?? null).toBeNull();
  });
});

// #242 遥控 v1:iOS 发结构化 task_request,Mac relay 拉取后本地起 session。
describe('POST /v1/crews/:crewId/messages — message_kind=task_request (#242)', () => {

  function seed(db: FakeDb) {
    db.rows.temporary_group_meta = [
      { conversation_id: CREW_ID, responsible_subject_id: SUBJECT, captain_bot_id: CAPTAIN_BOT_ID },
    ];
    db.rpcs = { can_view_temporary_group: () => ({ data: true, error: null }) };
  }

  it('stores payload on log_kind/log_payload and roundtrips through GET', async () => {
    const db = makeFakeDb();
    seed(db);
    const payload = { action: 'run_session', runner_kind: 'claude_code', task_brief: '修登录 bug' };
    const post = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: '远程起一个 session', message_kind: 'task_request', payload }),
    });
    expect(post.status).toBe(200);
    const msgInsert = db.inserts.find((i) => i.table === 'messages');
    expect(msgInsert?.row).toMatchObject({
      conversation_id: CREW_ID,
      role: 'user',
      content: '远程起一个 session',
      log_kind: 'task_request',
      log_payload: payload,
    });

    const get = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      headers: { 'x-test-user-id': USER },
    });
    expect(get.status).toBe(200);
    const body = (await get.json()) as {
      whiteboard: Array<{ message_kind: string; payload: Record<string, unknown>; summary: string | null }>;
    };
    expect(body.whiteboard.length).toBe(1);
    expect(body.whiteboard[0].message_kind).toBe('task_request');
    expect(body.whiteboard[0].payload).toMatchObject({ text: '远程起一个 session', ...payload });
  });

  it('plain text messages keep log_kind null and payload = { text }', async () => {
    const db = makeFakeDb();
    seed(db);
    const post = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'just chatting' }),
    });
    expect(post.status).toBe(200);
    const msgInsert = db.inserts.find((i) => i.table === 'messages');
    expect(msgInsert?.row.log_kind ?? null).toBeNull();
    const get = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      headers: { 'x-test-user-id': USER },
    });
    const body = (await get.json()) as {
      whiteboard: Array<{ message_kind: string; payload: Record<string, unknown> }>;
    };
    expect(body.whiteboard[0].message_kind).toBe('text');
    expect(body.whiteboard[0].payload).toEqual({ text: 'just chatting' });
  });
});

// #377 — 人发消息的 reply_to 可见引用。沿用 jsonb 方案(不加列):reply_to
// 落进人类消息的 attachments jsonb(`in_reply_to`),GET 白板经 mapMessageToEntry
// 统一透出 entry.in_reply_to。session 帖的 in_reply_to(log_payload.in_reply_to)
// 也走同一字段透出。
describe('POST /v1/crews/:crewId/messages — reply_to 可见引用 (#377)', () => {

  const REPLIED = '11111111-2222-4333-8444-555555555555';

  function seed(db: FakeDb) {
    db.rows.temporary_group_meta = [
      { conversation_id: CREW_ID, responsible_subject_id: SUBJECT, captain_bot_id: CAPTAIN_BOT_ID },
    ];
    db.rpcs = { can_view_temporary_group: () => ({ data: true, error: null }) };
  }

  function seedRepliedMessage(db: FakeDb) {
    db.rows.messages = [
      { id: REPLIED, conversation_id: CREW_ID, role: 'user', content: '原始消息', user_id: USER,
        sender_bot_id: null, log_kind: null, log_payload: null, attachments: null, status: 'done',
        created_at: '2026-06-11T00:00:01Z' },
    ];
  }

  it('persists in_reply_to into the human message attachments jsonb', async () => {
    const db = makeFakeDb();
    seed(db);
    seedRepliedMessage(db);
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: '回复一下', reply_to: REPLIED }),
    });
    expect(res.status).toBe(200);
    const msgInsert = db.inserts.find((i) => i.table === 'messages');
    expect(msgInsert?.row).toMatchObject({
      conversation_id: CREW_ID,
      role: 'user',
      content: '回复一下',
      attachments: { in_reply_to: REPLIED },
    });
  });

  it('co-exists with attachment ids in the same jsonb cell', async () => {
    const db = makeFakeDb();
    seed(db);
    seedRepliedMessage(db);
    const ATT = '99999999-9999-4999-8999-000000000077';
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: '看图回复', reply_to: REPLIED, attachmentIds: [ATT] }),
    });
    expect(res.status).toBe(200);
    const msgInsert = db.inserts.find((i) => i.table === 'messages');
    expect(msgInsert?.row.attachments).toMatchObject({ ids: [ATT], in_reply_to: REPLIED });
  });

  it('GET whiteboard exposes in_reply_to for the human message', async () => {
    const db = makeFakeDb();
    seed(db);
    db.rows.messages = [
      { id: REPLIED, conversation_id: CREW_ID, role: 'user', content: '原始消息', user_id: USER,
        sender_bot_id: null, log_kind: null, log_payload: null, attachments: null, status: 'done',
        created_at: '2026-06-11T00:00:01Z' },
      { id: 'reply-1', conversation_id: CREW_ID, role: 'user', content: '回复一下', user_id: USER,
        sender_bot_id: null, log_kind: null, log_payload: null, attachments: { in_reply_to: REPLIED },
        status: 'done', created_at: '2026-06-11T00:00:02Z' },
    ];
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { whiteboard: Array<{ id: string; in_reply_to: string | null }> };
    const replyEntry = body.whiteboard.find((e) => e.id === 'reply-1')!;
    expect(replyEntry.in_reply_to).toBe(REPLIED);
    const origEntry = body.whiteboard.find((e) => e.id === REPLIED)!;
    expect(origEntry.in_reply_to).toBeNull();
  });

  it('GET whiteboard exposes in_reply_to for a session post (log_payload.in_reply_to)', async () => {
    const db = makeFakeDb();
    seed(db);
    db.rows.messages = [
      { id: 'sess-post', conversation_id: CREW_ID, role: 'log', content: '我接着干', user_id: null,
        sender_bot_id: null, log_kind: 'session_post',
        log_payload: { session_id: SESSION_A, text: '我接着干', in_reply_to: REPLIED },
        attachments: null, status: 'done', created_at: '2026-06-11T00:00:03Z' },
    ];
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      headers: { 'x-test-user-id': USER },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { whiteboard: Array<{ id: string; in_reply_to: string | null }> };
    expect(body.whiteboard.find((e) => e.id === 'sess-post')!.in_reply_to).toBe(REPLIED);
  });

  it('reply_to that is not a valid uuid → 400 invalid_body', async () => {
    const db = makeFakeDb();
    seed(db);
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'x', reply_to: 'not-a-uuid' }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('invalid_body');
  });

  it('reply_to pointing at a message not in this crew → 400 invalid_body', async () => {
    const db = makeFakeDb();
    seed(db); // no messages seeded → REPLIED does not exist
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'x', reply_to: REPLIED }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('invalid_body');
  });

  it('no reply_to → attachments stays null and in_reply_to is null on read', async () => {
    const db = makeFakeDb();
    seed(db);
    const post = await appFor(db).request(`/v1/crews/${CREW_ID}/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ content: 'plain' }),
    });
    expect(post.status).toBe(200);
    const msgInsert = db.inserts.find((i) => i.table === 'messages');
    expect(msgInsert?.row.attachments ?? null).toBeNull();
  });
});

describe('POST /v1/crews/:crewId/members (接合 v2 block 3)', () => {
  const BOT_ID = '99999999-9999-4999-8999-000000000003';

  function seed(db: FakeDb) {
    db.rows.temporary_group_meta = [
      { conversation_id: CREW_ID, responsible_subject_id: SUBJECT, temporary_kind: 'crew' },
    ];
  }

  it('JWT caller adds a bot — 201 with member summary, RPC args pinned', async () => {
    const db = makeFakeDb();
    seed(db);
    let seenArgs: Record<string, unknown> | undefined;
    db.rpcs = {
      crew_add_member_for_subject: (args) => {
        seenArgs = args;
        return { data: { id: 'tm-1', member_kind: 'registered_bot', bot_id: BOT_ID, already_member: false }, error: null };
      },
    };
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/members`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ kind: 'bot', botId: BOT_ID }),
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as { crewId: string; member: { id: string } };
    expect(body.crewId).toBe(CREW_ID);
    expect(body.member.id).toBe('tm-1');
    expect(seenArgs).toMatchObject({
      p_actor_user_id: USER,
      p_crew_conversation_id: CREW_ID,
      p_member_kind: 'registered_bot',
      p_bot_id: BOT_ID,
      p_user_id: null,
    });
  });

  it('device-grant caller with mismatched subject gets 403', async () => {
    const db = makeFakeDb();
    seed(db);
    await seedDeviceGrant(db, OTHER_SUBJECT);
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/members`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${DEVICE_TOKEN}` },
      body: JSON.stringify({ kind: 'bot', botId: BOT_ID }),
    });
    expect(res.status).toBe(403);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('forbidden');
  });

  it('device-grant caller with matching subject reaches the RPC with grantedByUserId as actor', async () => {
    const db = makeFakeDb();
    seed(db);
    await seedDeviceGrant(db, SUBJECT);
    let seenArgs: Record<string, unknown> | undefined;
    db.rpcs = {
      crew_add_member_for_subject: (args) => {
        seenArgs = args;
        return { data: { id: 'tm-2', member_kind: 'human', user_id: 'friend-1', already_member: true }, error: null };
      },
    };
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/members`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${DEVICE_TOKEN}` },
      body: JSON.stringify({ kind: 'human', userId: '12121212-1212-4121-8121-000000000004' }),
    });
    expect(res.status).toBe(201);
    expect(seenArgs).toMatchObject({
      p_actor_user_id: USER,
      p_member_kind: 'human',
      p_user_id: '12121212-1212-4121-8121-000000000004',
    });
  });

  it('rejects kind=bot without botId with 400 invalid_body', async () => {
    const db = makeFakeDb();
    seed(db);
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/members`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ kind: 'bot' }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('invalid_body');
  });

  it('maps RPC 42501/forbidden to 403', async () => {
    const db = makeFakeDb();
    seed(db);
    db.rpcs = {
      crew_add_member_for_subject: () => ({ data: null, error: { code: '42501', message: 'forbidden: bot not visible to caller' } }),
    };
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/members`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ kind: 'bot', botId: BOT_ID }),
    });
    expect(res.status).toBe(403);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('forbidden');
  });

  it('returns 404 when the crew does not exist', async () => {
    const db = makeFakeDb();
    const res = await appFor(db).request(`/v1/crews/${CREW_ID}/members`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-user-id': USER },
      body: JSON.stringify({ kind: 'bot', botId: BOT_ID }),
    });
    expect(res.status).toBe(404);
  });
});

describe('mapMessageToEntry relay marker (接合 v2 block 3)', () => {
  const base = { id: 'm1', conversation_id: 'c1', created_at: '2026-06-11T00:00:00Z', log_kind: null, log_payload: null };

  it('exposes relay metadata from attachments jsonb', () => {
    const e = mapMessageToEntry({ ...base, role: 'user', content: 'hi', user_id: 'u1', sender_bot_id: null,
      attachments: { origin: 'mac_relay', senderLabel: '机长', localSessionId: 'ls-1' } } as any);
    expect(e.relay).toEqual({ origin: 'mac_relay', senderLabel: '机长', localSessionId: 'ls-1' });
  });

  it('relay is null for ordinary messages (including plain attachment ids)', () => {
    const plain = mapMessageToEntry({ ...base, role: 'user', content: 'hi', user_id: 'u1', sender_bot_id: null, attachments: { ids: ['a-1'] } } as any);
    expect(plain.relay).toBeNull();
  });
});

// #377 — mapMessageToEntry 统一透出 in_reply_to:人类消息从 attachments jsonb,
// session 帖从 log_payload.in_reply_to,解析不出为 null。
describe('mapMessageToEntry in_reply_to (#377)', () => {
  const base = { id: 'm1', conversation_id: 'c1', created_at: '2026-06-11T00:00:00Z', log_kind: null, log_payload: null };
  const REPLIED = '11111111-2222-4333-8444-555555555555';

  it('reads in_reply_to from a human message attachments jsonb', () => {
    const e = mapMessageToEntry({ ...base, role: 'user', content: 'reply', user_id: 'u1', sender_bot_id: null,
      attachments: { in_reply_to: REPLIED } } as any);
    expect(e.in_reply_to).toBe(REPLIED);
  });

  it('reads in_reply_to from a session post log_payload', () => {
    const e = mapMessageToEntry({ ...base, role: 'log', content: '接着干', user_id: null, sender_bot_id: null,
      log_kind: 'session_post', log_payload: { session_id: 's1', text: '接着干', in_reply_to: REPLIED } } as any);
    expect(e.in_reply_to).toBe(REPLIED);
  });

  it('in_reply_to is null when neither carrier has it', () => {
    const plainUser = mapMessageToEntry({ ...base, role: 'user', content: 'hi', user_id: 'u1', sender_bot_id: null } as any);
    expect(plainUser.in_reply_to).toBeNull();
    const plainAttIds = mapMessageToEntry({ ...base, role: 'user', content: 'hi', user_id: 'u1', sender_bot_id: null,
      attachments: { ids: ['a-1'] } } as any);
    expect(plainAttIds.in_reply_to).toBeNull();
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

  it('exposes sender_display_name from the resolver (human + session)', () => {
    const human = mapMessageToEntry(
      { ...base, role: 'user', content: 'hi', user_id: 'u1', sender_bot_id: null } as any,
      undefined,
      { senderName: '阿强', senderMemberId: 'mem-human' },
    );
    expect(human.sender_display_name).toBe('阿强');
    expect(human.sender_member_id).toBe('mem-human');

    const session = mapMessageToEntry(
      { ...base, role: 'log', content: '进度', user_id: null, sender_bot_id: null,
        log_kind: 'session_post', log_payload: { session_id: 's1', text: '进度' } } as any,
      undefined,
      { senderName: '小绿', senderMemberId: 'mem-sess' },
    );
    expect(session.sender_display_name).toBe('小绿');
    expect(session.sender_member_id).toBe('mem-sess');
  });

  it('sender_display_name is null when the resolver yields nothing', () => {
    const e = mapMessageToEntry({ ...base, role: 'user', content: 'hi', user_id: 'u1', sender_bot_id: null } as any);
    expect(e.sender_display_name).toBeNull();
    expect(e.sender_member_id).toBeNull();
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
// mock doesn't satisfy. The first two tests pin the JWT-rejection + bad-uuid
// contracts via the mocked requireSession; the Phase-2 mention/reply_to tests
// seed a real subject_device_grants row so the device-grant branch runs.
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

// Phase 2 — session/bot outbound @ + reply_to. The session (coding agent)
// posting to the crew can now @ a peer session / human and reply to a prior
// message (auto-@ its sender). We pin the RPC recipient args + mailbox
// enqueues + the mirror message's in_reply_to payload.
describe('POST /v1/sessions/:sessionId/post-to-crew — mentions + reply_to (Phase 2)', () => {
  const RUNNER_HOST = 'host-1';

  // Seed a runnable session + device grant + capture the announcement RPC args
  // and every mailbox enqueue. Returns the captured collections.
  async function seedSession(db: FakeDb): Promise<{
    annArgs: Record<string, unknown>[];
    enqueues: Record<string, unknown>[];
  }> {
    await seedDeviceGrant(db, SUBJECT);
    db.rows.crew_sessions = [
      {
        id: SESSION_A,
        responsible_subject_id: SUBJECT,
        runner_host_id: RUNNER_HOST,
        status: 'running',
        crew_conversation_id: CREW_ID,
      },
    ];
    const annArgs: Record<string, unknown>[] = [];
    const enqueues: Record<string, unknown>[] = [];
    db.rpcs = {
      create_crew_announcement_from_runner_for_subject: (args) => {
        annArgs.push(args);
        return { data: ANNOUNCEMENT_ID, error: null };
      },
      enqueue_session_mailbox: (args) => {
        enqueues.push(args);
        return { data: crypto.randomUUID(), error: null };
      },
    };
    return { annArgs, enqueues };
  }

  function postToCrew(db: FakeDb, body: Record<string, unknown>) {
    return appFor(db).request(`/v1/sessions/${SESSION_A}/post-to-crew`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${DEVICE_TOKEN}` },
      body: JSON.stringify(body),
    });
  }

  it('@session B → announcement recipient_session_ids includes B + B mailbox +1', async () => {
    const db = makeFakeDb();
    const { annArgs, enqueues } = await seedSession(db);
    const res = await postToCrew(db, {
      content: '@B 接力一下',
      mentions: [{ kind: 'session', target_id: SESSION_B }],
    });
    expect(res.status).toBe(200);

    // The RPC's hard-coded [] for recipients is gone — B is targeted.
    expect(annArgs.length).toBe(1);
    expect(annArgs[0].p_recipient_session_ids).toEqual([SESSION_B]);

    // B got exactly one directed mailbox row, linked to the new message id.
    const bEnqueues = enqueues.filter((e) => e.p_session_id === SESSION_B);
    expect(bEnqueues.length).toBe(1);
    expect(bEnqueues[0]).toMatchObject({ p_session_id: SESSION_B });
  });

  it('reply_to a session post → that session is auto-@d into recipients + mailbox', async () => {
    const db = makeFakeDb();
    const { annArgs, enqueues } = await seedSession(db);
    const REPLIED = '11111111-2222-4333-8444-555555555555';
    // The message being replied to is a session post (role=log, session_id=B).
    db.rows.messages = [
      {
        id: REPLIED,
        conversation_id: CREW_ID,
        role: 'log',
        log_kind: 'session_post',
        log_payload: { session_id: SESSION_B, text: '我先开了头' },
        content: '我先开了头',
        status: 'done',
        created_at: '2026-06-11T00:00:01Z',
      },
    ];
    const res = await postToCrew(db, { content: '收到，我接着干', reply_to: REPLIED });
    expect(res.status).toBe(200);

    // B (the original sender) is auto-@d even though no explicit mention given.
    expect(annArgs[0].p_recipient_session_ids).toEqual([SESSION_B]);
    expect(enqueues.filter((e) => e.p_session_id === SESSION_B).length).toBe(1);

    // The mirror message carries the reply linkage in its log_payload.
    const mirror = db.inserts.find(
      (i) => i.table === 'messages' && i.row.role === 'log' && (i.row.log_payload as Record<string, unknown> | null)?.session_id === SESSION_A,
    );
    expect((mirror?.row.log_payload as Record<string, unknown>).in_reply_to).toBe(REPLIED);
  });

  it('reply_to a human message → human becomes a member recipient (no mailbox)', async () => {
    const db = makeFakeDb();
    const { annArgs, enqueues } = await seedSession(db);
    const REPLIED = '22222222-3333-4444-8555-666666666666';
    const HUMAN_MEMBER = 'mem-human-x';
    db.rows.messages = [
      {
        id: REPLIED,
        conversation_id: CREW_ID,
        role: 'user',
        user_id: USER,
        log_kind: null,
        log_payload: null,
        content: '帮我看看这个',
        status: 'done',
        created_at: '2026-06-11T00:00:01Z',
      },
    ];
    // The crew roster maps the human's user_id → a member row.
    db.rows.temporary_group_members = [
      { id: HUMAN_MEMBER, conversation_id: CREW_ID, member_kind: 'human', user_id: USER, status: 'active' },
    ];
    const res = await postToCrew(db, { content: '看完了，结论是…', reply_to: REPLIED });
    expect(res.status).toBe(200);

    // Human lands as a member recipient, NOT a session recipient, and gets NO mailbox.
    expect(annArgs[0].p_recipient_member_ids).toEqual([HUMAN_MEMBER]);
    expect(annArgs[0].p_recipient_session_ids).toEqual([]);
    expect(enqueues.length).toBe(0);

    // The mirror message still records what was replied to.
    const mirror = db.inserts.find(
      (i) => i.table === 'messages' && i.row.role === 'log',
    );
    expect((mirror?.row.log_payload as Record<string, unknown>).in_reply_to).toBe(REPLIED);
  });

  it('no mentions + no reply_to → broadcast preserved (empty recipients, no mailbox)', async () => {
    const db = makeFakeDb();
    const { annArgs, enqueues } = await seedSession(db);
    const res = await postToCrew(db, { content: 'just a milestone', category: 'milestone' });
    expect(res.status).toBe(200);
    expect(annArgs[0].p_recipient_session_ids).toEqual([]);
    expect(annArgs[0].p_recipient_member_ids).toEqual([]);
    expect(enqueues.length).toBe(0);
  });

  it('reply_to is not a valid uuid → 400 invalid_body', async () => {
    const db = makeFakeDb();
    await seedSession(db);
    const res = await postToCrew(db, { content: 'x', reply_to: 'not-a-uuid' });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('invalid_body');
  });

  it('reply_to points at a non-existent message → 400 invalid_body', async () => {
    const db = makeFakeDb();
    await seedSession(db);
    const MISSING = '33333333-4444-4555-8666-777777777777';
    const res = await postToCrew(db, { content: 'x', reply_to: MISSING });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('invalid_body');
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
