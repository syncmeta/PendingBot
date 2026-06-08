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
    let q = pbFrom(svc, opts.table).select(opts.cols);
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
    let q = pbFrom(svc, opts.table).select(opts.cols).eq(opts.pk, c.req.param('id'));
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
    const { data, error } = await pbFrom(svc, opts.table)
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
    let beforeQ = pbFrom(svc, opts.table).select(opts.cols).eq(opts.pk, id);
    beforeQ = scope(beforeQ);
    const { data: before } = await beforeQ.maybeSingle();
    if (!before) return jsonError(c, 404, 'not_found');

    const { data: after, error } = await pbFrom(svc, opts.table)
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
    let beforeQ = pbFrom(svc, opts.table).select(opts.cols).eq(opts.pk, id);
    beforeQ = scope(beforeQ);
    const { data: before } = await beforeQ.maybeSingle();
    if (!before) return jsonError(c, 404, 'not_found');

    const { error } = await pbFrom(svc, opts.table).delete().eq(opts.pk, id);
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
