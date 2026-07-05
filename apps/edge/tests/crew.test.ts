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

async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function seedDeviceGrant(db: FakeDb, token: string, subjectId = 'subject-1', scopes = ['crew:read']) {
  db.rows.subject_device_grants = [
    ...(db.rows.subject_device_grants ?? []),
    {
      id: `grant-${db.rows.subject_device_grants?.length ?? 0}`,
      subject_id: subjectId,
      granted_by_user_id: 'user-1',
      token_hash: await sha256Hex(token),
      grant_kind: 'pendingcrew_control',
      scopes,
      app_kind: 'pendingcrew_macos',
      status: 'active',
      expires_at: '2099-01-01T00:00:00Z',
      last_used_at: null,
    },
  ];
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

  it('creates a crew with a device grant for the granted subject', async () => {
    const token = 'pdg_crew_write_token';
    const subjectId = '11111111-1111-4111-8111-111111111111';
    const convId = '22222222-2222-4222-8222-222222222222';
    const db = makeFakeDb();
    await seedDeviceGrant(db, token, subjectId, ['crew:write']);
    db.rpcs = {
      open_crew_conv_for_subject: (args) => {
        expect(args).toEqual({
          p_responsible_subject_id: subjectId,
          p_actor_user_id: 'user-1',
          p_title: '工程 Crew',
        });
        return { data: convId, error: null };
      },
    };

    const res = await appFor(db).request('/v1/crew', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        responsibleSubjectId: subjectId,
        title: '工程 Crew',
      }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ conversationId: convId });
  });
});

describe('POST /v1/crew/:id/sessions', () => {
  it('queues a crew session through the database RPC', async () => {
    const sessionId = '33333333-3333-4333-8333-333333333333';
    const db = makeFakeDb();
    db.rpcs = {
      open_crew_session: (args) => {
        expect(args).toEqual({
          p_crew_conversation_id: 'crew-1',
          p_runner_kind: 'local_codex',
          p_task_brief: '整理临时群地基',
        });
        return { data: sessionId, error: null };
      },
    };

    const res = await appFor(db).request('/v1/crew/crew-1/sessions', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        runnerKind: 'local_codex',
        taskBrief: '整理临时群地基',
      }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ sessionId });
  });

  it('maps non-crew or inactive crew failures to 404', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      open_crew_session: () => ({
        data: null,
        error: { message: 'crew not found or inactive' },
      }),
    };

    const res = await appFor(db).request('/v1/crew/not-crew/sessions', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        runnerKind: 'local_codex',
        taskBrief: 'do work',
      }),
    });

    expect(res.status).toBe(404);
  });

  it('queues a crew session with a device grant for the granted subject', async () => {
    const token = 'pdg_crew_session_write_token';
    const subjectId = '11111111-1111-4111-8111-111111111111';
    const sessionId = '33333333-3333-4333-8333-333333333333';
    const db = makeFakeDb();
    await seedDeviceGrant(db, token, subjectId, ['crew:write']);
    db.rpcs = {
      open_crew_session_for_subject: (args) => {
        expect(args).toEqual({
          p_crew_conversation_id: 'crew-1',
          p_responsible_subject_id: subjectId,
          p_actor_user_id: 'user-1',
          p_runner_kind: 'local_codex',
          p_task_brief: '整理临时群地基',
        });
        return { data: sessionId, error: null };
      },
    };

    const res = await appFor(db).request('/v1/crew/crew-1/sessions', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        runnerKind: 'local_codex',
        taskBrief: '整理临时群地基',
      }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ sessionId });
  });
});

describe('POST /v1/crew/:id/children', () => {
  it('creates a child crew by inheriting the parent responsibility split', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      create_child_crew_inheriting_responsibility: (args) => {
        expect(args).toEqual({
          p_parent_crew_conversation_id: 'crew-parent',
          p_title: 'API 小组',
        });
        return { data: 'crew-child', error: null };
      },
    };

    const res = await appFor(db).request('/v1/crew/crew-parent/children', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({ title: 'API 小组' }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ conversationId: 'crew-child' });
  });
});

