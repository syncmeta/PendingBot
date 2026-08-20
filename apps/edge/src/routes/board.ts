// apps/edge/src/routes/board.ts
//
// Board 管理台根路由。挂 requireCfAccess → requireBoardAdmin(Cloudflare Access
// 唯一身份源),之下挂载各内容域资源子路由。P1 只有 preset-bots;P2–P4 在此 .route(...) 续挂。
import { Hono } from 'hono';
import { z } from 'zod';
import { requireCfAccess, requireBoardAdmin } from '../lib/cf-access';
import { boardResource } from '../lib/board-resource';
import { bustModelPresetCaches } from '../lib/model-presets';
import { boardFeatureFlagsRoutes } from './board-feature-flags';
import { boardModelRolesRoutes } from './board-model-roles';
import { boardBillingRoutes } from './board-billing';
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

// ── 预设来信 ─────────────────────────────────────────────────
// pendingbot.preset_letters(slug 主键)。signup 的 seed_example_letter() 早已
// 从此表读 slug='readme' 那封来信物化进新用户 self 会话(无需改函数,这里只补
// board 管理面)。body_md 是 markdown 长文。
const presetLetterCreate = z.object({
  slug: z.string().min(1),
  title: z.string().min(1),
  summary: z.string().min(1),
  body_md: z.string().min(1),
  version: z.number().int().default(1),
});
boardRoutes.route(
  '/preset-letters',
  boardResource({
    table: 'preset_letters',
    pk: 'slug',
    targetKind: 'preset_letter',
    cols: 'slug, title, summary, body_md, version, updated_at',
    orderBy: { col: 'slug', ascending: true },
    createSchema: presetLetterCreate,
    updateSchema: presetLetterCreate.partial(),
  }),
);

// ── 模型预设(新建机器人用) ───────────────────────────────────
// pendingbot.model_presets(slug 主键)。board 管"规则"(resolver_kind + params),
// 内容由 OpenRouter 目录动态解析(见 lib/model-presets.ts)。params 是 jsonb:
// 如 { "authors":["openai","anthropic"], "flagship":"most_expensive" }。
const modelPresetCreate = z.object({
  slug: z.string().min(1),
  title: z.string().min(1),
  description: z.string().default(''),
  resolver_kind: z.enum([
    'top_flagship', 'chinese_flagship', 'latest_per_vendor', 'fastest', 'most_popular', 'manual',
  ]),
  params: z.record(z.string(), z.unknown()).default({}),
  default_selected: z.boolean().default(false),
  enabled: z.boolean().default(true),
  sort_order: z.number().int().default(100),
});
boardRoutes.route(
  '/model-presets',
  boardResource({
    table: 'model_presets',
    pk: 'slug',
    targetKind: 'model_preset',
    cols: 'slug, title, description, resolver_kind, params, default_selected, enabled, sort_order, updated_at',
    orderBy: { col: 'sort_order', ascending: true },
    createSchema: modelPresetCreate,
    updateSchema: modelPresetCreate.partial(),
    // 写后立即失效预设缓存,board 改动不等 TTL(列表 1h / 单预设 6h)。
    onWrite: (env, slug) => bustModelPresetCaches(env, slug ?? undefined),
  }),
);

// ── tool 管理(P3) ───────────────────────────────────────────
// pendingbot.tools(id 主键)。**只读+改,不建不删**:每行映射一个代码 handler
// (key→实现),board 凭空建行会造出无 handler 的死工具。可改的是运行时配置:
// enabled(kill-switch,≤60s 经 cfg:tools-registry KV TTL 生效)、scopes
// (chat/envelope)、model_description(模型实际看到的描述)、人读 description/notes、
// mcp_server_id 绑定。key/kind 是身份,不可改。
const presetToolUpdate = z.object({
  enabled: z.boolean().optional(),
  scopes: z.array(z.enum(['chat', 'envelope'])).optional(),
  model_description: z.string().nullable().optional(),
  description: z.string().nullable().optional(),
  notes: z.string().nullable().optional(),
  mcp_server_id: z.string().uuid().nullable().optional(),
});
boardRoutes.route(
  '/tools',
  boardResource({
    table: 'tools',
    pk: 'id',
    targetKind: 'tool',
    cols: 'id, key, kind, enabled, scopes, model_description, description, notes, mcp_server_id, updated_at',
    orderBy: { col: 'key', ascending: true },
    // 不传 createSchema → 不挂 POST;disableDelete → 不挂 DELETE。只 list/get/patch。
    updateSchema: presetToolUpdate,
    disableDelete: true,
  }),
);

// ── MCP server 注册(P4) ─────────────────────────────────────
// pendingbot.mcp_servers(id 主键)。纯配置(url + auth),无代码 handler,可全 CRUD。
// 改完 ≤60s 经 cfg:mcp-servers KV TTL 生效。**secret_ref 是 env var 的名字指针**
// (运行时 env[secret_ref] 解析),不是密钥本身——板里编辑名字安全,密钥另用
// `wrangler secret put` 配。transport=http(sse 未实现)/auth_kind=none|header。
const mcpServerCreate = z.object({
  name: z.string().min(1),
  url: z.string().url(),
  transport: z.enum(['http', 'sse']).default('http'),
  auth_kind: z.enum(['none', 'header']).default('none'),
  auth_header_name: z.string().nullable().optional(),
  secret_ref: z.string().nullable().optional(),
  enabled: z.boolean().default(true),
  notes: z.string().nullable().optional(),
});
boardRoutes.route(
  '/mcp-servers',
  boardResource({
    table: 'mcp_servers',
    pk: 'id',
    targetKind: 'mcp_server',
    cols: 'id, name, url, transport, auth_kind, auth_header_name, secret_ref, enabled, notes, last_health_check_at, last_health_error, updated_at',
    orderBy: { col: 'name', ascending: true },
    createSchema: mcpServerCreate,
    updateSchema: mcpServerCreate.partial(),
  }),
);

// ── 功能开关(单例 KV blob,非表行) ──────────────────────────
boardRoutes.route('/feature-flags', boardFeatureFlagsRoutes);
// ── 系统模型角色(单例 KV blob:title/group-router/vision/voice 等的默认 slug) ──
boardRoutes.route('/model-roles', boardModelRolesRoutes);
// ── 计费管理(套餐映射 KV + 钱包查询 + grant/claw-back) ──
boardRoutes.route('/billing', boardBillingRoutes);
