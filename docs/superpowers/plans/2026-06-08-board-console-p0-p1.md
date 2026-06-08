# Board Console CMS — P0 框架 + P1 预设机器人 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把被废的 board 在 Refine+AntD 上重建为「内容/预设/配置管理台」的第一个端到端纵切 —— edge `/v1/board/*` 门禁+审计框架,加第一个内容域(预设机器人)的全 CRUD,前端可登录、可增删改查。

**Architecture:** edge 侧一个 `boardResource(...)` CRUD 工厂(给定表/主键/字段/校验,生成 list/get/create/update/delete 五个端点,写操作自动落 `admin_audit` before/after),board 路由挂 `requireSession + requireAdmin`。前端复用现成的 edge-only dataProvider,换上 Ant Design,删旧运营页,加预设机器人 CRUD 页。预设机器人的源表就是 `pendingbot.bots` 里 `creator_id IS NULL` 的模板行 —— 零迁移。

**Tech Stack:** Hono on Cloudflare Workers · Zod · Supabase service-role client · Refine v5 + `@refinedev/antd` + Ant Design 5 · Vite · vitest(`@cloudflare/vitest-pool-workers` 跑在 Node + fake-supabase)。

**Design ref:** `docs/superpowers/specs/2026-06-08-board-console-cms-design.md`

---

## File Structure

**Edge(新建/改)**
- Create `apps/edge/src/lib/board-audit.ts` — `isBoardAdmin(c)` 管理员判定 + `recordBoardAudit(...)` 审计落地
- Create `apps/edge/src/lib/board-resource.ts` — `boardResource(opts)` CRUD 工厂(五端点 + 审计内建)
- Create `apps/edge/src/routes/board.ts` — board 根路由:挂门禁,挂载各资源子路由(P1 只挂 preset-bots)
- Modify `apps/edge/src/index.ts` — `import { boardRoutes }` + `v1.route('/board', boardRoutes)`
- Create `apps/edge/tests/board-preset-bots.test.ts` — 门禁 + CRUD + 审计单测

**前端 `apps/admin`(新建/改/删)**
- Modify `apps/admin/package.json` — 加 `@refinedev/antd` + `antd` 依赖
- Modify `apps/admin/src/providers/resource-map.ts` — 删旧资源,加 `preset_bots`(`board/preset-bots`, exists:true)
- Modify `apps/admin/src/App.tsx` — 换 AntD 布局 + 新资源
- Create `apps/admin/src/pages/preset-bots.tsx` — List / Create / Edit 三页
- Delete `apps/admin/src/pages/resources.tsx`、`queues.tsx`、`admin-actions.tsx`(旧运营页)

**约定(必须遵守,后续 P2–P4 复用)**
- edge 列表响应 `{ items: [...] }`;getOne/create/update 返回 `{ data: {...} }`;delete 返回 `{}`。(dataProvider 已按此 normalise。)
- 写操作错误用 `jsonError(c, status, code, opts?)` 信封;`code` 取自 `ApiErrorCode` union(已有 `invalid_body`/`not_found`/`forbidden`/`database_error` 等,够用,无需扩 union)。
- 审计 `target_kind` = 资源名(如 `'preset_bot'`),`target_id` = 行主键,`action` ∈ `'create'|'update'|'delete'`。

---

## Task 1: 管理员判定 + 审计落地 helper

**Files:**
- Create: `apps/edge/src/lib/board-audit.ts`
- Test: `apps/edge/tests/board-preset-bots.test.ts`(本任务先建文件 + 写 isBoardAdmin 的测,后续任务追加)

- [ ] **Step 1: 写 board-audit.ts**

