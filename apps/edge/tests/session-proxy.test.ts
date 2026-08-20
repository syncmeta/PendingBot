import { beforeEach, describe, expect, it } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
} from './_helpers/fake-supabase';
import type { Env } from '../src/types';

// T4.5 P0 — SessionProxyDO unit tests (spec v2 §8.2 + §9.6).
//
// Vitest runs in plain node — there is no real WebSocketPair /
// DurableObjectState here. We construct the DO with a fake state (just the
// storage subset it uses) + the fake-supabase env, build peers via the test
// seam (__makePeerForTest), and drive the message router (onMessage)
// directly with FakeWebSocket sinks. This pins the routing/queue/broadcast
// contract without the live upgrade plumbing (which the route handles).
//
// Covered:
//   • subscribe viewer / runner → ack
//   • role spoofing rejected (viewer can't subscribe as runner)
//   • command routing: runner online → delivered; offline → queued + flushed
//     on runner reconnect
//   • session.state broadcast to many viewers (and not to the runner)
//   • permission.request → persisted (RPC) + fanned to viewers
//   • permission.decision → persisted (RPC) + routed to runner

installFakeSupabaseMock();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let SessionProxyDO: any;

const SESSION_ID = '11111111-1111-1111-1111-111111111111';
const SUBJECT = '22222222-2222-2222-2222-222222222222';
const USER = '33333333-3333-3333-3333-333333333333';
const REQUEST_ID = '44444444-4444-4444-4444-444444444444';

beforeEach(async () => {
  ({ SessionProxyDO } = await import('../src/durable-objects/session-proxy'));
});

// ── fakes ────────────────────────────────────────────────────────────

interface SentFrame {
  type: string;
  [k: string]: unknown;
}

// Minimal WebSocket stand-in: records every frame sent to it. Listeners are
// unused (the test drives onMessage directly), but present so attach() — if
// a test ever calls it — won't throw.
class FakeWebSocket {
  sent: SentFrame[] = [];
  closed = false;
  closeReason: string | undefined;
  send(data: string): void {
    this.sent.push(JSON.parse(data) as SentFrame);
  }
  close(_code?: number, reason?: string): void {
    this.closed = true;
    this.closeReason = reason;
  }
  addEventListener(): void {
    /* no-op for the unit path */
  }
  // last frame of a given type, for terse assertions
  last(type: string): SentFrame | undefined {
    return [...this.sent].reverse().find((f) => f.type === type);
  }
  count(type: string): number {
    return this.sent.filter((f) => f.type === type).length;
  }
}

