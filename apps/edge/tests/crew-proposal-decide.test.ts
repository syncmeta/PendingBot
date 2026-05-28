import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import type { MiddlewareHandler } from 'hono';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
  type Row,
} from './_helpers/fake-supabase';
import type { AppBindings } from '../src/types';

// Tests for POST /v1/messages/:id/crew-proposal/decide (spec v2 §6.4).
//
// Pins the product contract:
//   • Only humans in the proposal's conversation may decide. Cross-user
//     attempts and non-member calls get 403 crew_proposal_forbidden.
//   • Unknown ids / wrong log_kind → 404 crew_proposal_not_found.
//   • A second decide call on an already-decided proposal → 409
//     crew_proposal_already_decided, surface existing decision.
//   • approve → calls create_crew_with_captain with captain_source=
//     reuse_bot, returns the new crewId, stamps payload.status=approved.
//   • reject → no RPC call, stamps payload.status=rejected.

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

// Stub the heavy llm / billing / runner imports that messages.ts pulls
// in at module load — this endpoint doesn't use them but ESM evaluates
// the whole file.
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

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let messageRoutes: any;
let env: ReturnType<typeof makeFakeEnv>;

async function call(
  path: string,
  body: { decision?: 'approve' | 'reject' } | undefined,
  userId: string,
): Promise<{
  status: number;
  body: {
    ok?: boolean;
    status?: string;
    crewId?: string;
    error?: { code?: string; message?: string; detail?: unknown };
  };
}> {
  const app = new Hono<AppBindings>();
  app.route('/v1/messages', messageRoutes);
  const headers: Record<string, string> = {
    'x-test-user-id': userId,
    'content-type': 'application/json',
  };
  const init: RequestInit = {
    method: 'POST',
    headers,
    body: JSON.stringify(body ?? {}),
  };
  const res = await app.request(path, init, env);
  let parsed: { ok?: boolean; status?: string; crewId?: string; error?: { code?: string; message?: string; detail?: unknown } } = {};
  try {
    parsed = (await res.json()) as typeof parsed;
  } catch {
    /* empty */
  }
  return { status: res.status, body: parsed };
}

beforeEach(async () => {
  ({ messageRoutes } = await import('../src/routes/messages'));
});

function mkProposal(overrides: Partial<Row> = {}): Row {
  return {
    id: '11111111-1111-1111-1111-111111111111',
    user_id: null,
    sender_bot_id: 'bot-aaa',
    conversation_id: 'conv-userbot',
    role: 'log',
    log_kind: 'crew_proposal',
    log_payload: {
      proposed_by_bot_id: 'bot-aaa',
      proposed_name: '研究小队',
      proposed_tag: '研究',
      proposed_working_directory: null,
      proposed_parent_crew_id: null,
      proposed_initial_brief: null,
      status: 'pending',
    },
    status: 'done',
    created_at: '2026-05-28T00:00:00Z',
    ...overrides,
  };
}

function freshSeed(): FakeDb {
  const db = makeFakeDb({
    messages: [
      mkProposal({
        id: '11111111-1111-1111-1111-111111111111',
        conversation_id: 'conv-userbot',
      }),
      // A non-crew_proposal log row — must 404 with crew_proposal_not_found.
      {
        id: '22222222-2222-2222-2222-222222222222',
        role: 'log',
        log_kind: 'recall',
        conversation_id: 'conv-userbot',
        log_payload: {},
        status: 'done',
      },
      // A normal bot reply — must 404 (not a log row at all).
      {
        id: '33333333-3333-3333-3333-333333333333',
        role: 'bot',
        log_kind: null,
        conversation_id: 'conv-userbot',
        log_payload: null,
        status: 'done',
      },
      // Already-decided proposal — exercises the idempotent 409 path.
      mkProposal({
        id: '44444444-4444-4444-4444-444444444444',
        conversation_id: 'conv-userbot',
        log_payload: {
          proposed_by_bot_id: 'bot-aaa',
          proposed_name: '研究小队',
          status: 'approved',
          crew_id: 'crew-xyz',
          decided_by: 'alice',
        },
      }),
      // Proposal in a group conv — for membership tests.
      mkProposal({
        id: '55555555-5555-4555-8555-555555555555',
        conversation_id: 'conv-group',
      }),
    ],
    conversations: [
      {
        id: 'conv-userbot',
        conversation_type: 'user_bot',
        user_id: 'alice',
        responsible_subject_id: 'subj-alice',
      },
      {
        id: 'conv-group',
        conversation_type: 'group',
        user_id: 'alice',
        responsible_subject_id: 'subj-alice',
      },
    ],
    conversation_participants: [
      // alice is a participant of conv-group; bob is not.
      {
        conversation_id: 'conv-group',
        participant_type: 'user',
        participant_id: 'alice',
        role: 'owner',
      },
    ],
  });

  // Stub RPCs the approve path hits.
  db.rpcs = {
    create_crew_with_captain: (args) => {
      // Pin the contract: we always pass captain_source=reuse_bot with
      // the proposing bot id, the conv's responsible subject, and
      // runtime_location=local_host.
      if (args.p_captain_source !== 'reuse_bot') {
        return { error: { code: '22023', message: 'expected captain_source=reuse_bot' } };
      }
      if (!args.p_captain_bot_id) {
        return { error: { code: '22023', message: 'missing captain bot id' } };
      }
      if (args.p_runtime_location !== 'local_host') {
        return { error: { code: '22023', message: 'expected local_host' } };
      }
      return { data: 'crew-new-001' };
    },
    crew_attach_as_child: () => ({ data: null }),
  };

  return db;
}

