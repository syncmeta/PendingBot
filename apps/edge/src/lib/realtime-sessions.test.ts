import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  REALTIME_SESSION_MAX_AGE_MS,
  endRealtimeSession,
  recordRealtimeSession,
  requireActiveSession,
  type RealtimeSession,
} from './realtime-sessions';
import type { Env } from '../types';

// realtime-sessions guards the voice-call /attach and /summary
// surface against replay. Tests pin the four rejection paths
// (session_not_found / _forbidden / _ended / _expired) and the
// happy path, plus the insert + end side effects. The Env wiring is
// faked by intercepting serviceClient(env).from(...).

interface FakeRow extends RealtimeSession {}

function makeFakeEnv(state: { rows: FakeRow[]; updates: Array<{ id: string; ended_at: string }>; reads: number }): Env {
  // Minimal mock that satisfies the shape `serviceClient(env)
  // .from('realtime_sessions')` expects. Only the methods the
  // module actually calls are implemented.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const env: any = {
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_SECRET_KEY: 'service-key',
    __fake: { state },
  };
  return env as Env;
}

// Replace the supabase service-role client with a hand-rolled query
// builder that reads/writes the in-memory `state.rows` array. We
// route through vi.mock so the test file never touches the real
// supabase-js network code.
vi.mock('./supabase', () => ({
  serviceClient: (env: Env) => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const state = (env as any).__fake.state as {
      rows: FakeRow[];
      updates: Array<{ id: string; ended_at: string }>;
      reads: number;
    };
    return {
      from(table: string) {
        if (table !== 'realtime_sessions') {
          throw new Error(`unexpected table: ${table}`);
        }
        return {
          select() {
            return this;
          },
          eq(_col: string, value: string) {
            (this as { _id?: string })._id = value;
            return this;
          },
          is(_col: string, _value: null) {
            (this as { _isNull?: boolean })._isNull = true;
            return this;
          },
          async maybeSingle() {
            state.reads += 1;
            const id = (this as { _id?: string })._id;
            const row = state.rows.find((r) => r.session_id === id);
            return { data: row ?? null, error: null };
          },
          async insert(row: FakeRow) {
            state.rows.push({
              ...row,
              created_at: row.created_at ?? new Date().toISOString(),
              ended_at: row.ended_at ?? null,
              openai_session_id: row.openai_session_id ?? null,
            });
            return { error: null };
          },
          update(patch: { ended_at: string }) {
            (this as { _patch?: typeof patch })._patch = patch;
            return this;
          },
          // .update(…).eq(session_id, X).is('ended_at', null)
          // resolves by side effect; awaiting the chain hits .then.
          then(this: { _id?: string; _isNull?: boolean; _patch?: { ended_at: string } }, resolve: (v: { error: null }) => void) {
            if (this._patch) {
              const id = this._id;
              const target = state.rows.find((r) => r.session_id === id);
              if (target && (this._isNull ? target.ended_at === null : true)) {
                target.ended_at = this._patch.ended_at;
                state.updates.push({ id: id!, ended_at: this._patch.ended_at });
              }
            }
            resolve({ error: null });
          },
        };
      },
    };
  },
}));

afterEach(() => {
  vi.useRealTimers();
});

function freshSession(overrides: Partial<RealtimeSession> = {}): RealtimeSession {
  return {
    session_id: 's1',
    user_id: 'u1',
    conversation_id: 'c1',
    bot_id: 'b1',
    created_at: new Date().toISOString(),
    ended_at: null,
    openai_session_id: null,
    ...overrides,
  };
}

describe('recordRealtimeSession', () => {
  it('inserts a row keyed by session_id', async () => {
    const state = { rows: [] as RealtimeSession[], updates: [], reads: 0 };
    const env = makeFakeEnv(state);
    await recordRealtimeSession(env, {
      session_id: 's-mint',
      user_id: 'u-mint',
      conversation_id: 'c-mint',
      bot_id: 'b-mint',
      openai_session_id: 'sess_openai_xxx',
    });
    expect(state.rows).toHaveLength(1);
    expect(state.rows[0]).toMatchObject({
      session_id: 's-mint',
      user_id: 'u-mint',
      conversation_id: 'c-mint',
      bot_id: 'b-mint',
      openai_session_id: 'sess_openai_xxx',
    });
  });
});