describe('GET /v1/crew/:id/links', () => {
  it('checks explicit crew visibility before returning link summaries to a user', async () => {
    const db = makeFakeDb({
      crew_link_summaries: [
        {
          current_crew_id: 'crew-secret',
          linked_crew_id: 'crew-child',
          direction: 'child',
          title: 'Hidden Crew',
          status: 'active',
          runtime_location: 'local_host',
          captain_bot_id: null,
          captain_member_id: null,
          created_at: '2026-05-27T00:01:00Z',
        },
      ],
    });
    const calls: Array<Record<string, unknown>> = [];
    db.rpcs = {
      can_view_temporary_group: (args) => {
        calls.push(args);
        return { data: false, error: null };
      },
    };

    const res = await appFor(db).request('/v1/crew/crew-secret/links', {
      headers: { 'x-test-user-id': 'user-1' },
    });

    expect(res.status).toBe(404);
    expect(calls).toEqual([
      {
        p_conversation_id: 'crew-secret',
        p_user_id: 'user-1',
      },
    ]);
  });

  it('returns parent links, child links, and resolved responsibility shares', async () => {
    const db = makeFakeDb({
      crew_link_summaries: [
        {
          current_crew_id: 'crew-current',
          linked_crew_id: 'crew-parent',
          direction: 'parent',
          title: '平台部',
          status: 'active',
          runtime_location: 'local_host',
          captain_bot_id: 'bot-parent',
          captain_member_id: 'member-parent-captain',
          created_at: '2026-05-27T00:00:00Z',
        },
        {
          current_crew_id: 'crew-current',
          linked_crew_id: 'crew-child',
          direction: 'child',
          title: 'API 小组',
          status: 'active',
          runtime_location: 'local_host',
          captain_bot_id: 'bot-child',
          captain_member_id: 'member-child-captain',
          created_at: '2026-05-27T00:01:00Z',
        },
      ],
      crew_resolved_responsibility_shares: [
        {
          crew_conversation_id: 'crew-current',
          subject_id: 'subject-a',
          share_bps: 6000,
          source: 'inherited',
        },
        {
          crew_conversation_id: 'crew-current',
          subject_id: 'subject-b',
          share_bps: 4000,
          source: 'inherited',
        },
      ],
    });
    db.rpcs = {
      can_view_temporary_group: () => ({ data: true, error: null }),
    };

    const res = await appFor(db).request('/v1/crew/crew-current/links', {
      headers: { 'x-test-user-id': 'user-1' },
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({
      parents: [
        {
          crew_conversation_id: 'crew-parent',
          title: '平台部',
          status: 'active',
          runtime_location: 'local_host',
          captain_bot_id: 'bot-parent',
          captain_member_id: 'member-parent-captain',
          created_at: '2026-05-27T00:00:00Z',
        },
      ],
      children: [
        {
          crew_conversation_id: 'crew-child',
          title: 'API 小组',
          status: 'active',
          runtime_location: 'local_host',
          captain_bot_id: 'bot-child',
          captain_member_id: 'member-child-captain',
          created_at: '2026-05-27T00:01:00Z',
        },
      ],
      responsibilityShares: [
        {
          subject_id: 'subject-a',
          share_bps: 6000,
          source: 'inherited',
        },
        {
          subject_id: 'subject-b',
          share_bps: 4000,
          source: 'inherited',
        },
      ],
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
          runtime_location: 'local_host',
          created_at: '2026-05-24T00:00:00Z',
          updated_at: '2026-05-24T00:01:00Z',
        },
      ],
    });
  });

  it('lists only the granted subject crews for a device grant', async () => {
    const token = 'pdg_crew_read_token';
    const db = makeFakeDb({
      temporary_group_meta: [
        {
          conversation_id: 'crew-1',
          temporary_kind: 'crew',
          responsible_subject_id: 'subject-1',
          status: 'active',
          title: '自己的 Crew',
          created_at: '2026-05-24T00:00:00Z',
          updated_at: '2026-05-24T00:01:00Z',
        },
        {
          conversation_id: 'crew-2',
          temporary_kind: 'crew',
          responsible_subject_id: 'subject-2',
          status: 'active',
          title: '别人的 Crew',
          created_at: '2026-05-24T00:00:00Z',
          updated_at: '2026-05-24T00:01:00Z',
        },
      ],
      conversations: [
        {
          id: 'crew-1',
          title: '自己的 Crew',
          created_at: '2026-05-24T00:00:00Z',
          updated_at: '2026-05-24T00:01:00Z',
        },
        {
          id: 'crew-2',
          title: '别人的 Crew',
          created_at: '2026-05-24T00:00:00Z',
          updated_at: '2026-05-24T00:01:00Z',
        },
      ],
    });
    await seedDeviceGrant(db, token);

    const res = await appFor(db).request('/v1/crew', {
      headers: { authorization: `Bearer ${token}` },
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: Array<Record<string, unknown>> };
    expect(body.items.map((item) => item.conversation_id)).toEqual(['crew-1']);
  });
});

describe('GET /v1/crew/:id/sessions', () => {
  it('lists queued sessions for a crew', async () => {
    const db = makeFakeDb({
      crew_sessions: [
        {
          id: 'session-1',
          crew_conversation_id: 'crew-1',
          responsible_subject_id: 'subject-1',
          runner_kind: 'local_codex',
          status: 'queued',
          task_brief: '整理地基',
          progress_summary: '已排队',
          created_at: '2026-05-24T00:00:00Z',
          started_at: null,
          finished_at: null,
        },
      ],
    });

    const res = await appFor(db).request('/v1/crew/crew-1/sessions', {
      headers: { 'x-test-user-id': 'user-1' },
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: Array<Record<string, unknown>> };
    expect(body.items).toHaveLength(1);
    expect(body.items[0]).toMatchObject({
      id: 'session-1',
      runner_kind: 'local_codex',
      status: 'queued',
    });
  });

  it('rejects a device grant when the crew belongs to another subject', async () => {
    const token = 'pdg_crew_session_token';
    const db = makeFakeDb({
      temporary_group_meta: [
        {
          conversation_id: 'crew-2',
          temporary_kind: 'crew',
          responsible_subject_id: 'subject-2',
          status: 'active',
          title: '别人的 Crew',
          created_at: '2026-05-24T00:00:00Z',
          updated_at: '2026-05-24T00:01:00Z',
        },
      ],
      crew_sessions: [
        {
          id: 'session-2',
          crew_conversation_id: 'crew-2',
          responsible_subject_id: 'subject-2',
          runner_kind: 'local_codex',
          status: 'queued',
          task_brief: '整理地基',
          progress_summary: '已排队',
          created_at: '2026-05-24T00:00:00Z',
          started_at: null,
          finished_at: null,
        },
      ],
    });
    await seedDeviceGrant(db, token, 'subject-1');

    const res = await appFor(db).request('/v1/crew/crew-2/sessions', {
      headers: { authorization: `Bearer ${token}` },
    });

    expect(res.status).toBe(404);
  });
});

describe('POST /v1/crew/:id/announcements', () => {
  it('creates a human announcement with session and member mentions', async () => {
    const sessionId = '33333333-3333-4333-8333-333333333333';
    const memberId = '44444444-4444-4444-8444-444444444444';
    const db = makeFakeDb();
    db.rpcs = {
      create_crew_announcement: (args) => {
        expect(args).toEqual({
          p_crew_conversation_id: 'crew-1',
          p_recipient_session_ids: [sessionId],
          p_recipient_member_ids: [memberId],
          p_message_kind: 'instruction',
          p_summary: '只处理 API 层',
          p_payload: {},
          p_board_visible: true,
        });
        return { data: 'announcement-1', error: null };
      },
    };

    const res = await appFor(db).request('/v1/crew/crew-1/announcements', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({
        recipientSessionIds: [sessionId],
        recipientMemberIds: [memberId],
        messageKind: 'instruction',
        summary: '只处理 API 层',
      }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ announcementId: 'announcement-1' });
  });

  it('creates an all-session broadcast when no mentions are supplied', async () => {
    const db = makeFakeDb();
    db.rpcs = {
      create_crew_announcement: (args) => {
        expect(args).toMatchObject({
          p_recipient_session_ids: [],
          p_recipient_member_ids: [],
          p_summary: '全员同步一下状态',
        });
        return { data: 'announcement-2', error: null };
      },
    };

    const res = await appFor(db).request('/v1/crew/crew-1/announcements', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-test-user-id': 'user-1',
      },
      body: JSON.stringify({ summary: '全员同步一下状态' }),
    });

    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ announcementId: 'announcement-2' });
  });
});