```ts
// apps/edge/src/lib/board-audit.ts
//
// Board 管理台的两块公共件:
//   1. isBoardAdmin —— requireAdmin 的 lookup:查 pendingbot.users.is_admin。
//   2. recordBoardAudit —— 每次 board 写操作落一条 admin_audit(before/after)。
//
// admin_audit 表列(已存在,见 schema.ts):
//   action / actor_id / target_kind / target_id / before / after /
//   ip / user_agent / created_at / id
import type { Context } from 'hono';
import { serviceClient } from './supabase';
import type { AppBindings } from '../types';

// requireAdmin 的 isAdminLookup:当前会话用户是否 is_admin。
export async function isBoardAdmin(c: Context<AppBindings>): Promise<boolean> {
  const userId = c.var.userId;
  if (!userId) return false;
  const svc = serviceClient(c.env);
  const { data, error } = await svc
    .schema('pendingbot')
    .from('users')
    .select('is_admin')
    .eq('id', userId)
    .maybeSingle();
  if (error || !data) return false;
  return data.is_admin === true;
}

export interface BoardAuditInput {
  action: 'create' | 'update' | 'delete';
  targetKind: string;
  targetId: string | null;
  before: unknown;
  after: unknown;
}

// 落一条审计。失败不抛 —— 审计写失败不应让已成功的业务写回滚成错误,
// 但要 console.error 让其在 tail 里可见(审计漏写是要追的)。
export async function recordBoardAudit(
  c: Context<AppBindings>,
  input: BoardAuditInput,
): Promise<void> {
  try {
    const svc = serviceClient(c.env);
    await svc.schema('pendingbot').from('admin_audit').insert({
      actor_id: c.var.userId ?? null,
      action: input.action,
      target_kind: input.targetKind,
      target_id: input.targetId,
      before: (input.before ?? null) as never,
      after: (input.after ?? null) as never,
      ip: c.req.header('cf-connecting-ip') ?? null,
      user_agent: c.req.header('user-agent') ?? null,
    });
  } catch (err) {
    console.error('[board] audit insert failed', err);
  }
}
```

- [ ] **Step 2: 建测试文件 + 写 isBoardAdmin 的失败测**

```ts
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
```

- [ ] **Step 3: 跑测,确认 fail**

Run: `cd apps/edge && ./node_modules/.bin/vitest run tests/board-preset-bots.test.ts`
Expected: FAIL —— `../src/routes/board` 还不存在(import 报错)。本任务到此为止;board.ts 在 Task 3 建。

- [ ] **Step 4: 提交 helper**

```bash
cd /Users/hey/Untitled/Pendingname/PendingBot/dev/.claude/worktrees/charming-goldberg-0dafe3
git add apps/edge/src/lib/board-audit.ts apps/edge/tests/board-preset-bots.test.ts
git commit -m "edge(board): isBoardAdmin gate + recordBoardAudit helper

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: `boardResource` CRUD 工厂

**Files:**
- Create: `apps/edge/src/lib/board-resource.ts`

工厂产出一个挂在子路径上的 Hono app,五端点;写操作经 `recordBoardAudit` 落审计。P1 之后的 P2–P4 都靠再调用它,不再各写一遍 CRUD。

- [ ] **Step 1: 写 board-resource.ts**

```ts
// apps/edge/src/lib/board-resource.ts
//
// Board CMS 的 CRUD 工厂。给定表、主键、可见字段、可写 body 校验,产出
// 一个 Hono 子 app:
//   GET    /            列表        → { items: [...] }
//   GET    /:id         单条        → { data: {...} }
//   POST   /            新建        → { data: {...} }  + audit(create)
//   PATCH  /:id         改          → { data: {...} }  + audit(update, before/after)
//   DELETE /:id         删          → {}               + audit(delete, before)
//
// 所有写操作先读 before 快照再落审计 —— 审计不可被某条路径遗漏。
import { Hono } from 'hono';
import type { z } from 'zod';
import { serviceClient } from './supabase';
import { jsonError } from './http-error';
import { recordBoardAudit } from './board-audit';
import type { AppBindings } from '../types';

