// Failed LLM turns must leave a row behind.
//
// Until now every non-'success' outcome was invisible after the fact:
// `audit_log` had status / error_class / route_trace columns and
// persistAuditMessage wrote them, but the thrown FallbackError carried
// its real cause (lastError, routeTrace) on the object where nobody read
// it, so the only thing that ever reached a human was the contentless
// "withFallback exhausted (N attempts)".
//
// These tests pin the whole chain on the failure path:
//   runner throws → withFallback classifies + logs the fixed marker →
//   FallbackError message carries the cause → auditErrorFields shapes it →
//   enqueueAudit → persistAuditMessage → audit_log row with status='error',
//   an error_class from classifyError's vocabulary, the route_trace, and
//   NO billing debit.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeWallet,
} from '../../tests/_helpers/fake-supabase';

vi.mock('../lib/llm-trace', () => ({
  traceGeneration: async () => {},
}));

installFakeSupabaseMock();

import {
  auditErrorFields,
  enqueueAudit,
  FALLBACK_EXHAUSTED_MARKER,
  FallbackError,
  persistAuditMessage,
  withFallback,
  type ResolvedRoute,
} from './router';

const TURN_ID = '018f3333-3333-7333-8333-333333333333';

function envWith(db: ReturnType<typeof makeFakeDb>, wallet?: FakeWallet) {
  const env = makeFakeEnv(db, wallet ? { wallet } : undefined) as unknown as Record<
    string,
    unknown
  >;
  // resolveRoute needs the gateway coordinates + run token. The fake env
  // has no AUDIT_QUEUE binding, so enqueueAudit takes its inline-persist
  // fallback — the same code path a queue outage takes in production.
  env.CF_ACCOUNT_ID = 'acct-1';
  env.CF_AIG_GATEWAY = 'gw-1';
  env.CF_AIG_RUN_TOKEN = 'run-token';
  return env as never;
}

function seedConv() {
  return makeFakeDb({
    conversations: [
      { id: 'conv-1', conversation_type: 'user_bot', responsible_subject_id: null },
    ],
    subjects: [{ id: 'subj-1', kind: 'user_account', user_id: 'user-9' }],
  });
}

/// A fatal (non-retryable) upstream error — the shape classifyError maps
/// to 'auth', and the shape the 2026-08-19 production incident hit.
function authError() {
  return Object.assign(new Error('invalid x-api-key'), { status: 401 });
}

/// Run a withFallback call that is expected to give up, and hand back the
/// FallbackError. Fails the test loudly if it somehow succeeded.
async function expectExhausted(
  run: () => Promise<unknown>,
): Promise<FallbackError> {
  try {
    await run();
  } catch (err) {
    expect(err).toBeInstanceOf(FallbackError);
    return err as FallbackError;
  }
  throw new Error('expected withFallback to exhaust, but it resolved');
}

describe('withFallback — the thrown error carries the real cause', () => {
  beforeEach(() => vi.restoreAllMocks());

  it('names the error class, provider and upstream message in the message', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const db = seedConv();

    const err = await expectExhausted(() =>
      withFallback(
        null as never,
        envWith(db),
        { modelSlug: 'openai/gpt-5-mini', taskType: 'message_reply' },
        async () => {
          throw authError();
        },
      ),
    );

    // The old message was exactly "withFallback exhausted (1 attempt)" —
    // that prefix stays (logs/dashboards key off it) but the cause is now
    // appended instead of being dropped on the floor.
    expect(err.message).toContain('withFallback exhausted (1 attempt)');
    expect(err.message).toContain('auth');
    expect(err.message).toContain('invalid x-api-key');
    expect(err.message).toContain('openrouter');
  });

  it('emits one fixed-marker log line with the classified failure', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const db = seedConv();

    await withFallback(
      null as never,
      envWith(db),
      { modelSlug: 'openai/gpt-5-mini', taskType: 'title' },
      async () => {
        throw authError();
      },
    ).catch(() => undefined);

    const marked = spy.mock.calls.filter((c) => c[0] === FALLBACK_EXHAUSTED_MARKER);
    expect(marked).toHaveLength(1);
    const payload = JSON.parse(marked[0][1] as string);
    expect(payload).toMatchObject({
      task_type: 'title',
      model_slug: 'openai/gpt-5-mini',
      attempts: 1,
      error_class: 'auth',
      provider: 'openrouter',
    });
    expect(payload.route_trace).toHaveLength(1);
  });

  it('reports no_route when not even a provider could be resolved', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const db = seedConv();
    const env = envWith(db) as unknown as Record<string, unknown>;
    delete env.CF_AIG_RUN_TOKEN; // resolveRoute throws NoRouteError

    const err = await expectExhausted(() =>
      withFallback(
        null as never,
        env as never,
        { modelSlug: 'openai/gpt-5-mini', taskType: 'message_reply' },
        async () => 'never runs',
      ),
    );

    expect(auditErrorFields(err)).toMatchObject({
      route: null,
      errorClass: 'no_route',
    });
    expect(err.message).toContain('no route');
    expect(err.message).toContain('CF_AIG_RUN_TOKEN');
  });
});

