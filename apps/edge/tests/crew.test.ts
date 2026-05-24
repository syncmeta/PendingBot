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
let crewRoutes: any;

beforeEach(async () => {
  ({ crewRoutes } = await import('../src/routes/crew'));
});

function appFor(db: FakeDb) {
  const app = new Hono<AppBindings>();
  app.route('/v1/crew', crewRoutes);
  return {
    request: (path: string, init?: RequestInit) =>
      app.request(path, init, makeFakeEnv(db)),
  };
}

describe('POST /v1/crew', () => {
  it('creates a crew through the database RPC', async () => {
    const subjectId = '11111111-1111-4111-8111-111111111111';
    const convId = '22222222-2222-4222-8222-222222222222';
    const db = makeFakeDb();
    db.rpcs = {
      open_crew_conv: (args) => {
        expect(args).toEqual({
          p_responsible_subject_id: subjectId,
          p_title: '工程 Crew',
        });
        return { data: convId, error: null };
      },
    };

    const res = await appFor(db).request('/v1/crew', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        responsibleSubjectId: subjectId,
        title: '工程 Crew',
      }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ conversationId: convId });
  });

  it('maps subject permission failures to 403', async () => {
    const subjectId = '11111111-1111-4111-8111-111111111111';
    const db = makeFakeDb();
    db.rpcs = {
      open_crew_conv: () => ({
        data: null,
        error: { message: 'forbidden: cannot create crew for subject' },
      }),
    };

    const res = await appFor(db).request('/v1/crew', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({ responsibleSubjectId: subjectId }),
    });

    expect(res.status).toBe(403);
    await expect(res.json()).resolves.toEqual({
      error: {
        code: 'forbidden',
        message: 'forbidden: cannot create crew for subject',
      },
    });
  });
});

describe('GET /v1/crew', () => {
  it('lists visible crews with conversation titles as fallback', async () => {
    const db = makeFakeDb({
      temporary_group_meta: [
        {
          conversation_id: 'crew-1',
          temporary_kind: 'crew',
          responsible_subject_id: 'subject-1',
          status: 'active',
          title: null,
          created_at: '2026-05-24T00:00:00Z',
          updated_at: null,
        },
      ],
      conversations: [
        {
          id: 'crew-1',
          title: '本机工程任务',
          created_at: '2026-05-24T00:00:00Z',
          updated_at: '2026-05-24T00:01:00Z',
        },
      ],
    });

    const res = await appFor(db).request('/v1/crew', {
      headers: { 'x-test-user-id': 'user-1' },
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({
      items: [
        {
          conversation_id: 'crew-1',
          responsible_subject_id: 'subject-1',
          status: 'active',
          title: '本机工程任务',
          created_at: '2026-05-24T00:00:00Z',
          updated_at: '2026-05-24T00:01:00Z',
        },
      ],
    });
  });
});

