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