export interface BoardResourceOpts {
  // pendingbot 表名(serviceClient 会 .schema('pendingbot'))
  table: string;
  // 主键列名,'id' 或 'slug'
  pk: string;
  // admin_audit.target_kind 用的资源标识,如 'preset_bot'
  targetKind: string;
  // 列表 / 单条返回的列(逗号分隔的 select 串)
  cols: string;
  // 列表默认排序列 + 方向
  orderBy: { col: string; ascending: boolean };
  // 给列表/单条加固定过滤(如预设机器人只取 creator_id IS NULL 的模板)。
  // 传入 supabase query builder,返回加了过滤的同一个 builder。
  scope?: <Q>(q: Q) => Q;
  // create body 校验(全字段)
  createSchema: z.ZodTypeAny;
  // update body 校验(通常 .partial())
  updateSchema: z.ZodTypeAny;
}

export function boardResource(opts: BoardResourceOpts): Hono<AppBindings> {
  const app = new Hono<AppBindings>();
  const scope = opts.scope ?? (<Q>(q: Q) => q);

  // ── LIST ────────────────────────────────────────────────
  app.get('/', async (c) => {
    const svc = serviceClient(c.env);
    let q = svc.schema('pendingbot').from(opts.table).select(opts.cols);
    q = scope(q);
    const { data, error } = await q
      .order(opts.orderBy.col, { ascending: opts.orderBy.ascending })
      .limit(500);
    if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
    return c.json({ items: data ?? [] });
  });

  // ── GET ONE ─────────────────────────────────────────────
  app.get('/:id', async (c) => {
    const svc = serviceClient(c.env);
    let q = svc.schema('pendingbot').from(opts.table).select(opts.cols).eq(opts.pk, c.req.param('id'));
    q = scope(q);
    const { data, error } = await q.maybeSingle();
    if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
    if (!data) return jsonError(c, 404, 'not_found');
    return c.json({ data });
  });

  // ── CREATE ──────────────────────────────────────────────
  app.post('/', async (c) => {
    const body = await c.req.json().catch(() => null);
    const parsed = opts.createSchema.safeParse(body);
    if (!parsed.success) {
      return jsonError(c, 400, 'invalid_body', { detail: parsed.error.flatten() });
    }
    const svc = serviceClient(c.env);
    const { data, error } = await svc
      .schema('pendingbot')
      .from(opts.table)
      .insert(parsed.data as never)
      .select(opts.cols)
      .maybeSingle();
    if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
    await recordBoardAudit(c, {
      action: 'create',
      targetKind: opts.targetKind,
      targetId: (data as Record<string, unknown> | null)?.[opts.pk] as string ?? null,
      before: null,
      after: data,
    });
    return c.json({ data });
  });

  // ── UPDATE ──────────────────────────────────────────────
  app.patch('/:id', async (c) => {
    const id = c.req.param('id');
    const body = await c.req.json().catch(() => null);
    const parsed = opts.updateSchema.safeParse(body);
    if (!parsed.success) {
      return jsonError(c, 400, 'invalid_body', { detail: parsed.error.flatten() });
    }
    const svc = serviceClient(c.env);
    // before 快照(过 scope,防越权改非模板行)
    let beforeQ = svc.schema('pendingbot').from(opts.table).select(opts.cols).eq(opts.pk, id);
    beforeQ = scope(beforeQ);
    const { data: before } = await beforeQ.maybeSingle();
    if (!before) return jsonError(c, 404, 'not_found');

    const { data: after, error } = await svc
      .schema('pendingbot')
      .from(opts.table)
      .update(parsed.data as never)
      .eq(opts.pk, id)
      .select(opts.cols)
      .maybeSingle();
    if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
    await recordBoardAudit(c, {
      action: 'update',
      targetKind: opts.targetKind,
      targetId: id,
      before,
      after,
    });
    return c.json({ data: after });
  });

  // ── DELETE ──────────────────────────────────────────────
  app.delete('/:id', async (c) => {
    const id = c.req.param('id');
    const svc = serviceClient(c.env);
    let beforeQ = svc.schema('pendingbot').from(opts.table).select(opts.cols).eq(opts.pk, id);
    beforeQ = scope(beforeQ);
    const { data: before } = await beforeQ.maybeSingle();
    if (!before) return jsonError(c, 404, 'not_found');

    const { error } = await svc.schema('pendingbot').from(opts.table).delete().eq(opts.pk, id);
    if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
    await recordBoardAudit(c, {
      action: 'delete',
      targetKind: opts.targetKind,
      targetId: id,
      before,
      after: null,
    });
    return c.json({});
  });

  return app;
}
```

- [ ] **Step 2: typecheck**

Run: `bun --filter='@pendingbot/edge' run typecheck`
Expected: 通过(board.ts 尚未引用它也无妨;本文件自身类型自洽)。

- [ ] **Step 3: 提交工厂**

```bash
git add apps/edge/src/lib/board-resource.ts
git commit -m "edge(board): boardResource CRUD factory with built-in audit

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: board 根路由 + 预设机器人资源 + 挂载

