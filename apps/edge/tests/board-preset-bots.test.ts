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
    const body = (await res.json()) as {
      items: Array<Record<string, unknown>>;
      total: number;
      has_more: boolean;
    };
    expect(body.items).toHaveLength(1);
    expect(body.items[0].id).toBe('b-tpl');
    // total reflects the scoped exact count (only template rows), not the page.
    expect(body.total).toBe(1);
    expect(body.has_more).toBe(false);
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
    expect(audits[0].row.actor_email).toBe('admin-1@board.test');
    expect(audits[0].row.actor_id).toBeNull();
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

  it('maps a unique-violation (slug 撞车) to 409 conflict, not 500', async () => {
    const db = adminDb();
    // 模拟 Postgres 唯一约束冲突(slug 已占用)。
    db.errors = {
      insert: () => ({
        code: '23505',
        message: 'duplicate key value violates unique constraint "bots_slug_key"',
        details: 'Key (slug)=(novum) already exists.',
      }),
    };
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
    expect(res.status).toBe(409);
    const body = (await res.json()) as { error: { code: string; detail?: string } };
    expect(body.error.code).toBe('conflict');
    expect(body.error.detail).toContain('slug');
    // 冲突时不落审计(写没成功)。
    expect(db.inserts.filter((i) => i.table === 'admin_audit')).toHaveLength(0);
  });
});