function envWith(seed: FakeDb) {
  return makeFakeEnv(seed);
}

describe('POST /v1/messages/:id/crew-proposal/decide — error paths', () => {
  it('400 invalid_id for non-uuid', async () => {
    env = envWith(freshSeed());
    const r = await call('/v1/messages/not-a-uuid/crew-proposal/decide', { decision: 'approve' }, 'alice');
    expect(r.status).toBe(400);
    expect(r.body.error?.code).toBe('invalid_id');
  });

  it('400 invalid_body when decision missing', async () => {
    env = envWith(freshSeed());
    const r = await call(
      '/v1/messages/11111111-1111-1111-1111-111111111111/crew-proposal/decide',
      undefined,
      'alice',
    );
    expect(r.status).toBe(400);
    expect(r.body.error?.code).toBe('invalid_body');
  });

  it('404 crew_proposal_not_found when row is the wrong log_kind', async () => {
    env = envWith(freshSeed());
    const r = await call(
      '/v1/messages/22222222-2222-2222-2222-222222222222/crew-proposal/decide',
      { decision: 'approve' },
      'alice',
    );
    expect(r.status).toBe(404);
    expect(r.body.error?.code).toBe('crew_proposal_not_found');
  });

  it('404 crew_proposal_not_found for a normal bot reply', async () => {
    env = envWith(freshSeed());
    const r = await call(
      '/v1/messages/33333333-3333-3333-3333-333333333333/crew-proposal/decide',
      { decision: 'approve' },
      'alice',
    );
    expect(r.status).toBe(404);
    expect(r.body.error?.code).toBe('crew_proposal_not_found');
  });

  it('403 crew_proposal_forbidden when caller is not a conv member', async () => {
    env = envWith(freshSeed());
    // bob isn't on conv-userbot (alice's user_bot conv) — must be refused.
    const r = await call(
      '/v1/messages/11111111-1111-1111-1111-111111111111/crew-proposal/decide',
      { decision: 'approve' },
      'bob',
    );
    expect(r.status).toBe(403);
    expect(r.body.error?.code).toBe('crew_proposal_forbidden');
  });

  it('409 crew_proposal_already_decided is idempotent surface', async () => {
    env = envWith(freshSeed());
    const r = await call(
      '/v1/messages/44444444-4444-4444-4444-444444444444/crew-proposal/decide',
      { decision: 'reject' },
      'alice',
    );
    expect(r.status).toBe(409);
    expect(r.body.error?.code).toBe('crew_proposal_already_decided');
    expect(r.body.error?.detail).toMatchObject({ status: 'approved', crew_id: 'crew-xyz' });
  });
});

describe('POST /v1/messages/:id/crew-proposal/decide — approve path', () => {
  it('returns crewId and stamps payload status=approved', async () => {
    const seed = freshSeed();
    env = envWith(seed);
    const r = await call(
      '/v1/messages/11111111-1111-1111-1111-111111111111/crew-proposal/decide',
      { decision: 'approve' },
      'alice',
    );
    expect(r.status).toBe(200);
    expect(r.body.ok).toBe(true);
    expect(r.body.status).toBe('approved');
    expect(r.body.crewId).toBe('crew-new-001');

    // The message row should now have a new payload with status=approved.
    const updated = seed.rows.messages.find(
      (m) => m.id === '11111111-1111-1111-1111-111111111111',
    );
    expect(updated).toBeDefined();
    const payload = updated?.log_payload as Record<string, unknown> | undefined;
    expect(payload?.status).toBe('approved');
    expect(payload?.crew_id).toBe('crew-new-001');
    expect(payload?.decided_by).toBe('alice');
    expect(payload?.decided_at).toEqual(expect.any(String));
  });

  it('group conv: member can approve', async () => {
    env = envWith(freshSeed());
    const r = await call(
      '/v1/messages/55555555-5555-4555-8555-555555555555/crew-proposal/decide',
      { decision: 'approve' },
      'alice',
    );
    expect(r.status).toBe(200);
    expect(r.body.status).toBe('approved');
    expect(r.body.crewId).toBe('crew-new-001');
  });

  it('group conv: non-member rejected with 403', async () => {
    env = envWith(freshSeed());
    const r = await call(
      '/v1/messages/55555555-5555-4555-8555-555555555555/crew-proposal/decide',
      { decision: 'approve' },
      'bob',
    );
    expect(r.status).toBe(403);
    expect(r.body.error?.code).toBe('crew_proposal_forbidden');
  });
});

describe('POST /v1/messages/:id/crew-proposal/decide — reject path', () => {
  it('stamps payload status=rejected and skips the RPC', async () => {
    const seed = freshSeed();
    // Sentinel: a thrown error from the RPC would surface if reject
    // accidentally invokes it. Replace with a hard throw to detect.
    seed.rpcs = {
      create_crew_with_captain: () => {
        throw new Error('reject path must not call create_crew_with_captain');
      },
      crew_attach_as_child: () => ({ data: null }),
    };
    env = envWith(seed);
    const r = await call(
      '/v1/messages/11111111-1111-1111-1111-111111111111/crew-proposal/decide',
      { decision: 'reject' },
      'alice',
    );
    expect(r.status).toBe(200);
    expect(r.body.ok).toBe(true);
    expect(r.body.status).toBe('rejected');

    const updated = seed.rows.messages.find(
      (m) => m.id === '11111111-1111-1111-1111-111111111111',
    );
    const payload = updated?.log_payload as Record<string, unknown> | undefined;
    expect(payload?.status).toBe('rejected');
    expect(payload?.decided_by).toBe('alice');
    expect(payload?.crew_id).toBeUndefined();
  });
});