**Files:**
- Create: `apps/edge/src/routes/board.ts`
- Modify: `apps/edge/src/index.ts`
- Test: `apps/edge/tests/board-preset-bots.test.ts`(追加 CRUD + 审计测)

预设机器人 = `pendingbot.bots` 里 `creator_id IS NULL` 的模板行。可编辑字段:`slug / display_name / model_id / output_mode / is_active / visibility / config(jsonb,装 system prompt 等)`。

- [ ] **Step 1: 写 board.ts**

```ts
// apps/edge/src/routes/board.ts
//
// Board 管理台根路由。挂 requireSession → requireAdmin(isBoardAdmin),
// 之下挂载各内容域资源子路由。P1 只有 preset-bots;P2–P4 在此 .route(...) 续挂。
import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession, requireAdmin } from '@pendingbot/identity';
import { isBoardAdmin } from '../lib/board-audit';
import { boardResource } from '../lib/board-resource';
import type { AppBindings } from '../types';

export const boardRoutes = new Hono<AppBindings>();

// 门禁:必须登录且 is_admin。
boardRoutes.use('*', requireSession());
boardRoutes.use('*', requireAdmin(isBoardAdmin));

// ── 预设机器人(bots 表 creator_id IS NULL 的模板行) ──────────
const presetBotCreate = z.object({
  slug: z.string().min(1),
  display_name: z.string().min(1),
  model_id: z.string().min(1),
  output_mode: z.enum(['single', 'bubble']),
  is_active: z.boolean().default(true),
  visibility: z.enum(['private', 'public_invite']).default('private'),
  config: z.record(z.string(), z.unknown()).default({}),
  // 模板行的标记 —— 强制 creator_id NULL,新建时由服务端钉死(下方 .extend 不暴露)。
});
const presetBotUpdate = presetBotCreate.partial();

boardRoutes.route(
  '/preset-bots',
  boardResource({
    table: 'bots',
    pk: 'id',
    targetKind: 'preset_bot',
    cols: 'id, slug, display_name, model_id, output_mode, is_active, visibility, config, created_at, updated_at',
    orderBy: { col: 'slug', ascending: true },
    // 只看/只改模板行(creator_id IS NULL),防止 board 误改用户克隆出的私有 bot。
    scope: <Q>(q: Q): Q => (q as { is: (c: string, v: null) => Q }).is('creator_id', null),
    createSchema: presetBotCreate,
    updateSchema: presetBotUpdate,
  }),
);
```

> 注:`creator_id` 在 create 时需为 NULL。`bots` 表 `creator_id` 列可空且无默认强制,Zod schema 不含该字段 → insert 不带它 → 入库为 NULL,正合模板语义。若日后 `bots` 给 `creator_id` 加了 NOT NULL/默认,则需在 createSchema 后显式 `creator_id: null` 注入;P1 当前 schema 下不需要。

