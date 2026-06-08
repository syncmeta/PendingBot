// apps/edge/tests/board-preset-bots.test.ts
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
} from './_helpers/fake-supabase';
import type { AppBindings } from '../src/types';

// 复刻 identity 中间件:requireSession 从 x-test-user-id 注入 userId;
// requireAdmin 忠实跑传入的 lookup(于是真实 isBoardAdmin 对 fake users 表生效)。
vi.mock('@pendingbot/identity', () => ({
  requireSession: () => async (c: any, next: any) => {
    const u = c.req.header('x-test-user-id');
    if (!u) return c.json({ error: { code: 'unauthorized' } }, 401);
    c.set('userId', u);
    c.set('userJwt', 'test-jwt');
    await next();
  },
  requireAdmin: (lookup: (c: any) => Promise<boolean>) => async (c: any, next: any) => {
    if (!c.var.userId) return c.json({ error: 'unauthorized' }, 401);
    const ok = await lookup(c);
    if (!ok) return c.json({ error: 'forbidden' }, 403);
    c.set('isAdmin', true);
    await next();
  },
}));

installFakeSupabaseMock();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let boardRoutes: any;

beforeEach(async () => {
  ({ boardRoutes } = await import('../src/routes/board'));
});

function appFor(db: FakeDb) {
  const app = new Hono<AppBindings>();
  app.route('/v1/board', boardRoutes);
  return {
    request: (path: string, init?: RequestInit) => app.request(path, init, makeFakeEnv(db)),
  };
}

const adminDb = (): FakeDb =>
  makeFakeDb({
    users: [{ id: 'admin-1', is_admin: true }],
    bots: [],
  });

describe('board admin gate', () => {
  it('rejects a non-admin user with 403', async () => {
    const db = makeFakeDb({ users: [{ id: 'user-2', is_admin: false }], bots: [] });
    const res = await appFor(db).request('/v1/board/preset-bots', {
      headers: { 'x-test-user-id': 'user-2' },
    });
    expect(res.status).toBe(403);
  });
});

describe('GET /v1/board/preset-bots', () => {
  it('lists only template rows (creator_id NULL) under { items }', async () => {
    const db = makeFakeDb({
      users: [{ id: 'admin-1', is_admin: true }],
      bots: [
        { id: 'b-tpl', slug: 'amet', display_name: 'Amet', model_id: 'm1', output_mode: 'single', is_active: true, visibility: 'private', config: {}, creator_id: null, created_at: 't', updated_at: 't' },
        { id: 'b-user', slug: 'amet', display_name: 'Clone', model_id: 'm1', output_mode: 'single', is_active: true, visibility: 'private', config: {}, creator_id: 'user-9', created_at: 't', updated_at: 't' },
      ],
    });
    const res = await appFor(db).request('/v1/board/preset-bots', {
      headers: { 'x-test-user-id': 'admin-1' },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: Array<Record<string, unknown>> };
    expect(body.items).toHaveLength(1);
    expect(body.items[0].id).toBe('b-tpl');
  });
});

describe('POST /v1/board/preset-bots', () => {
  it('creates a template row and writes an admin_audit(create) row', async () => {
    const db = adminDb();
    const res = await appFor(db).request('/v1/board/preset-bots', {
      method: 'POST',
      headers: { 'x-test-user-id': 'admin-1', 'content-type': 'application/json' },
      body: JSON.stringify({
        slug: 'novum',
        display_name: 'Novum',
        model_id: 'claude-opus-4.7',
        output_mode: 'single',
      }),
    });
    expect(res.status).toBe(200);
    const inserted = db.inserts.filter((i) => i.table === 'bots');
    expect(inserted).toHaveLength(1);
    // creator_id 由 fixedFields 显式钉成 null,把行标记为模板行(scope 可见)。
    expect(inserted[0].row).toHaveProperty('creator_id', null);
    const audits = db.inserts.filter((i) => i.table === 'admin_audit');
    expect(audits).toHaveLength(1);
    expect(audits[0].row.action).toBe('create');
    expect(audits[0].row.target_kind).toBe('preset_bot');
    expect(audits[0].row.actor_id).toBe('admin-1');
  });

  it('rejects an invalid body with 400 invalid_body', async () => {
    const db = adminDb();
    const res = await appFor(db).request('/v1/board/preset-bots', {
      method: 'POST',
      headers: { 'x-test-user-id': 'admin-1', 'content-type': 'application/json' },
      body: JSON.stringify({ display_name: 'no slug' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe('invalid_body');
  });
});
