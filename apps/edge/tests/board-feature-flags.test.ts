import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import {
  billingEnabled,
  posthogEnabled,
  __resetFlagCacheForTest,
} from '../src/lib/feature-flags';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
  type FakeKv,
} from './_helpers/fake-supabase';
import type { AppBindings, Env } from '../src/types';

afterEach(() => __resetFlagCacheForTest());

// board 门禁现在全在 cf-access:requireCfAccess 校验 Access JWT 并取 email,
// requireBoardAdmin 查 BOARD_ADMIN_EMAILS 名单。测试里把 x-test-user-id 映射成
// email,admin-1 当唯一管理员(真实 JWT/JWKS + 名单逻辑由 cf-access.test.ts 覆盖)。
vi.mock('../src/lib/cf-access', () => ({
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  requireCfAccess: () => async (c: any, next: any) => {
    const u = c.req.header('x-test-user-id');
    if (!u) return c.json({ error: { code: 'forbidden' } }, 403);
    c.set('boardEmail', `${u}@board.test`);
    await next();
  },
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  requireBoardAdmin: () => async (c: any, next: any) => {
    if (c.var.boardEmail !== 'admin-1@board.test') {
      return c.json({ error: { code: 'forbidden' } }, 403);
    }
    await next();
  },
}));

installFakeSupabaseMock();

// Minimal env: env defaults + a controllable MEMORY KV.
function envWith(opts: {
  billingEnv?: string;
  kv?: Record<string, unknown>;
  kvThrows?: boolean;
}): Env {
  const store = opts.kv ?? {};
  return {
    BILLING_ENABLED: opts.billingEnv,
    POSTHOG_ENABLED: undefined,
    LANGFUSE_ENABLED: undefined,
    MEMORY: {
      get: async (key: string, _type?: string) => {
        if (opts.kvThrows) throw new Error('kv down');
        return store[key] ?? null;
      },
      put: async () => {},
    },
  } as unknown as Env;
}

describe('feature flag: KV override ?? env default', () => {
  it('uses env default when no KV override', async () => {
    const env = envWith({ billingEnv: 'true', kv: {} });
    expect(await billingEnabled(env, 1)).toBe(true);
  });

  it('KV override wins over env default', async () => {
    const env = envWith({ billingEnv: 'true', kv: { 'cfg:feature-flags': { billing: false } } });
    expect(await billingEnabled(env, 1)).toBe(false); // override false beats env true
  });

  it('falls back to env when KV read throws (never blocks)', async () => {
    const env = envWith({ billingEnv: 'true', kvThrows: true });
    expect(await billingEnabled(env, 1)).toBe(true); // KV down → env true
    expect(await posthogEnabled(env, 1)).toBe(false); // env undefined → false
  });
});

// ── 端点 GET/PUT /v1/board/feature-flags ─────────────────────────
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let boardRoutes: any;

beforeEach(async () => {
  ({ boardRoutes } = await import('../src/routes/board'));
});

function appFor(db: FakeDb, kv?: FakeKv) {
  const app = new Hono<AppBindings>();
  app.route('/v1/board', boardRoutes);
  const env = makeFakeEnv(db, kv ? { kv } : undefined);
  return {
    request: (path: string, init?: RequestInit) => app.request(path, init, env),
    kv: (env as unknown as { __fakeKv: FakeKv }).__fakeKv,
  };
}

const adminDb = (): FakeDb => makeFakeDb({ users: [{ id: 'admin-1', is_admin: true }] });

describe('GET /v1/board/feature-flags', () => {
  it('returns 4 keys with override/envDefault/effective; sentry readonly', async () => {
    const kv: FakeKv = { store: { 'cfg:feature-flags': { billing: false } }, throws: false };
    const res = await appFor(adminDb(), kv).request('/v1/board/feature-flags', {
      headers: { 'x-test-user-id': 'admin-1' },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      data: Record<string, { override: boolean | null; envDefault: boolean; effective: boolean; readonly?: boolean }>;
    };
    expect(Object.keys(body.data).sort()).toEqual(['billing', 'langfuse', 'posthog', 'sentry']);
    // billing override false beats env default (makeFakeEnv sets BILLING_ENABLED='true').
    expect(body.data.billing).toEqual({ override: false, envDefault: true, effective: false });
    // posthog/langfuse: no override, env unset → all false.
    expect(body.data.posthog).toEqual({ override: null, envDefault: false, effective: false });
    expect(body.data.sentry.readonly).toBe(true);
    expect(body.data.sentry.override).toBe(null);
  });

  it('rejects a non-admin user with 403 (board root gate)', async () => {
    const db = makeFakeDb({ users: [{ id: 'user-2', is_admin: false }] });
    const res = await appFor(db).request('/v1/board/feature-flags', {
      headers: { 'x-test-user-id': 'user-2' },
    });
    expect(res.status).toBe(403);
  });
});

describe('PUT /v1/board/feature-flags', () => {
  it('sets an override + writes an admin_audit(update, feature_flags) row', async () => {
    const db = adminDb();
    const a = appFor(db);
    const res = await a.request('/v1/board/feature-flags', {
      method: 'PUT',
      headers: { 'x-test-user-id': 'admin-1', 'content-type': 'application/json' },
      body: JSON.stringify({ billing: false }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { data: Record<string, boolean> };
    expect(body.data).toEqual({ billing: false });
    // KV blob persisted.
    expect(a.kv.store['cfg:feature-flags']).toEqual({ billing: false });
    // Audit row.
    const audits = db.inserts.filter((i) => i.table === 'admin_audit');
    expect(audits).toHaveLength(1);
    expect(audits[0].row.action).toBe('update');
    expect(audits[0].row.target_kind).toBe('feature_flags');
    expect(audits[0].row.target_id).toBe('cfg:feature-flags');
    expect(audits[0].row.actor_email).toBe('admin-1@board.test');
    expect(audits[0].row.actor_id).toBeNull();
  });

  it('null clears an existing override (key removed from blob)', async () => {
    const kv: FakeKv = { store: { 'cfg:feature-flags': { billing: false, posthog: true } }, throws: false };
    const a = appFor(adminDb(), kv);
    const res = await a.request('/v1/board/feature-flags', {
      method: 'PUT',
      headers: { 'x-test-user-id': 'admin-1', 'content-type': 'application/json' },
      body: JSON.stringify({ billing: null }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { data: Record<string, boolean> };
    expect(body.data).toEqual({ posthog: true }); // billing cleared, posthog untouched
    expect(a.kv.store['cfg:feature-flags']).toEqual({ posthog: true });
  });

  it('rejects an invalid body with 400 invalid_body', async () => {
    const res = await appFor(adminDb()).request('/v1/board/feature-flags', {
      method: 'PUT',
      headers: { 'x-test-user-id': 'admin-1', 'content-type': 'application/json' },
      body: JSON.stringify({ billing: 'yes' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_body');
  });
});