- [ ] **Step 2: 在 index.ts 挂载**

在 `apps/edge/src/index.ts` 顶部 import 区(与其它 route import 同处)加:

```ts
import { boardRoutes } from './routes/board';
```

在 `v1.route(...)` 群里(`langfusePromptRoutes` 那行附近)加:

```ts
v1.route('/board', boardRoutes);   // 内容/预设/配置管理台(requireAdmin)
```

- [ ] **Step 3: 给测试追加 CRUD + 审计用例**

在 `apps/edge/tests/board-preset-bots.test.ts` 的 `describe('board admin gate', ...)` 之后追加:

```ts
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
    const body = await res.json();
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
    const body = await res.json();
    expect(body.error.code).toBe('invalid_body');
  });
});
```

> 说明:fake-supabase 的 `db.inserts` 记录每次 insert(`{table,row}`),故审计可断言。`.is('creator_id', null)` 在 fake 里按 JS `=== null` 过滤,模板行(creator_id:null)入选、克隆行(creator_id:'user-9')被排除。

- [ ] **Step 4: 跑测,确认全绿**

Run: `cd apps/edge && ./node_modules/.bin/vitest run tests/board-preset-bots.test.ts`
Expected: PASS —— 4 个用例(403 gate / list 过滤 / create+audit / 400)全过。

> 若 `.is()` 在 fake-supabase 未实现,fake 头注释列了支持 `.is(col, val)` —— 已支持。若 list 的 `.select().is().order().limit()` 链顺序报错,把 `scope` 的 `.is` 应用移到 `.select()` 之后、`.order()` 之前(boardResource 已是此顺序)。

- [ ] **Step 5: edge typecheck + 全量测**

Run: `bun --filter='@pendingbot/edge' run typecheck && cd apps/edge && ./node_modules/.bin/vitest run`
Expected: typecheck 通过;既有测试套 + 新套全绿。

- [ ] **Step 6: 提交**

```bash
git add apps/edge/src/routes/board.ts apps/edge/src/index.ts apps/edge/tests/board-preset-bots.test.ts
git commit -m "edge(board): /v1/board/preset-bots CRUD over bots template rows

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: 前端换 Ant Design + 预设机器人 CRUD 页

**Files:**
- Modify: `apps/admin/package.json`
- Modify: `apps/admin/src/providers/resource-map.ts`
- Modify: `apps/admin/src/App.tsx`
- Create: `apps/admin/src/pages/preset-bots.tsx`
- Delete: `apps/admin/src/pages/resources.tsx`、`apps/admin/src/pages/queues.tsx`、`apps/admin/src/pages/admin-actions.tsx`

> `apps/admin` 无单测设施(仓库现状:只有 `bun run build`)。本任务以 **build 绿 + 手动登录验证** 为验收,不写前端单测。

- [ ] **Step 1: 加 AntD 依赖**

```bash
cd apps/admin && bun add @refinedev/antd@^2 antd@^5
```

确认 `package.json` 的 `dependencies` 多了 `@refinedev/antd` 和 `antd`。

- [ ] **Step 2: 重写 resource-map.ts**

把 `apps/admin/src/providers/resource-map.ts` 整个 `RESOURCE_ROUTES` 换成只含 board 资源(删旧的 users/bots/conversations/billing/queues 等),并删掉 `ADMIN_ACTION_ENDPOINTS`(旧写动作不再用):

```ts
// 文件保留顶部 ResourceRoute 类型与 routeFor()。RESOURCE_ROUTES 改为:
export const RESOURCE_ROUTES: Record<string, ResourceRoute> = {
  // 预设机器人 —— bots 表 creator_id NULL 模板行。EXISTS。
  preset_bots: {
    basePath: 'board/preset-bots',
    exists: true,
    listKey: 'items',
    note: 'EXISTING: /v1/board/preset-bots CRUD (requireAdmin).',
  },
};