// In-memory DurableObjectState.storage subset the DO touches.
function makeFakeState() {
  const map = new Map<string, unknown>();
  return {
    storage: {
      // eslint-disable-next-line @typescript-eslint/require-await
      async get<T>(key: string): Promise<T | undefined> {
        return map.get(key) as T | undefined;
      },
      // eslint-disable-next-line @typescript-eslint/require-await
      async put(key: string, value: unknown): Promise<void> {
        map.set(key, value);
      },
      // eslint-disable-next-line @typescript-eslint/require-await
      async delete(key: string): Promise<boolean> {
        return map.delete(key);
      },
    },
    _map: map,
  };
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeDO(env: Env): any {
  const state = makeFakeState();
  return new SessionProxyDO(state, env);
}

function frame(obj: Record<string, unknown>): string {
  return JSON.stringify(obj);
}

function viewerPeer(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  doInstance: any,
  ws: FakeWebSocket,
  userId: string | null = USER,
) {
  return doInstance.__makePeerForTest({
    role: 'viewer',
    ws,
    subjectId: SUBJECT,
    userId,
    sessionId: SESSION_ID,
  });
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function runnerPeer(doInstance: any, ws: FakeWebSocket) {
  return doInstance.__makePeerForTest({
    role: 'runner',
    ws,
    subjectId: SUBJECT,
    userId: USER,
    sessionId: SESSION_ID,
  });
}

function envWith(rpcs: FakeDb['rpcs']): Env {
  const db = makeFakeDb();
  db.rpcs = rpcs;
  return makeFakeEnv(db);
}

// ── subscribe ──────────────────────────────────────────────────────

describe('SessionProxyDO subscribe', () => {
  it('acks a viewer subscribe', async () => {
    const env = envWith({});
    const dao = makeDO(env);
    const ws = new FakeWebSocket();
    const peer = viewerPeer(dao, ws);
    await dao.onMessage(peer, frame({ type: 'subscribe', role: 'viewer' }));
    const ack = ws.last('subscribed');
    expect(ack).toMatchObject({ type: 'subscribed', sessionId: SESSION_ID, role: 'viewer' });
  });

  it('acks a runner subscribe', async () => {
    const env = envWith({});
    const dao = makeDO(env);
    const ws = new FakeWebSocket();
    const peer = runnerPeer(dao, ws);
    await dao.onMessage(peer, frame({ type: 'subscribe', role: 'runner' }));
    expect(ws.last('subscribed')).toMatchObject({ role: 'runner' });
  });

  it('rejects a viewer claiming runner role in the subscribe frame', async () => {
    const env = envWith({});
    const dao = makeDO(env);
    const ws = new FakeWebSocket();
    const peer = viewerPeer(dao, ws);
    await dao.onMessage(peer, frame({ type: 'subscribe', role: 'runner' }));
    expect(ws.last('error')).toMatchObject({ code: 'role_mismatch' });
    expect(ws.last('subscribed')).toBeUndefined();
  });
});

// ── command routing ─────────────────────────────────────────────────

describe('SessionProxyDO session.command routing', () => {
  it('delivers a command to a live runner and acks the sender', async () => {
    let enqueued: Record<string, unknown> | undefined;
    const env = envWith({
      enqueue_session_mailbox: (args) => {
        enqueued = args;
        return { data: 'mailbox-id', error: null };
      },
    });
    const dao = makeDO(env);

    const runnerWs = new FakeWebSocket();
    const runner = runnerPeer(dao, runnerWs);
    await dao.onMessage(runner, frame({ type: 'subscribe', role: 'runner' }));

    const viewerWs = new FakeWebSocket();
    const viewer = viewerPeer(dao, viewerWs);
    await dao.onMessage(viewer, frame({ type: 'subscribe', role: 'viewer' }));

    await dao.onMessage(
      viewer,
      frame({ type: 'session.command', command: { kind: 'send_instruction', payload: { text: 'go' } } }),
    );

    // Runner got the delivered command.
    const delivered = runnerWs.last('session.command');
    expect(delivered).toMatchObject({ type: 'session.command', command: { kind: 'send_instruction' } });
    expect(typeof delivered?.commandId).toBe('string');
    // Sender got a 'delivered' ack.
    expect(viewerWs.last('session.command.ack')).toMatchObject({ disposition: 'delivered' });
    // Always persisted to the durable mailbox.
    expect(enqueued).toMatchObject({
      p_session_id: SESSION_ID,
      p_message_kind: 'instruction',
    });
    expect((enqueued?.p_payload as Record<string, unknown>)?.command_kind).toBe('send_instruction');
  });

  it('queues a command when the runner is offline, then flushes on reconnect', async () => {
    const env = envWith({
      enqueue_session_mailbox: () => ({ data: 'mailbox-id', error: null }),
    });
    const dao = makeDO(env);

    const viewerWs = new FakeWebSocket();
    const viewer = viewerPeer(dao, viewerWs);
    await dao.onMessage(viewer, frame({ type: 'subscribe', role: 'viewer' }));

    // No runner connected yet.
    await dao.onMessage(
      viewer,
      frame({ type: 'session.command', command: { kind: 'cmd_a', payload: { n: 1 } } }),
    );
    await dao.onMessage(
      viewer,
      frame({ type: 'session.command', command: { kind: 'cmd_b', payload: { n: 2 } } }),
    );

    // Both acked as queued.
    expect(viewerWs.count('session.command.ack')).toBe(2);
    expect(viewerWs.last('session.command.ack')).toMatchObject({ disposition: 'queued' });

    // Runner connects → both commands flushed in order, marked queued.
    const runnerWs = new FakeWebSocket();
    const runner = runnerPeer(dao, runnerWs);
    await dao.onMessage(runner, frame({ type: 'subscribe', role: 'runner' }));

    const flushed = runnerWs.sent.filter((f) => f.type === 'session.command');
    expect(flushed).toHaveLength(2);
    expect(flushed[0]).toMatchObject({ command: { kind: 'cmd_a' }, queued: true });
    expect(flushed[1]).toMatchObject({ command: { kind: 'cmd_b' }, queued: true });
  });

  it('does not re-flush an already-drained queue on a second runner connect', async () => {
    const env = envWith({
      enqueue_session_mailbox: () => ({ data: 'mailbox-id', error: null }),
    });
    const dao = makeDO(env);

    const viewerWs = new FakeWebSocket();
    const viewer = viewerPeer(dao, viewerWs);
    await dao.onMessage(viewer, frame({ type: 'subscribe', role: 'viewer' }));
    await dao.onMessage(
      viewer,
      frame({ type: 'session.command', command: { kind: 'cmd_a' } }),
    );

    const runner1 = runnerPeer(dao, new FakeWebSocket());
    await dao.onMessage(runner1, frame({ type: 'subscribe', role: 'runner' }));

    // Second runner connect (e.g. reconnect) — queue already drained.
    const runner2Ws = new FakeWebSocket();
    const runner2 = runnerPeer(dao, runner2Ws);
    await dao.onMessage(runner2, frame({ type: 'subscribe', role: 'runner' }));
    expect(runner2Ws.count('session.command')).toBe(0);
  });
});

// ── state broadcast ─────────────────────────────────────────────────

describe('SessionProxyDO session.state broadcast', () => {
  it('fans runner state out to all viewers but not back to the runner', async () => {
    const env = envWith({});
    const dao = makeDO(env);

    const runnerWs = new FakeWebSocket();
    const runner = runnerPeer(dao, runnerWs);
    await dao.onMessage(runner, frame({ type: 'subscribe', role: 'runner' }));

    const v1 = new FakeWebSocket();
    const v2 = new FakeWebSocket();
    await dao.onMessage(viewerPeer(dao, v1), frame({ type: 'subscribe', role: 'viewer' }));
    await dao.onMessage(viewerPeer(dao, v2), frame({ type: 'subscribe', role: 'viewer' }));

    await dao.onMessage(
      runner,
      frame({ type: 'session.state', state: { status: 'running', progress: 0.4 } }),
    );

    expect(v1.last('session.state')).toMatchObject({ state: { status: 'running', progress: 0.4 } });
    expect(v2.last('session.state')).toMatchObject({ state: { status: 'running' } });
    // Runner doesn't get its own state echoed back.
    expect(runnerWs.count('session.state')).toBe(0);
  });

  it('rejects a viewer trying to publish session.state', async () => {
    const env = envWith({});
    const dao = makeDO(env);
    const ws = new FakeWebSocket();
    const viewer = viewerPeer(dao, ws);
    await dao.onMessage(viewer, frame({ type: 'subscribe', role: 'viewer' }));
    await dao.onMessage(viewer, frame({ type: 'session.state', state: { status: 'fake' } }));
    expect(ws.last('error')).toMatchObject({ code: 'forbidden' });
  });
});

// ── permission round-trip ───────────────────────────────────────────

describe('SessionProxyDO permission round-trip', () => {
  it('persists a runner permission.request and fans it to viewers', async () => {
    let created: Record<string, unknown> | undefined;
    const env = envWith({
      create_permission_request: (args) => {
        created = args;
        return { data: REQUEST_ID, error: null };
      },
    });
    const dao = makeDO(env);

    const runner = runnerPeer(dao, new FakeWebSocket());
    await dao.onMessage(runner, frame({ type: 'subscribe', role: 'runner' }));
    const viewerWs = new FakeWebSocket();
    await dao.onMessage(viewerPeer(dao, viewerWs), frame({ type: 'subscribe', role: 'viewer' }));

    await dao.onMessage(
      runner,
      frame({
        type: 'permission.request',
        request: { action: 'rm -rf build/', riskLevel: 'high', payload: { cwd: '/repo' } },
      }),
    );

    expect(created).toMatchObject({
      p_session_id: SESSION_ID,
      p_action: 'rm -rf build/',
      p_risk_level: 'high',
    });
    // Viewer sees the request carrying the persisted id.
    expect(viewerWs.last('permission.request')).toMatchObject({
      request: { id: REQUEST_ID, action: 'rm -rf build/' },
    });
  });

  it('persists a viewer permission.decision and routes it to the runner', async () => {
    let decided: Record<string, unknown> | undefined;
    const env = envWith({
      decide_permission_request: (args) => {
        decided = args;
        return { data: null, error: null };
      },
    });
    const dao = makeDO(env);

    const runnerWs = new FakeWebSocket();
    const runner = runnerPeer(dao, runnerWs);
    await dao.onMessage(runner, frame({ type: 'subscribe', role: 'runner' }));
    const viewerWs = new FakeWebSocket();
    const viewer = viewerPeer(dao, viewerWs);
    await dao.onMessage(viewer, frame({ type: 'subscribe', role: 'viewer' }));

    await dao.onMessage(
      viewer,
      frame({ type: 'permission.decision', requestId: REQUEST_ID, decision: 'approve' }),
    );

    expect(decided).toMatchObject({
      p_id: REQUEST_ID,
      p_decision: 'approve',
      p_caller_user_id: USER,
    });
    // Runner gets the decision so it can unblock.
    expect(runnerWs.last('permission.decision')).toMatchObject({
      requestId: REQUEST_ID,
      decision: 'approve',
    });
  });

  it('acks a permission.request back to the runner with the persisted id', async () => {
    const env = envWith({
      create_permission_request: () => ({ data: REQUEST_ID, error: null }),
    });
    const dao = makeDO(env);

    const runnerWs = new FakeWebSocket();
    const runner = runnerPeer(dao, runnerWs);
    await dao.onMessage(runner, frame({ type: 'subscribe', role: 'runner' }));

    await dao.onMessage(
      runner,
      frame({
        type: 'permission.request',
        // `id` is the runner's local correlation id — echoed back on the ack
        // so the runner can map the DO-persisted id onto its local approval.
        request: { id: 'local-approval-1', action: 'computer-use click' },
      }),
    );

    expect(runnerWs.last('permission.request.ack')).toMatchObject({
      clientRequestId: 'local-approval-1',
      requestId: REQUEST_ID,
    });
    // The runner does NOT receive the viewer fan-out of its own request.
    expect(runnerWs.count('permission.request')).toBe(0);
  });

  it('queues a viewer decision for an offline runner and flushes it on reconnect', async () => {
    const env = envWith({
      decide_permission_request: () => ({ data: null, error: null }),
    });
    const dao = makeDO(env);

    const viewerWs = new FakeWebSocket();
    const viewer = viewerPeer(dao, viewerWs);
    await dao.onMessage(viewer, frame({ type: 'subscribe', role: 'viewer' }));

    // No runner connected — the decision must not vanish.
    await dao.onMessage(
      viewer,
      frame({ type: 'permission.decision', requestId: REQUEST_ID, decision: 'reject' }),
    );

    const runnerWs = new FakeWebSocket();
    const runner = runnerPeer(dao, runnerWs);
    await dao.onMessage(runner, frame({ type: 'subscribe', role: 'runner' }));

    // Flushed from the offline queue as a session.command the runner already
    // knows how to consume.
    const flushed = runnerWs.last('session.command');
    expect(flushed).toMatchObject({
      command: {
        kind: 'permission.decision',
        payload: { requestId: REQUEST_ID, decision: 'reject' },
      },
      queued: true,
    });
  });

  it('rejects a runner submitting a permission.decision', async () => {
    const env = envWith({});
    const dao = makeDO(env);
    const ws = new FakeWebSocket();
    const runner = runnerPeer(dao, ws);
    await dao.onMessage(runner, frame({ type: 'subscribe', role: 'runner' }));
    await dao.onMessage(
      runner,
      frame({ type: 'permission.decision', requestId: REQUEST_ID, decision: 'approve' }),
    );
    expect(ws.last('error')).toMatchObject({ code: 'forbidden' });
  });
});
