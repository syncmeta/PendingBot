import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import type { Context, MiddlewareHandler } from 'hono';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
  type Row,
} from './_helpers/fake-supabase';
import type { AppBindings } from '../src/types';

// Tests for POST /v1/messages/:id/recall. Pins the three product
// requirements:
//
//   • Only the original sender may recall (sender_bot_id rows + cross-
//     user attempts both 403; unknown id 404).
//   • user_user convs leave a WeChat-style tombstone row; user_bot /
//     group convs purge attachments + don't tombstone.
//   • Idempotent — second recall returns ok with `already: true` and
//     does not duplicate state changes.
//   • R2 deletion ref-counts attachment rows by r2_key — a shared blob
//     (cross-user dedup case) is not deleted while another row claims it.

// Auth middleware swap — bypass JWT verification; read user id from
// header. Must be set up before importing the route.
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

// Stub the heavy llm / billing / runner imports that messages.ts pulls in
// at module load — the recall path doesn't use them but ESM evaluates the
// whole file when we import it.
vi.mock('../src/lib/bot-reply', () => ({ runChatTurn: vi.fn() }));
vi.mock('../src/lib/memory', () => ({ maybeRefreshMemory: vi.fn() }));
vi.mock('../src/lib/lookback-runner', () => ({ runLookback: vi.fn() }));
vi.mock('../src/lib/title-runner', () => ({ runTitle: vi.fn() }));
vi.mock('../src/lib/billing', () => ({
  requireBalance: vi.fn(),
  InsufficientBalanceError: class {},
}));
vi.mock('../src/lib/group-mentions', () => ({ resolveGroupMentions: vi.fn() }));
vi.mock('../src/llm/vision', () => ({
  summarizeAttachments: vi.fn(),
  DEFAULT_VISION_MODEL: 'stub',
}));

installFakeSupabaseMock();

// Importing the route AFTER the mocks above is intentional — Vitest
// requires the imports to come last in this file for the vi.mock hoists
// to work, but route registration with mocks needs the dynamic import.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let messageRoutes: any;
// Track R2 deletes via a per-test object the mocked UPLOADS binding writes
// into. Set up in beforeEach.
let r2Deleted: string[];
let env: ReturnType<typeof makeFakeEnv>;

async function call(
  method: 'POST' | 'DELETE',
  path: string,
  userId: string,
): Promise<{ status: number; body: { ok?: boolean; already?: boolean; error?: { code?: string; message?: string } } }> {
  const app = new Hono<AppBindings>();
  app.route('/v1/messages', messageRoutes);
  const headers: Record<string, string> = { 'x-test-user-id': userId };
  const res = await app.request(path, { method, headers }, env);
  let body: { ok?: boolean; already?: boolean; error?: { code?: string; message?: string } } = {};
  try {
    body = (await res.json()) as typeof body;
  } catch {
    /* empty body */
  }
  return { status: res.status, body };
}

beforeEach(async () => {
  ({ messageRoutes } = await import('../src/routes/messages'));
  r2Deleted = [];
});

