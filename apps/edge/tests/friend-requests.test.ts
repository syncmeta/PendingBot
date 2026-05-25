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

vi.mock('../src/lib/rate-limit', () => ({
  rateLimitOrBlock: vi.fn(async () => null),
}));

installFakeSupabaseMock();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let friendRequestRoutes: any;
let env: ReturnType<typeof makeFakeEnv>;

const alice = '11111111-1111-4111-8111-111111111111';
const bob = '22222222-2222-4222-8222-222222222222';
const groupId = '33333333-3333-4333-8333-333333333333';

async function post(body: unknown, userId = alice) {
  const app = new Hono<AppBindings>();
  app.route('/v1/friend-requests', friendRequestRoutes);
  const res = await app.request(
    '/v1/friend-requests',
    {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': userId,
      },
      body: JSON.stringify(body),
    },
    env,
  );
  let json: { error?: { code?: string }; requestId?: string } = {};
  try {
    json = await res.json();
  } catch {
    /* empty */
  }
  return { status: res.status, body: json };
}

beforeEach(async () => {
  ({ friendRequestRoutes } = await import('../src/routes/friend-requests'));
});

function seedDb(targetInGroup = true): FakeDb {
  return makeFakeDb({
    conversations: [
      {
        id: groupId,
        conversation_type: 'group',
        user_id: alice,
      },
    ],
    conversation_participants: [
      {
        conversation_id: groupId,
        participant_type: 'user',
        participant_id: alice,
        role: 'owner',
      },
      ...(targetInGroup
        ? [{
            conversation_id: groupId,
            participant_type: 'user',
            participant_id: bob,
            role: 'member',
          }]
        : []),
    ],
    users: [
      { id: alice },
      { id: bob },
    ],
    user_contacts: [],
    friend_requests: [],
  });
}

describe('POST /v1/friend-requests peer-id source authorization', () => {
  it('rejects peerUserId requests that do not name the source group', async () => {
    env = makeFakeEnv(seedDb());

    const res = await post({ peerUserId: bob, message: 'hi' });

    expect(res.status).toBe(400);
    expect(res.body.error?.code).toBe('invalid_body');
  });

  it('rejects peerUserId requests when the target is not in the source group', async () => {
    env = makeFakeEnv(seedDb(false));

    const res = await post({ peerUserId: bob, sourceConversationId: groupId, message: 'hi' });

    expect(res.status).toBe(403);
    expect(res.body.error?.code).toBe('peer_not_in_source_group');
    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    expect(db.inserts.filter((i) => i.table === 'friend_requests')).toHaveLength(0);
  });

  it('creates a request by peerUserId only when both users are in the source group', async () => {
    env = makeFakeEnv(seedDb());

    const res = await post({ peerUserId: bob, sourceConversationId: groupId, message: 'hi' });

    expect(res.status).toBe(200);
    const db = (env as unknown as { __fakeDb: FakeDb }).__fakeDb;
    expect(db.inserts.filter((i) => i.table === 'friend_requests')).toEqual([
      {
        table: 'friend_requests',
        row: {
          from_user_id: alice,
          to_user_id: bob,
          status: 'pending',
          message: 'hi',
          remark_for_contact: null,
          via_handle_id: null,
        },
      },
    ]);
  });
});
