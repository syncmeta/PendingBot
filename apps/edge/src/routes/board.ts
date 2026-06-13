// apps/edge/src/routes/board.ts
//
// Board 管理台根路由。挂 requireSession → requireAdmin(isBoardAdmin),
// 之下挂载各内容域资源子路由。P1 只有 preset-bots;P2–P4 在此 .route(...) 续挂。
import { Hono } from 'hono';
import { z } from 'zod';
import { requireCfAccess, requireBoardAdmin } from '../lib/cf-access';
import { boardResource } from '../lib/board-resource';
import { boardFeatureFlagsRoutes } from './board-feature-flags';
import type { AppBindings } from '../types';

export const boardRoutes = new Hono<AppBindings>();

// 门禁(BeyondCorp 模型,Cloudflare Access 是唯一身份源):
//   1. requireCfAccess —— 校验 Access JWT(team JWKS+AUD,fail-closed)+ 取 email
//   2. requireBoardAdmin —— email ∈ 服务端 BOARD_ADMIN_EMAILS 名单(独立授权权威)
// board 不再自带 Supabase 登录;身份/审计全部来自已验证的 Access 邮箱。
boardRoutes.use('*', requireCfAccess());
boardRoutes.use('*', requireBoardAdmin());

// ── 预设机器人(bots 表 creator_id IS NULL 的模板行) ──────────
const presetBotCreate = z.object({
  slug: z.string().min(1),
  display_name: z.string().min(1),
  model_id: z.string().min(1),
  output_mode: z.enum(['single', 'bubble']),
  is_active: z.boolean().default(true),
  visibility: z.enum(['private', 'public_invite']).default('private'),
  config: z.record(z.string(), z.unknown()).default({}),
  // creator_id 不在 body 里:它是模板行的标记,由服务端在 create 时通过
  // boardResource 的 fixedFields 显式钉成 null(见下方 route)。
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
    // 新建时显式把 creator_id 钉成 null,把行标记为模板 —— 不依赖「列恰好无 DEFAULT」。
    fixedFields: { creator_id: null },
    createSchema: presetBotCreate,
    updateSchema: presetBotUpdate,
  }),
);

// ── 预设会话模板(signup bootstrap 物化用) ─────────────────
// pendingbot.preset_conversation_templates(slug 主键)。整表都是模板,无 scope。
const presetConvCreate = z.object({
  slug: z.string().min(1),
  bot_slug: z.string().min(1),
  title: z.string().min(1),
  // 起始时间锚点;省略走表 DEFAULT。
  base_ts: z.string().optional(),
  // 消息数组:元素可为字符串(纯文本)或对象(富结构),由 seed 端解释。
  messages: z.array(z.unknown()).default([]),
  sort_order: z.number().int().default(100),
  enabled: z.boolean().default(true),
});
boardRoutes.route(
  '/preset-conversations',
  boardResource({
    table: 'preset_conversation_templates',
    pk: 'slug',
    targetKind: 'preset_conversation',
    cols: 'slug, bot_slug, title, base_ts, messages, sort_order, enabled, updated_at',
    orderBy: { col: 'sort_order', ascending: true },
    createSchema: presetConvCreate,
    updateSchema: presetConvCreate.partial(),
  }),
);

// ── 预设群模板 ───────────────────────────────────────────────
// pendingbot.preset_group_templates(slug 主键)。
const presetGroupCreate = z.object({
  slug: z.string().min(1),
  title: z.string().min(1),
  bot_slugs: z.array(z.string()).default([]),
  messages: z.array(z.unknown()).default([]),
  sort_order: z.number().int().default(100),
  enabled: z.boolean().default(true),
});
boardRoutes.route(
  '/preset-groups',
  boardResource({
    table: 'preset_group_templates',
    pk: 'slug',
    targetKind: 'preset_group',
    cols: 'slug, title, bot_slugs, messages, sort_order, enabled, updated_at',
    orderBy: { col: 'sort_order', ascending: true },
    createSchema: presetGroupCreate,
    updateSchema: presetGroupCreate.partial(),
  }),
);

// ── 功能开关(单例 KV blob,非表行) ──────────────────────────
boardRoutes.route('/feature-flags', boardFeatureFlagsRoutes);
