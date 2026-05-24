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
let runnerHostRoutes: any;

beforeEach(async () => {
  ({ runnerHostRoutes } = await import('../src/routes/runner-hosts'));
});

function appFor(db: FakeDb) {
  const app = new Hono<AppBindings>();
  app.route('/v1/runner-hosts', runnerHostRoutes);
  return {
    request: (path: string, init?: RequestInit) =>
      app.request(path, init, makeFakeEnv(db)),
  };
}

describe('POST /v1/runner-hosts', () => {
  it('registers a macOS runner host under a responsible subject', async () => {
    const subjectId = '11111111-1111-4111-8111-111111111111';
    const hostId = '22222222-2222-4222-8222-222222222222';
    const db = makeFakeDb();
    db.rpcs = {
      register_runner_host: (args) => {
        expect(args).toEqual({
          p_responsible_subject_id: subjectId,
          p_display_name: 'MacBook Pro',
          p_capabilities: { local: true },
          p_allowed_runner_kinds: ['local_codex', 'local_claude_code'],
        });
        return { data: hostId, error: null };
      },
    };

    const res = await appFor(db).request('/v1/runner-hosts', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        responsibleSubjectId: subjectId,
        displayName: 'MacBook Pro',
        capabilities: { local: true },
        allowedRunnerKinds: ['local_codex', 'local_claude_code'],
      }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ runnerHostId: hostId });
  });
});

describe('POST /v1/runner-hosts/:id/heartbeat', () => {
  it('updates runner heartbeat through the database RPC', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      runner_host_heartbeat: (args) => {
        expect(args).toEqual({
          p_runner_host_id: 'host-1',
          p_capabilities: { shell: true },
          p_allowed_runner_kinds: ['local_codex'],
        });
        return { data: true, error: null };
      },
    };

    const res = await appFor(db).request('/v1/runner-hosts/host-1/heartbeat', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        capabilities: { shell: true },
        allowedRunnerKinds: ['local_codex'],
      }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ ok: true });
  });
});

describe('GET /v1/runner-hosts', () => {
  it('lists visible runner hosts', async () => {
    const db = makeFakeDb({
      runner_hosts: [
        {
          id: 'host-1',
          responsible_subject_id: 'subject-1',
          platform: 'macos',
          display_name: 'MacBook Pro',
          capabilities: { shell: true },
          allowed_runner_kinds: ['local_codex'],
          status: 'online',
          last_seen_at: '2026-05-24T00:01:00Z',
          created_at: '2026-05-24T00:00:00Z',
          updated_at: '2026-05-24T00:01:00Z',
        },
      ],
    });

    const res = await appFor(db).request('/v1/runner-hosts', {
      headers: { 'x-test-user-id': 'user-1' },
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: Array<Record<string, unknown>> };
    expect(body.items).toHaveLength(1);
    expect(body.items[0]).toMatchObject({
      id: 'host-1',
      platform: 'macos',
      status: 'online',
    });
  });
});