// 删除 ADMIN_ACTION_ENDPOINTS 整段及其 re-export。
```

`routeFor()` 函数保持不变(它读 RESOURCE_ROUTES)。

- [ ] **Step 3: 删旧页文件**

```bash
cd /Users/hey/Untitled/Pendingname/PendingBot/dev/.claude/worktrees/charming-goldberg-0dafe3
git rm apps/admin/src/pages/resources.tsx apps/admin/src/pages/queues.tsx apps/admin/src/pages/admin-actions.tsx
```

(`apps/admin/src/pages/login.tsx`、`common.tsx` 保留。)

- [ ] **Step 4: 写 preset-bots.tsx**

```tsx
// apps/admin/src/pages/preset-bots.tsx
import { List, useTable, EditButton, DeleteButton, CreateButton, Create, Edit, useForm } from '@refinedev/antd';
import { Table, Space, Form, Input, Switch, Select } from 'antd';

const OUTPUT_MODES = [
  { label: '单条 (single)', value: 'single' },
  { label: '气泡 (bubble)', value: 'bubble' },
];
const VISIBILITIES = [
  { label: '私有 (private)', value: 'private' },
  { label: '公开可邀请 (public_invite)', value: 'public_invite' },
];

export function PresetBotList() {
  const { tableProps } = useTable({ resource: 'preset_bots', syncWithLocation: true });
  return (
    <List headerButtons={<CreateButton />}>
      <Table {...tableProps} rowKey="id">
        <Table.Column dataIndex="slug" title="Slug" />
        <Table.Column dataIndex="display_name" title="名称" />
        <Table.Column dataIndex="model_id" title="模型" />
        <Table.Column dataIndex="output_mode" title="输出" />
        <Table.Column dataIndex="visibility" title="可见性" />
        <Table.Column dataIndex="is_active" title="启用" render={(v: boolean) => (v ? '✓' : '—')} />
        <Table.Column
          title="操作"
          render={(_, row: { id: string }) => (
            <Space>
              <EditButton hideText size="small" recordItemId={row.id} />
              <DeleteButton hideText size="small" recordItemId={row.id} />
            </Space>
          )}
        />
      </Table>
    </List>
  );
}

// system prompt 等放在 config(jsonb)。先用一个多行 JSON 文本域编辑整个 config。
function ConfigField() {
  return (
    <Form.Item
      label="Config (JSON)"
      name="config"
      getValueProps={(v) => ({ value: v ? JSON.stringify(v, null, 2) : '{}' })}
      normalize={(v) => {
        try {
          return JSON.parse(v);
        } catch {
          return v; // 让校验在提交时由 edge 兜;此处不阻断输入
        }
      }}
    >
      <Input.TextArea rows={10} style={{ fontFamily: 'monospace' }} />
    </Form.Item>
  );
}

function BotFields() {
  return (
    <>
      <Form.Item label="Slug" name="slug" rules={[{ required: true }]}>
        <Input />
      </Form.Item>
      <Form.Item label="名称" name="display_name" rules={[{ required: true }]}>
        <Input />
      </Form.Item>
      <Form.Item label="模型 ID" name="model_id" rules={[{ required: true }]}>
        <Input placeholder="如 claude-opus-4.7" />
      </Form.Item>
      <Form.Item label="输出模式" name="output_mode" rules={[{ required: true }]}>
        <Select options={OUTPUT_MODES} />
      </Form.Item>
      <Form.Item label="可见性" name="visibility" rules={[{ required: true }]}>
        <Select options={VISIBILITIES} />
      </Form.Item>
      <Form.Item label="启用" name="is_active" valuePropName="checked">
        <Switch />
      </Form.Item>
      <ConfigField />
    </>
  );
}

export function PresetBotCreate() {
  const { formProps, saveButtonProps } = useForm({ resource: 'preset_bots', action: 'create' });
  return (
    <Create saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical">
        <BotFields />
      </Form>
    </Create>
  );
}

