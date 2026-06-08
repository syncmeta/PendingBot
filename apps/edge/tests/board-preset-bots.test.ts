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
