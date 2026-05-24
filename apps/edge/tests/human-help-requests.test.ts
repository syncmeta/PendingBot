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
let humanHelpRequestRoutes: any;

beforeEach(async () => {
  ({ humanHelpRequestRoutes } = await import('../src/routes/human-help-requests'));
});

function appFor(db: FakeDb) {
  const app = new Hono<AppBindings>();
  app.route('/v1/human-help-requests', humanHelpRequestRoutes);
  return {
    request: (path: string, init?: RequestInit) =>
      app.request(path, init, makeFakeEnv(db)),
  };
}

describe('GET /v1/human-help-requests', () => {
  it('lists pending requests for the current user', async () => {
    const db = makeFakeDb({
      human_help_requests: [
        {
          id: 'request-1',
          temporary_group_id: 'temp-1',
          requester_member_id: 'member-1',
          requested_user_id: 'user-1',
          responsible_subject_id: 'subject-1',
          status: 'pending',
          reason: '需要你确认需求',
          created_at: '2026-05-24T00:00:00Z',
          decided_at: null,
        },
      ],
      temporary_group_meta: [
        {
          conversation_id: 'temp-1',
          title: '需求澄清',
          temporary_kind: 'bot_temporary_group',
          status: 'active',
        },
      ],
      conversations: [
        { id: 'temp-1', title: '需求澄清' },
      ],
      temporary_group_members: [
        {
          id: 'member-1',
          display_name: '需求机器人',
          member_kind: 'registered_bot',
        },
      ],
    });

    const res = await appFor(db).request('/v1/human-help-requests', {
      headers: { 'x-test-user-id': 'user-1' },
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: Array<Record<string, unknown>> };
    expect(body.items).toHaveLength(1);
    expect(body.items[0]).toMatchObject({
      id: 'request-1',
      status: 'pending',
      reason: '需要你确认需求',
      temporary_group: {
        title: '需求澄清',
        temporary_kind: 'bot_temporary_group',
      },
      requester: {
        display_name: '需求机器人',
      },
    });
  });
});

describe('POST /v1/human-help-requests/:id/decision', () => {
  it('accepts a request through the database RPC', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      decide_human_help_request: (args) => {
        expect(args).toEqual({
          p_request_id: 'request-1',
          p_decision: 'accepted',
        });
        return { data: true, error: null };
      },
    };

    const res = await appFor(db).request('/v1/human-help-requests/request-1/decision', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({ decision: 'accepted' }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ ok: true });
  });
});