export function PresetBotEdit() {
  const { formProps, saveButtonProps } = useForm({ resource: 'preset_bots', action: 'edit' });
  return (
    <Edit saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical">
        <BotFields />
      </Form>
    </Edit>
  );
}
```

- [ ] **Step 5: 重写 App.tsx**

把 `apps/admin/src/App.tsx` 换成 AntD 布局 + 仅 preset_bots 资源:

```tsx
import { Refine, Authenticated } from '@refinedev/core';
import { ThemedLayoutV2, RefineThemes, useNotificationProvider } from '@refinedev/antd';
import routerProvider, { NavigateToResource, CatchAllNavigate } from '@refinedev/react-router';
import { BrowserRouter, Routes, Route, Outlet } from 'react-router';
import { ConfigProvider, App as AntdApp } from 'antd';
import '@refinedev/antd/dist/reset.css';

import { dataProvider } from './providers/data-provider';
import { authProvider } from './providers/auth-provider';
import { LoginPage } from './pages/login';
import { PresetBotList, PresetBotCreate, PresetBotEdit } from './pages/preset-bots';

export default function App() {
  return (
    <BrowserRouter>
      <ConfigProvider theme={RefineThemes.Blue}>
        <AntdApp>
          <Refine
            routerProvider={routerProvider}
            dataProvider={dataProvider}
            authProvider={authProvider}
            notificationProvider={useNotificationProvider}
            options={{ disableTelemetry: true, warnWhenUnsavedChanges: true }}
            resources={[
              {
                name: 'preset_bots',
                list: '/preset-bots',
                create: '/preset-bots/create',
                edit: '/preset-bots/edit/:id',
                meta: { label: '预设机器人' },
              },
            ]}
          >
            <Routes>
              <Route path="/login" element={<LoginPage />} />
              <Route
                element={
                  <Authenticated key="protected" fallback={<CatchAllNavigate to="/login" />}>
                    <ThemedLayoutV2 Title={() => <strong>PendingBot Board</strong>}>
                      <Outlet />
                    </ThemedLayoutV2>
                  </Authenticated>
                }
              >
                <Route index element={<NavigateToResource resource="preset_bots" />} />
                <Route path="/preset-bots" element={<PresetBotList />} />
                <Route path="/preset-bots/create" element={<PresetBotCreate />} />
                <Route path="/preset-bots/edit/:id" element={<PresetBotEdit />} />
              </Route>
              <Route path="*" element={<CatchAllNavigate to="/login" />} />
            </Routes>
          </Refine>
        </AntdApp>
      </ConfigProvider>
    </BrowserRouter>
  );
}
```

> 若 `login.tsx` 引用了被删页的导出,改为不引用;登录页应是独立的(只用 authProvider)。`common.tsx` 若只被旧页引用且现无引用,可一并 `git rm`(build 报未用不影响,但干净起见删)。

- [ ] **Step 6: build 验证**

Run: `cd apps/admin && bun run build`
Expected: `tsc --noEmit` 通过 + `vite build` 产出 `dist/`,无报错。

> 常见坑:`@refinedev/antd` 的导出名随版本变 —— 若 `useNotificationProvider` 报未导出,换成 `notificationProvider`(v5 集成有两种命名);若 `ThemedLayoutV2` 报错,确认装的是 `@refinedev/antd@^2`(配 Refine v5)。以 `bun run build` 的报错为准微调 import,不要凭印象。

- [ ] **Step 7: 提交**

```bash
git add apps/admin/package.json apps/admin/bun.lock apps/admin/src/App.tsx apps/admin/src/providers/resource-map.ts apps/admin/src/pages/preset-bots.tsx
git rm 已在 Step 3/5 暂存
git commit -m "admin(board): Ant Design shell + 预设机器人 CRUD 页,退役旧运营页

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 5: Admin 引导 + 端到端手验 + 账本

