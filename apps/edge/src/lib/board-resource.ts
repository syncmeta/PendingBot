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
import type { SupabaseClient } from './supabase';
import { jsonError } from './http-error';
import { recordBoardAudit } from './board-audit';
import type { AppBindings } from '../types';

// supabase-js types `.from()` against a literal union of known table names,
// so a generic factory that takes a runtime `string` table name can't satisfy
// it. We deliberately erase the table-literal constraint here (and only here):
// the board CMS resource table is data-driven, not statically known. The
// returned builder is loosely typed — callers in this file own correctness.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type LooseBuilder = any;
function pbFrom(svc: SupabaseClient, table: string): LooseBuilder {
  return (svc.schema('pendingbot') as { from: (t: string) => LooseBuilder }).from(table);
}

// LIST pagination bounds. Default page is generous (board volumes are small)
// but bounded so a bad ?limit can't ask for the whole table; the response
// carries `total` so the client knows when there's more.
const DEFAULT_LIST_LIMIT = 100;
const MAX_LIST_LIMIT = 500;

function clampInt(raw: string | undefined, fallback: number, min: number, max: number): number {
  const n = Number.parseInt(raw ?? '', 10);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

// Postgres error → semantic HTTP status. Supabase surfaces the SQLSTATE on
// `error.code`; map constraint violations to 409 (with the offending detail)
// instead of flattening every DB error to an opaque 500. `error.details`
// names the column/value for unique/fk violations — safe to echo to an
// authenticated admin.
type PgError = { code?: string; message?: string; details?: string } | null | undefined;
function dbError(c: Parameters<typeof jsonError>[0], error: PgError) {
  const code = error?.code;
  if (code === '23505') {
    // unique_violation
    return jsonError(c, 409, 'conflict', {
      message: '已存在冲突记录(唯一约束)',
      detail: error?.details ?? error?.message,
    });
  }
  if (code === '23503') {
    // foreign_key_violation
    return jsonError(c, 409, 'conflict', {
      message: '关联记录不存在或被引用(外键约束)',
      detail: error?.details ?? error?.message,
    });
  }
  return jsonError(c, 500, 'database_error', { detail: error?.message });
}

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
  // create 时强制钉进 insert payload 的固定列(覆盖 body)。用于把新行显式打成
  // scope 能看见的形状 —— 如 preset-bot 传 { creator_id: null } 显式标记模板行,
  // 而不是依赖「列恰好无 DEFAULT」这种隐式机制。
  fixedFields?: Record<string, unknown>;
  // create body 校验(全字段)。省略 = 不挂 POST 路由(只读+改的资源,
  // 如 tools:每行映射代码 handler,board 不该凭空建出无 handler 的死工具)。
  createSchema?: z.ZodTypeAny;
  // update body 校验(通常 .partial())
  updateSchema: z.ZodTypeAny;
  // true = 不挂 DELETE 路由(同上:tools 之类不该被 board 删)。
  disableDelete?: boolean;
  // 写入成功后(create/update/delete)调用,用于让相关 KV 缓存失效——否则 board
  // 改动要等缓存 TTL 过期才生效。第二参是被写行的主键值(create 取返回行、
  // update/delete 取路径 id)。失败只 warn,不影响写本身。
  onWrite?: (env: AppBindings['Bindings'], id: string | null) => Promise<void>;
}

async function runOnWrite(
  opts: BoardResourceOpts,
  env: AppBindings['Bindings'],
  id: string | null,
): Promise<void> {
  if (!opts.onWrite) return;
  try {
    await opts.onWrite(env, id);
  } catch (err) {
    console.warn(`[board-resource] onWrite for ${opts.table} failed`, err);
  }
}