describe('requireActiveSession', () => {
  it('passes for a fresh session owned by the caller', async () => {
    const state = { rows: [freshSession()] as RealtimeSession[], updates: [], reads: 0 };
    const env = makeFakeEnv(state);
    const r = await requireActiveSession(env, 's1', 'u1');
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.session.user_id).toBe('u1');
  });

  it('rejects with 401 session_not_found for unknown ids', async () => {
    const state = { rows: [] as RealtimeSession[], updates: [], reads: 0 };
    const env = makeFakeEnv(state);
    const r = await requireActiveSession(env, 'ghost', 'u1');
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.status).toBe(401);
      expect(r.body.error).toBe('session_not_found');
    }
  });

  it('rejects with 403 session_forbidden for cross-user replay', async () => {
    // Attacker holds the original caller's session_id and tries to
    // /usage it against a different user JWT. Must not leak
    // existence information (404-vs-403) but does need to refuse —
    // 403 is deliberate per the helper's contract.
    const state = {
      rows: [freshSession({ session_id: 's1', user_id: 'alice' })] as RealtimeSession[],
      updates: [],
      reads: 0,
    };
    const env = makeFakeEnv(state);
    const r = await requireActiveSession(env, 's1', 'bob');
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.status).toBe(403);
      expect(r.body.error).toBe('session_forbidden');
    }
  });

  it('rejects with 410 session_ended when ended_at is set', async () => {
    const state = {
      rows: [freshSession({ ended_at: new Date().toISOString() })] as RealtimeSession[],
      updates: [],
      reads: 0,
    };
    const env = makeFakeEnv(state);
    const r = await requireActiveSession(env, 's1', 'u1');
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.status).toBe(410);
      expect(r.body.error).toBe('session_ended');
    }
  });

  it('rejects with 410 session_expired past REALTIME_SESSION_MAX_AGE_MS', async () => {
    const tooOld = new Date(Date.now() - REALTIME_SESSION_MAX_AGE_MS - 60_000).toISOString();
    const state = {
      rows: [freshSession({ created_at: tooOld })] as RealtimeSession[],
      updates: [],
      reads: 0,
    };
    const env = makeFakeEnv(state);
    const r = await requireActiveSession(env, 's1', 'u1');
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.status).toBe(410);
      expect(r.body.error).toBe('session_expired');
    }
  });

  it('auto-closes the row on age-out (fire-and-forget side effect)', async () => {
    const tooOld = new Date(Date.now() - REALTIME_SESSION_MAX_AGE_MS - 60_000).toISOString();
    const state = {
      rows: [freshSession({ created_at: tooOld })] as RealtimeSession[],
      updates: [] as Array<{ id: string; ended_at: string }>,
      reads: 0,
    };
    const env = makeFakeEnv(state);
    await requireActiveSession(env, 's1', 'u1');
    // The auto-close update fires via void promise; we don't await
    // it in production but in this test the synchronous fake settles
    // before we inspect state.
    await new Promise((r) => setTimeout(r, 0));
    expect(state.updates).toHaveLength(1);
    expect(state.updates[0].id).toBe('s1');
  });
});

describe('endRealtimeSession', () => {
  it('marks the row ended (idempotent — second call is a no-op)', async () => {
    const state = {
      rows: [freshSession()] as RealtimeSession[],
      updates: [] as Array<{ id: string; ended_at: string }>,
      reads: 0,
    };
    const env = makeFakeEnv(state);
    await endRealtimeSession(env, 's1');
    expect(state.rows[0].ended_at).not.toBeNull();
    const firstEndedAt = state.rows[0].ended_at;
    // Second call — `.is('ended_at', null)` guard means no further write
    await endRealtimeSession(env, 's1');
    expect(state.rows[0].ended_at).toBe(firstEndedAt);
  });
});