function freshSeed(): FakeDb {
  return makeFakeDb({
    messages: [
      // user_bot conv — bot is the recaller's chat partner
      mkMessage({
        id: '11111111-1111-1111-1111-111111111111',
        user_id: 'alice',
        conversation_id: 'conv-userbot',
        attachments: { ids: ['att-1'] },
      }),
      // user_user conv — alice sends to bob
      mkMessage({
        id: '22222222-2222-2222-2222-222222222222',
        user_id: 'alice',
        conversation_id: 'conv-useruser',
        attachments: null,
      }),
      // someone else's bot row (sender_bot_id, no user_id) — can't be recalled
      mkMessage({
        id: '33333333-3333-3333-3333-333333333333',
        user_id: null,
        sender_bot_id: 'bot-1',
        conversation_id: 'conv-userbot',
        attachments: null,
      }),
      // bob's message — alice attempting to recall would be cross-user
      mkMessage({
        id: '44444444-4444-4444-4444-444444444444',
        user_id: 'bob',
        conversation_id: 'conv-useruser',
        attachments: null,
      }),
      // already-recalled — second recall must be idempotent
      mkMessage({
        id: '55555555-5555-5555-5555-555555555555',
        user_id: 'alice',
        conversation_id: 'conv-userbot',
        status: 'deleted',
        attachments: null,
      }),
      // group conversation owned by alice, but the row belongs to bob.
      // DELETE must not treat group ownership as permission to remove
      // another human's message.
      mkMessage({
        id: '66666666-6666-4666-8666-666666666666',
        user_id: 'bob',
        conversation_id: 'conv-group',
        attachments: null,
      }),
      // bot reply in alice's user_bot conversation. The conversation owner
      // may delete this presentation row even though msg.user_id is null.
      mkMessage({
        id: '77777777-7777-4777-8777-777777777777',
        user_id: null,
        sender_bot_id: 'bot-1',
        conversation_id: 'conv-userbot',
        attachments: null,
      }),
    ],
    conversations: [
      { id: 'conv-userbot', conversation_type: 'user_bot', user_id: 'alice' },
      { id: 'conv-useruser', conversation_type: 'user_user' },
      { id: 'conv-group', conversation_type: 'group', user_id: 'alice' },
    ],
    attachments: [
      { id: 'att-1', user_id: 'alice', r2_key: 'blobs/h1.png' },
      // A second user's row pointing at the same r2_key — exercises the
      // cross-user dedup ref-count guard in the recall path.
      { id: 'att-shared-1', user_id: 'alice', r2_key: 'blobs/shared.png' },
      { id: 'att-shared-2', user_id: 'bob',   r2_key: 'blobs/shared.png' },
    ],
  });
}

function mkMessage(overrides: Partial<Row>): Row {
  return {
    id: 'm',
    user_id: 'alice',
    sender_bot_id: null,
    conversation_id: 'conv',
    status: 'done',
    attachments: null,
    created_at: '2026-05-12T00:00:00Z',
    ...overrides,
  };
}

function envWith(seed: FakeDb) {
  const fakeEnv = makeFakeEnv(seed);
  // R2 binding — only .delete is exercised by the recall path.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (fakeEnv as any).UPLOADS = {
    delete: async (key: string) => {
      r2Deleted.push(key);
    },
  };
  return fakeEnv;
}

describe('POST /v1/messages/:id/recall — auth & ownership', () => {
  it('rejects non-UUID ids with 400 invalid_id', async () => {
    env = envWith(freshSeed());
    const r = await call('POST', '/v1/messages/not-a-uuid/recall', 'alice');
    expect(r.status).toBe(400);
    expect(r.body.error?.code).toBe('invalid_id');
  });

  it('returns 404 not_found for unknown ids', async () => {
    env = envWith(freshSeed());
    const r = await call('POST', '/v1/messages/00000000-0000-0000-0000-000000000000/recall', 'alice');
    expect(r.status).toBe(404);
    expect(r.body.error?.code).toBe('not_found');
  });

  it('rejects cross-user attempts with 403 forbidden', async () => {
    // alice tries to recall bob's message — must 403, must not mutate
    env = envWith(freshSeed());
    const r = await call('POST', '/v1/messages/44444444-4444-4444-4444-444444444444/recall', 'alice');
    expect(r.status).toBe(403);
    expect(r.body.error?.code).toBe('forbidden');
    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    expect(db.updates).toHaveLength(0);
    expect(db.deletes).toHaveLength(0);
  });

  it('rejects recall of bot reply rows (user_id=null) with 403', async () => {
    // The bot's reply row has sender_bot_id set + user_id=null; the
    // sender-check `msg.user_id !== userId` rejects on null === 'alice'.
    env = envWith(freshSeed());
    const r = await call('POST', '/v1/messages/33333333-3333-3333-3333-333333333333/recall', 'alice');
    expect(r.status).toBe(403);
  });
});

describe('POST /v1/messages/:id/recall — idempotency', () => {
  it('returns ok+already=true for a row already status="deleted"', async () => {
    env = envWith(freshSeed());
    const r = await call('POST', '/v1/messages/55555555-5555-5555-5555-555555555555/recall', 'alice');
    expect(r.status).toBe(200);
    expect(r.body.ok).toBe(true);
    expect(r.body.already).toBe(true);
    // No further updates / deletes — purely a read.
    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    expect(db.updates).toHaveLength(0);
    expect(db.deletes).toHaveLength(0);
    expect(r2Deleted).toEqual([]);
  });
});