export function boardResource(opts: BoardResourceOpts): Hono<AppBindings> {
  const app = new Hono<AppBindings>();
  const scope = opts.scope ?? (<Q>(q: Q) => q);

  // ── LIST ────────────────────────────────────────────────
  // Paginated: ?limit (≤MAX) & ?offset. Returns total (exact count) + has_more
  // so the client never silently loses the tail of a large table.
  app.get('/', async (c) => {
    const svc = serviceClient(c.env);
    const limit = clampInt(c.req.query('limit'), DEFAULT_LIST_LIMIT, 1, MAX_LIST_LIMIT);
    const offset = clampInt(c.req.query('offset'), 0, 0, Number.MAX_SAFE_INTEGER);
    let q = pbFrom(svc, opts.table).select(opts.cols, { count: 'exact' });
    q = scope(q);
    const { data, error, count } = await q
      .order(opts.orderBy.col, { ascending: opts.orderBy.ascending })
      .range(offset, offset + limit - 1);
    if (error) return dbError(c, error);
    const total = typeof count === 'number' ? count : (data?.length ?? 0);
    return c.json({
      items: data ?? [],
      total,
      limit,
      offset,
      has_more: offset + (data?.length ?? 0) < total,
    });
  });

  // ── GET ONE ─────────────────────────────────────────────
  app.get('/:id', async (c) => {
    const svc = serviceClient(c.env);
    let q = pbFrom(svc, opts.table).select(opts.cols).eq(opts.pk, c.req.param('id'));
    q = scope(q);
    const { data, error } = await q.maybeSingle();
    if (error) return dbError(c, error);
    if (!data) return jsonError(c, 404, 'not_found');
    return c.json({ data });
  });

  // ── CREATE ──────────────────────────────────────────────
  // Only mounted when a createSchema is provided.
  const createSchema = opts.createSchema;
  if (createSchema)
  app.post('/', async (c) => {
    const body = await c.req.json().catch(() => null);
    const parsed = createSchema.safeParse(body);
    if (!parsed.success) {
      return jsonError(c, 400, 'invalid_body', { detail: parsed.error.flatten() });
    }
    const svc = serviceClient(c.env);
    // 固定列后 merge,确保 body 无法覆盖服务端钉死的字段(如 creator_id)。
    const insertPayload = { ...(parsed.data as Record<string, unknown>), ...opts.fixedFields };
    const { data, error } = await pbFrom(svc, opts.table)
      .insert(insertPayload as never)
      .select(opts.cols)
      .maybeSingle();
    if (error) return dbError(c, error);
    await recordBoardAudit(c, {
      action: 'create',
      targetKind: opts.targetKind,
      targetId: (data as Record<string, unknown> | null)?.[opts.pk] as string ?? null,
      before: null,
      after: data,
    });
    await runOnWrite(opts, c.env, (data as Record<string, unknown> | null)?.[opts.pk] as string ?? null);
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
    let beforeQ = pbFrom(svc, opts.table).select(opts.cols).eq(opts.pk, id);
    beforeQ = scope(beforeQ);
    const { data: before } = await beforeQ.maybeSingle();
    if (!before) return jsonError(c, 404, 'not_found');

    const { data: after, error } = await pbFrom(svc, opts.table)
      .update(parsed.data as never)
      .eq(opts.pk, id)
      .select(opts.cols)
      .maybeSingle();
    if (error) return dbError(c, error);
    await recordBoardAudit(c, {
      action: 'update',
      targetKind: opts.targetKind,
      targetId: id,
      before,
      after,
    });
    await runOnWrite(opts, c.env, id);
    return c.json({ data: after });
  });

  // ── DELETE ──────────────────────────────────────────────
  // Skipped when disableDelete (e.g. tools — rows map to code handlers).
  if (!opts.disableDelete)
  app.delete('/:id', async (c) => {
    const id = c.req.param('id');
    const svc = serviceClient(c.env);
    let beforeQ = pbFrom(svc, opts.table).select(opts.cols).eq(opts.pk, id);
    beforeQ = scope(beforeQ);
    const { data: before } = await beforeQ.maybeSingle();
    if (!before) return jsonError(c, 404, 'not_found');

    const { error } = await pbFrom(svc, opts.table).delete().eq(opts.pk, id);
    if (error) return dbError(c, error);
    await recordBoardAudit(c, {
      action: 'delete',
      targetKind: opts.targetKind,
      targetId: id,
      before,
      after: null,
    });
    await runOnWrite(opts, c.env, id);
    return c.json({});
  });

  return app;
}
