// apps/edge/tests/board-preset-templates.test.ts
//
// Smoke tests for the two preset-template board resources (preset conversations
// + groups). The boardResource factory itself is covered in depth by
// board-preset-bots.test.ts; here we only assert the wiring (table / pk /
// targetKind) is correct for each mount.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Hono } from 'hono';
import { installFakeSupabaseMock, makeFakeDb, makeFakeEnv, type FakeDb } from './_helpers/fake-supabase';
import type { AppBindings } from '../src/types';

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

const ADMIN = { 'x-test-user-id': 'admin-1' };
const ADMIN_JSON = { ...ADMIN, 'content-type': 'application/json' };

describe('preset conversations', () => {
  it('lists templates under { items } with total', async () => {
    const db = makeFakeDb({
      preset_conversation_templates: [
        { slug: 'welcome', bot_slug: 'self', title: '读我', base_ts: 't', messages: [], sort_order: 10, enabled: true, updated_at: 't' },
      ],
    });
    const res = await appFor(db).request('/v1/board/preset-conversations', { headers: ADMIN });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: unknown[]; total: number };
    expect(body.items).toHaveLength(1);
    expect(body.total).toBe(1);
  });

  it('create writes a preset_conversation audit', async () => {
    const db = makeFakeDb({ preset_conversation_templates: [] });
    const res = await appFor(db).request('/v1/board/preset-conversations', {
      method: 'POST',
      headers: ADMIN_JSON,
      body: JSON.stringify({ slug: 'intro', bot_slug: 'self', title: 'Intro', messages: ['hi'] }),
    });
    expect(res.status).toBe(200);
    const audits = db.inserts.filter((i) => i.table === 'admin_audit');
    expect(audits).toHaveLength(1);
    expect(audits[0].row.target_kind).toBe('preset_conversation');
    expect(audits[0].row.actor_email).toBe('admin-1@board.test');
  });
});

describe('preset groups', () => {
  it('create writes a preset_group audit', async () => {
    const db = makeFakeDb({ preset_group_templates: [] });
    const res = await appFor(db).request('/v1/board/preset-groups', {
      method: 'POST',
      headers: ADMIN_JSON,
      body: JSON.stringify({ slug: 'study', title: '学习组', bot_slugs: ['tutor'], messages: [] }),
    });
    expect(res.status).toBe(200);
    const inserted = db.inserts.filter((i) => i.table === 'preset_group_templates');
    expect(inserted).toHaveLength(1);
    const audits = db.inserts.filter((i) => i.table === 'admin_audit');
    expect(audits[0].row.target_kind).toBe('preset_group');
  });

  it('non-admin is rejected 403', async () => {
    const db = makeFakeDb({ preset_group_templates: [] });
    const res = await appFor(db).request('/v1/board/preset-groups', {
      headers: { 'x-test-user-id': 'user-2' },
    });
    expect(res.status).toBe(403);
  });
});

describe('tools (P3 · edit-only)', () => {
  const seed = () =>
    makeFakeDb({
      tools: [
        { id: 't1', key: 'web_search', kind: 'native', enabled: true, scopes: ['chat'], model_description: null, description: null, notes: null, mcp_server_id: null, updated_at: 't' },
      ],
    });

  it('lists + patch toggles enabled and writes a tool audit', async () => {
    const db = seed();
    const list = await appFor(db).request('/v1/board/tools', { headers: ADMIN });
    expect(list.status).toBe(200);

    const res = await appFor(db).request('/v1/board/tools/t1', {
      method: 'PATCH',
      headers: ADMIN_JSON,
      body: JSON.stringify({ enabled: false, scopes: ['chat', 'envelope'] }),
    });
    expect(res.status).toBe(200);
    const audits = db.inserts.filter((i) => i.table === 'admin_audit');
    expect(audits.at(-1)?.row.target_kind).toBe('tool');
    expect(audits.at(-1)?.row.action).toBe('update');
  });

  it('rejects create (POST) — tools are not board-creatable (404)', async () => {
    const db = seed();
    const res = await appFor(db).request('/v1/board/tools', {
      method: 'POST',
      headers: ADMIN_JSON,
      body: JSON.stringify({ key: 'evil', kind: 'native' }),
    });
    expect(res.status).toBe(404);
  });

  it('rejects delete — tools are not board-deletable (404)', async () => {
    const db = seed();
    const res = await appFor(db).request('/v1/board/tools/t1', {
      method: 'DELETE',
      headers: ADMIN,
    });
    expect(res.status).toBe(404);
  });
});

describe('mcp servers (P4)', () => {
  it('create writes an mcp_server audit; list returns it', async () => {
    const db = makeFakeDb({ mcp_servers: [] });
    const res = await appFor(db).request('/v1/board/mcp-servers', {
      method: 'POST',
      headers: ADMIN_JSON,
      body: JSON.stringify({ name: 'ctx7', url: 'https://mcp.example/ctx7', transport: 'http', auth_kind: 'none' }),
    });
    expect(res.status).toBe(200);
    const inserted = db.inserts.filter((i) => i.table === 'mcp_servers');
    expect(inserted).toHaveLength(1);
    const audits = db.inserts.filter((i) => i.table === 'admin_audit');
    expect(audits.at(-1)?.row.target_kind).toBe('mcp_server');
  });

  it('rejects a non-url url with 400', async () => {
    const db = makeFakeDb({ mcp_servers: [] });
    const res = await appFor(db).request('/v1/board/mcp-servers', {
      method: 'POST',
      headers: ADMIN_JSON,
      body: JSON.stringify({ name: 'bad', url: 'not-a-url', transport: 'http', auth_kind: 'none' }),
    });
    expect(res.status).toBe(400);
  });
});

describe('preset letters', () => {
  it('lists letters + create writes a preset_letter audit', async () => {
    const db = makeFakeDb({
      preset_letters: [
        { slug: 'readme', title: '读我', summary: '欢迎', body_md: '# hi', version: 1, updated_at: 't' },
      ],
    });
    const list = await appFor(db).request('/v1/board/preset-letters', { headers: ADMIN });
    expect(list.status).toBe(200);
    expect(((await list.json()) as { items: unknown[] }).items).toHaveLength(1);

    const res = await appFor(db).request('/v1/board/preset-letters', {
      method: 'POST',
      headers: ADMIN_JSON,
      body: JSON.stringify({ slug: 'tips', title: '小贴士', summary: 's', body_md: '内容' }),
    });
    expect(res.status).toBe(200);
    const audits = db.inserts.filter((i) => i.table === 'admin_audit');
    expect(audits.at(-1)?.row.target_kind).toBe('preset_letter');
  });
});