describe('POST /v1/messages/:id/recall — user_bot conv', () => {
  it('soft-deletes the message and purges its attachments + R2 object', async () => {
    env = envWith(freshSeed());
    const r = await call('POST', '/v1/messages/11111111-1111-1111-1111-111111111111/recall', 'alice');
    expect(r.status).toBe(200);
    expect(r.body.ok).toBe(true);

    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    // Soft-delete: status flipped, content + attachments cleared
    const msg = db.rows.messages.find((m) => m.id === '11111111-1111-1111-1111-111111111111');
    expect(msg?.status).toBe('deleted');
    expect(msg?.content).toBeNull();
    expect(msg?.attachments).toBeNull();
    // Attachment row purged
    expect(db.rows.attachments.find((a) => a.id === 'att-1')).toBeUndefined();
    // R2 object deleted (no other claim)
    expect(r2Deleted).toEqual(['blobs/h1.png']);
    // No tombstone log row — user_bot convs don't surface one
    const tombstones = db.inserts.filter((i) =>
      i.table === 'messages' && (i.row as { log_kind?: string }).log_kind === 'recall',
    );
    expect(tombstones).toHaveLength(0);
  });
});

describe('POST /v1/messages/:id/recall — user_user conv', () => {
  it('soft-deletes the message and inserts a recall tombstone log row', async () => {
    env = envWith(freshSeed());
    const r = await call('POST', '/v1/messages/22222222-2222-2222-2222-222222222222/recall', 'alice');
    expect(r.status).toBe(200);

    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    const tombstones = db.inserts.filter((i) =>
      i.table === 'messages' && (i.row as { log_kind?: string }).log_kind === 'recall',
    );
    expect(tombstones).toHaveLength(1);
    const payload = (tombstones[0].row as { log_payload?: { original_message_id?: string; recaller_user_id?: string } }).log_payload;
    expect(payload?.original_message_id).toBe('22222222-2222-2222-2222-222222222222');
    expect(payload?.recaller_user_id).toBe('alice');
  });
});

describe('POST /v1/messages/:id/recall — R2 ref counting', () => {
  it('does NOT delete the R2 object when another attachments row still references the r2_key', async () => {
    // Set up: alice's message references att-shared-1 (blobs/shared.png);
    // bob's row att-shared-2 also points at blobs/shared.png. Recalling
    // alice's message should drop her row but leave the R2 object alone.
    const seed = freshSeed();
    // Re-aim the userbot row at the shared attachment
    const m = seed.rows.messages.find((x) => x.id === '11111111-1111-1111-1111-111111111111');
    if (m) m.attachments = { ids: ['att-shared-1'] };

    env = envWith(seed);
    const r = await call('POST', '/v1/messages/11111111-1111-1111-1111-111111111111/recall', 'alice');
    expect(r.status).toBe(200);

    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    // alice's row gone, bob's row still there
    expect(db.rows.attachments.find((a) => a.id === 'att-shared-1')).toBeUndefined();
    expect(db.rows.attachments.find((a) => a.id === 'att-shared-2')).toBeDefined();
    // R2 object NOT deleted — bob's row still claims it
    expect(r2Deleted).toEqual([]);
  });
});

describe('DELETE /v1/messages/:id — auth boundaries', () => {
  it('does not let a group owner hard-delete another human participant message', async () => {
    env = envWith(freshSeed());
    const r = await call('DELETE', '/v1/messages/66666666-6666-4666-8666-666666666666', 'alice');
    expect(r.status).toBe(403);
    expect(r.body.error?.code).toBe('forbidden');

    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    expect(db.rows.messages.find((m) => m.id === '66666666-6666-4666-8666-666666666666')).toBeDefined();
  });

  it('lets a user_bot conversation owner delete a bot reply presentation row', async () => {
    env = envWith(freshSeed());
    const r = await call('DELETE', '/v1/messages/77777777-7777-4777-8777-777777777777', 'alice');
    expect(r.status).toBe(200);
    expect(r.body.ok).toBe(true);

    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    expect(db.rows.messages.find((m) => m.id === '77777777-7777-4777-8777-777777777777')).toBeUndefined();
  });
});