describe('auditErrorFields — one error_class vocabulary for both branches', () => {
  it('classifies a plain runner throw instead of using its JS class name', () => {
    // Pre-fix, bot-reply put `err.name` here, so a mid-stream failure
    // landed in audit_log as 'Error' / 'TypeError' — useless for grouping.
    expect(auditErrorFields(authError())).toMatchObject({
      route: null,
      errorClass: 'auth',
      routeTrace: undefined,
    });
    expect(auditErrorFields(Object.assign(new Error('slow down'), { status: 429 })))
      .toMatchObject({ errorClass: 'rate_limit' });
  });
});

describe('failed turn → audit_log row', () => {
  beforeEach(() => vi.restoreAllMocks());

  it('lands status=error with the classified cause and the route trace, unbilled', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const db = seedConv();
    const wallet: FakeWallet = { calls: [], balances: { 'subj-1': 100_000_000 } };
    const env = envWith(db, wallet);

    // The production shape: a fatal upstream error inside the runner.
    const err = await expectExhausted(() =>
      withFallback(
        null as never,
        env,
        {
          modelSlug: 'openai/gpt-5-mini',
          taskType: 'message_reply',
          metadata: { userId: 'user-9', conversationId: 'conv-1', turnId: TURN_ID },
        },
        async () => {
          throw authError();
        },
      ),
    );

    const audit = auditErrorFields(err);
    await enqueueAudit(env, audit.route, {
      auditId: TURN_ID,
      userId: 'user-9',
      conversationId: 'conv-1',
      taskType: 'message_reply',
      startedAt: Date.now() - 120,
      status: 'error',
      errorClass: audit.errorClass,
      routeTrace: audit.routeTrace,
      metadata: { error_message: audit.message },
    });

    const rows = db.inserts.filter((i) => i.table === 'audit_log');
    expect(rows).toHaveLength(1);
    const row = rows[0].row as Record<string, unknown>;
    expect(row).toMatchObject({
      id: TURN_ID,
      status: 'error',
      error_class: 'auth',
      task_type: 'message_reply',
      conversation_id: 'conv-1',
    });

    // The whole point: the attempt that failed is queryable.
    const trace = row.route_trace as Array<Record<string, unknown>>;
    expect(trace).toHaveLength(1);
    expect(trace[0]).toMatchObject({
      attempt: 1,
      provider_slug: 'openrouter',
      status: 'fatal_err',
      error_class: 'auth',
    });
    expect(trace[0].error_message).toContain('invalid x-api-key');

    // A failed turn must not touch the wallet or the cost rollups. The
    // owner IS resolvable here (subj-1 has a funded balance), so this is
    // the real "billable user, zero cost" branch — not 'free' by accident.
    expect(row.cost_usd).toBeNull();
    expect(row.billing_status).toBe('skipped');
    expect(wallet.calls.filter((c) => c.path === '/debit')).toHaveLength(0);
  });

  it('records the turn even when no provider was ever reached (route null)', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const db = seedConv();
    const env = envWith(db) as unknown as Record<string, unknown>;
    delete env.CF_AIG_RUN_TOKEN;

    const err = await expectExhausted(() =>
      withFallback(
        null as never,
        env as never,
        { modelSlug: 'openai/gpt-5-mini', taskType: 'title' },
        async () => 'never runs',
      ),
    );

    const audit = auditErrorFields(err);
    await enqueueAudit(env as never, audit.route, {
      auditId: TURN_ID,
      conversationId: 'conv-1',
      taskType: 'title',
      startedAt: Date.now() - 5,
      status: 'error',
      errorClass: audit.errorClass,
      routeTrace: audit.routeTrace,
    });

    const row = db.inserts.find((i) => i.table === 'audit_log')!.row as Record<
      string,
      unknown
    >;
    expect(row).toMatchObject({
      status: 'error',
      error_class: 'no_route',
      // No route resolved → no model to name. '<unrouted>' keeps the
      // NOT NULL column honest without inventing a model id.
      model_id: '<unrouted>',
    });
    expect((row.route_trace as unknown[])).toHaveLength(1);
  });

  it('never queries the gateway for cost on a failed turn', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const fetchSpy = vi.spyOn(globalThis, 'fetch');
    const db = seedConv();

    await persistAuditMessage(envWith(db), {
      auditId: TURN_ID,
      latencyMs: 90,
      route: {
        modelToCall: 'openai/gpt-5-mini',
        provider: { slug: 'openrouter', apiStyle: 'chat' },
      } as unknown as ResolvedRoute,
      opts: {
        taskType: 'message_reply',
        status: 'error',
        errorClass: 'auth',
        conversationId: 'conv-1',
        userId: 'user-9',
        routeTrace: [{ attempt: 1, provider_slug: 'openrouter', status: 'fatal_err' }],
      },
    } as never);

    expect(fetchSpy).not.toHaveBeenCalled();
    const row = db.inserts.find((i) => i.table === 'audit_log')!.row as Record<
      string,
      unknown
    >;
    expect(row.cost_usd).toBeNull();
    expect(row.billing_status).not.toBe('billed');
  });
});