describe('GET /v1/crew/:id/announcements', () => {
  it('returns board-visible announcements with mention rows', async () => {
    const db = makeFakeDb({
      crew_announcements: [
        {
          id: 'announcement-1',
          crew_conversation_id: 'crew-1',
          responsible_subject_id: 'subject-1',
          sender_kind: 'session',
          sender_member_id: null,
          sender_session_id: 'session-1',
          recipient_mode: 'mentioned_targets',
          message_kind: 'question',
          board_visible: true,
          summary: '需要你确认权限',
          payload: {},
          created_at: '2026-05-24T00:00:00Z',
        },
      ],
      crew_announcement_mentions: [
        {
          id: 'mention-1',
          announcement_id: 'announcement-1',
          target_kind: 'member',
          target_session_id: null,
          target_member_id: 'member-1',
          created_at: '2026-05-24T00:00:01Z',
        },
      ],
    });

    const res = await appFor(db).request('/v1/crew/crew-1/announcements', {
      headers: { 'x-test-user-id': 'user-1' },
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: Array<{ mentions: unknown[] }> };
    expect(body.items).toHaveLength(1);
    expect(body.items[0].mentions).toHaveLength(1);
  });
});

describe('GET /v1/crew/sessions/:sessionId/events', () => {
  it('lists session events in chronological order', async () => {
    const db = makeFakeDb({
      session_events: [
        {
          id: 'event-2',
          crew_session_id: 'session-1',
          event_type: 'status',
          visibility: 'crew_members',
          summary: '开始',
          payload: {},
          created_at: '2026-05-24T00:01:00Z',
        },
        {
          id: 'event-1',
          crew_session_id: 'session-1',
          event_type: 'queued',
          visibility: 'crew_members',
          summary: '排队',
          payload: {},
          created_at: '2026-05-24T00:00:00Z',
        },
      ],
    });

    const res = await appFor(db).request('/v1/crew/sessions/session-1/events', {
      headers: { 'x-test-user-id': 'user-1' },
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: Array<{ id: string }> };
    expect(body.items.map((item) => item.id)).toEqual(['event-1', 'event-2']);
  });
});
