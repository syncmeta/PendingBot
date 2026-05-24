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

async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function seedDeviceGrant(
  db: FakeDb,
  token: string,
  subjectId = '11111111-1111-4111-8111-111111111111',
  scopes = ['runner:read', 'runner:write'],
) {
  db.rows.subject_device_grants = [
    ...(db.rows.subject_device_grants ?? []),
    {
      id: `grant-${db.rows.subject_device_grants?.length ?? 0}`,
      subject_id: subjectId,
      token_hash: await sha256Hex(token),
      grant_kind: 'pendingcrew_runner',
      scopes,
      app_kind: 'pendingcrew_macos',
      status: 'active',
      expires_at: '2099-01-01T00:00:00Z',
      last_used_at: null,
    },
  ];
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

  it('registers a runner host with a device grant for the granted subject', async () => {
    const token = 'pdg_runner_write_token';
    const subjectId = '11111111-1111-4111-8111-111111111111';
    const db = makeFakeDb();
    await seedDeviceGrant(db, token, subjectId, ['runner:write']);

    const res = await appFor(db).request('/v1/runner-hosts', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        responsibleSubjectId: subjectId,
        displayName: 'PendingCrew Mac',
        capabilities: { local: true },
        allowedRunnerKinds: ['local_codex'],
      }),
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { runnerHostId?: unknown };
    expect(typeof body.runnerHostId).toBe('string');
    expect(db.inserts).toHaveLength(1);
    expect(db.inserts[0]).toMatchObject({
        table: 'runner_hosts',
        row: {
        responsible_subject_id: subjectId,
        platform: 'macos',
        display_name: 'PendingCrew Mac',
        capabilities: { local: true },
        allowed_runner_kinds: ['local_codex'],
        status: 'online',
      },
    });
  });

  it('rejects a device grant registering under a different subject', async () => {
    const token = 'pdg_runner_wrong_subject_token';
    const db = makeFakeDb();
    await seedDeviceGrant(db, token, '11111111-1111-4111-8111-111111111111', ['runner:write']);

    const res = await appFor(db).request('/v1/runner-hosts', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        responsibleSubjectId: '22222222-2222-4222-8222-222222222222',
        displayName: 'PendingCrew Mac',
      }),
    });

    expect(res.status).toBe(403);
    expect(db.inserts).toHaveLength(0);
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

  it('updates runner heartbeat with a device grant for the granted subject', async () => {
    const token = 'pdg_runner_heartbeat_token';
    const subjectId = '11111111-1111-4111-8111-111111111111';
    const db = makeFakeDb();
    await seedDeviceGrant(db, token, subjectId, ['runner:write']);
    db.rpcs = {
      runner_host_heartbeat_for_subject: (args) => {
        expect(args).toEqual({
          p_runner_host_id: 'host-1',
          p_responsible_subject_id: subjectId,
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
        authorization: `Bearer ${token}`,
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

describe('POST /v1/runner-hosts/:id/claim-next', () => {
  it('claims the next queued crew session for this runner host', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      claim_next_crew_session: (args) => {
        expect(args).toEqual({
          p_runner_host_id: 'host-1',
          p_runner_kinds: ['local_codex'],
        });
        return {
          data: {
            lease_id: 'lease-1',
            session: {
              id: 'session-1',
              crew_conversation_id: 'crew-1',
              responsible_subject_id: 'subject-1',
              runner_kind: 'local_codex',
              status: 'running',
              task_brief: '整理临时群地基',
              progress_summary: '正在运行',
              created_at: '2026-05-24T00:00:00Z',
              started_at: '2026-05-24T00:01:00Z',
              finished_at: null,
            },
          },
          error: null,
        };
      },
    };

    const res = await appFor(db).request('/v1/runner-hosts/host-1/claim-next', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({ runnerKinds: ['local_codex'] }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({
      leaseId: 'lease-1',
      session: {
        id: 'session-1',
        crew_conversation_id: 'crew-1',
        responsible_subject_id: 'subject-1',
        runner_kind: 'local_codex',
        status: 'running',
        task_brief: '整理临时群地基',
        progress_summary: '正在运行',
        created_at: '2026-05-24T00:00:00Z',
        started_at: '2026-05-24T00:01:00Z',
        finished_at: null,
      },
    });
  });

  it('claims the next queued session with a device grant for the granted subject', async () => {
    const token = 'pdg_runner_claim_token';
    const subjectId = '11111111-1111-4111-8111-111111111111';
    const db = makeFakeDb();
    await seedDeviceGrant(db, token, subjectId, ['runner:write']);
    db.rpcs = {
      claim_next_crew_session_for_subject: (args) => {
        expect(args).toEqual({
          p_runner_host_id: 'host-1',
          p_responsible_subject_id: subjectId,
          p_runner_kinds: ['local_codex'],
        });
        return {
          data: {
            lease_id: 'lease-1',
            session: {
              id: 'session-1',
              crew_conversation_id: 'crew-1',
              responsible_subject_id: subjectId,
              runner_kind: 'local_codex',
              status: 'running',
              task_brief: '整理临时群地基',
              progress_summary: '正在运行',
              created_at: '2026-05-24T00:00:00Z',
              started_at: '2026-05-24T00:01:00Z',
              finished_at: null,
            },
          },
          error: null,
        };
      },
    };

    const res = await appFor(db).request('/v1/runner-hosts/host-1/claim-next', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ runnerKinds: ['local_codex'] }),
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { leaseId: string; session: { responsible_subject_id: string } };
    expect(body.leaseId).toBe('lease-1');
    expect(body.session.responsible_subject_id).toBe(subjectId);
  });

  it('returns an empty claim when there is no matching session', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      claim_next_crew_session: () => ({ data: null, error: null }),
    };

    const res = await appFor(db).request('/v1/runner-hosts/host-1/claim-next', {
      method: 'POST',
      headers: { 'x-test-user-id': 'user-1' },
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ leaseId: null, session: null });
  });
});

describe('POST /v1/runner-hosts/:id/sessions/:sessionId/events', () => {
  it('appends a runner-visible progress event to an active session', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      append_crew_session_event_from_runner: (args) => {
        expect(args).toEqual({
          p_runner_host_id: 'host-1',
          p_crew_session_id: 'session-1',
          p_event_type: 'status',
          p_visibility: 'crew_members',
          p_summary: '完成依赖安装',
          p_payload: { step: 'deps' },
          p_progress_summary: '依赖已安装',
        });
        return { data: 'event-1', error: null };
      },
    };

    const res = await appFor(db).request('/v1/runner-hosts/host-1/sessions/session-1/events', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        eventType: 'status',
        visibility: 'crew_members',
        summary: '完成依赖安装',
        payload: { step: 'deps' },
        progressSummary: '依赖已安装',
      }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ eventId: 'event-1' });
  });

  it('appends a progress event with a device grant for the granted subject', async () => {
    const token = 'pdg_runner_event_token';
    const subjectId = '11111111-1111-4111-8111-111111111111';
    const db = makeFakeDb();
    await seedDeviceGrant(db, token, subjectId, ['runner:write']);
    db.rpcs = {
      append_crew_session_event_from_runner_for_subject: (args) => {
        expect(args).toEqual({
          p_runner_host_id: 'host-1',
          p_responsible_subject_id: subjectId,
          p_crew_session_id: 'session-1',
          p_event_type: 'status',
          p_visibility: 'crew_members',
          p_summary: '完成依赖安装',
          p_payload: { step: 'deps' },
          p_progress_summary: '依赖已安装',
        });
        return { data: 'event-1', error: null };
      },
    };

    const res = await appFor(db).request('/v1/runner-hosts/host-1/sessions/session-1/events', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        eventType: 'status',
        visibility: 'crew_members',
        summary: '完成依赖安装',
        payload: { step: 'deps' },
        progressSummary: '依赖已安装',
      }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ eventId: 'event-1' });
  });
});