**Files:**（无代码改动;运维 + 文档)

- [ ] **Step 1: 设一个 admin 用户**

在用户在场确认下,对共享 DB 执行(从主 worktree,`supabase db query --linked` 或 Studio):

```sql
UPDATE pendingbot.users SET is_admin = true WHERE id = '<你的-user-uuid>';
```

(uuid 取自你登录 board 用的那个 Supabase 账号。)

- [ ] **Step 2: 本地端到端手验**

```bash
# 终端 A:edge 本地(从 apps/edge,读 .dev.vars)
cd apps/edge && bun run dev
# 终端 B:admin 本地
cd apps/admin && bun run dev   # http://127.0.0.1:5174
```

确认 edge 的 `ALLOWED_ORIGIN` 本地允许 `127.0.0.1:5174`(`wrangler dev` 默认 env 不锁 origin;若锁了,临时放开)。
登录 board(用 is_admin 账号)→ 进「预设机器人」→ 列表应列出 6 个模板 bot → 新建一个 → 改一个名字 → 删掉新建的那个。每步成功且无 403。

- [ ] **Step 3: 确认审计落地**

```sql
SELECT action, target_kind, target_id, actor_id, created_at
FROM pendingbot.admin_audit
WHERE target_kind = 'preset_bot'
ORDER BY created_at DESC LIMIT 10;
```

应看到刚才 create/update/delete 三条,`before`/`after` 有 JSON 快照。

- [ ] **Step 4: 更新账本**

- `docs/tech-debt.md`:把 "admin console" 那条缺口标记为「已重定位为 board CMS,P1 预设机器人已落地」,并记下 P2–P4 仍待做。
- `docs/progress.md`:顶部「最近对账」日期更新为 2026-06-08,加一行 board CMS P0+P1 完成。
- 提交:

```bash
git add docs/tech-debt.md docs/progress.md
git commit -m "docs: board CMS P0+P1 落地对账,记 P2-P4 待做

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## 后续(不在本计划内,各自出短计划复用 boardResource)

- **P2 预设会话/群 + 预设来信**:`boardResource` 套 `preset_conversation_templates`(pk slug)、`preset_group_templates`(pk slug);预设来信需先建 `preset_letters` 表 + 改 `seed_example_letter()` 读表(唯一带迁移的一期)。
- **P3 tool 管理**:`boardResource` 套 `tools` 表(开关 / scopes / model_description);写后可选显式 purge `cfg:tools-registry` KV。
- **P4 KV 配置类**:逐个钉源表(模型目录/pricing/i18n/place_names),`boardResource` 套之;写后 purge 对应 `cfg:*` KV 做即时生效。

---

## Self-Review

- **Spec 覆盖**:P0 框架(门禁 Task1+3 / 审计 Task1+2 / AntD Task4 / bootstrap Task5)✓;P1 预设机器人(Task3 edge + Task4 前端)✓;命名用 board、保留 is_admin/admin_audit/requireAdmin ✓;不做项(用户/计费/审批)= 删旧页 Task4 ✓。P2–P4 明确移出本计划 ✓。
- **占位扫描**:无 TBD/TODO;每个代码步骤含完整代码;命令含预期输出。
- **类型一致**:`boardResource` 的 opts 字段(table/pk/targetKind/cols/orderBy/scope/createSchema/updateSchema)在 Task2 定义、Task3 调用一致;`recordBoardAudit` 入参(action/targetKind/targetId/before/after)Task1 定义、Task2 调用一致;前端 resource 名 `preset_bots` 在 resource-map / App.tsx / pages 三处一致;edge 路径 `board/preset-bots` 与 resource-map basePath 一致。
- **已知风险点(已在步骤内标注微调指引,非占位)**:`@refinedev/antd` 导出名随版本(Task4 Step6)、fake-supabase 链顺序(Task3 Step4)、`creator_id` 默认值假设(Task3 Step1 注)。