describe('POST /v1/runner-hosts/:id/sessions/:sessionId/finish', () => {
  it('marks a claimed crew session as succeeded', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      finish_crew_session_from_runner: (args) => {
        expect(args).toEqual({
          p_runner_host_id: 'host-1',
          p_crew_session_id: 'session-1',
          p_status: 'completed',
          p_summary: '已完成',
          p_payload: { result: 'ok' },
          p_progress_summary: '已完成',
        });
        return { data: true, error: null };
      },
    };

    const res = await appFor(db).request('/v1/runner-hosts/host-1/sessions/session-1/finish', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        status: 'completed',
        summary: '已完成',
        payload: { result: 'ok' },
        progressSummary: '已完成',
      }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ ok: true });
  });

  it('finishes a claimed session with a device grant for the granted subject', async () => {
    const token = 'pdg_runner_finish_token';
    const subjectId = '11111111-1111-4111-8111-111111111111';
    const db = makeFakeDb();
    await seedDeviceGrant(db, token, subjectId, ['runner:write']);
    db.rpcs = {
      finish_crew_session_from_runner_for_subject: (args) => {
        expect(args).toEqual({
          p_runner_host_id: 'host-1',
          p_responsible_subject_id: subjectId,
          p_crew_session_id: 'session-1',
          p_status: 'completed',
          p_summary: '已完成',
          p_payload: { result: 'ok' },
          p_progress_summary: '已完成',
        });
        return { data: true, error: null };
      },
    };

    const res = await appFor(db).request('/v1/runner-hosts/host-1/sessions/session-1/finish', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        status: 'completed',
        summary: '已完成',
        payload: { result: 'ok' },
        progressSummary: '已完成',
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

  it('lists only runner hosts for the granted subject', async () => {
    const token = 'pdg_runner_read_token';
    const subjectId = '11111111-1111-4111-8111-111111111111';
    const db = makeFakeDb({
      runner_hosts: [
        {
          id: 'host-1',
          responsible_subject_id: subjectId,
          platform: 'macos',
          display_name: 'MacBook Pro',
          capabilities: { shell: true },
          allowed_runner_kinds: ['local_codex'],
          status: 'online',
          last_seen_at: '2026-05-24T00:01:00Z',
          created_at: '2026-05-24T00:00:00Z',
          updated_at: '2026-05-24T00:01:00Z',
        },
        {
          id: 'host-2',
          responsible_subject_id: '22222222-2222-4222-8222-222222222222',
          platform: 'macos',
          display_name: 'Other Mac',
          capabilities: {},
          allowed_runner_kinds: ['local_codex'],
          status: 'online',
          last_seen_at: '2026-05-24T00:01:00Z',
          created_at: '2026-05-24T00:00:00Z',
          updated_at: '2026-05-24T00:01:00Z',
        },
      ],
    });
    await seedDeviceGrant(db, token, subjectId, ['runner:read']);

    const res = await appFor(db).request('/v1/runner-hosts', {
      headers: { authorization: `Bearer ${token}` },
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: Array<Record<string, unknown>> };
    expect(body.items.map((item) => item.id)).toEqual(['host-1']);
  });
});
