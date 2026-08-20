// ─────────────────────────────────────────────────────────────────────────
// Resource → edge endpoint map.
//
// HARD RULE (board CMS spec): all reads AND writes go through the edge API,
// never direct-to-Postgres. So every Refine resource maps to an edge route
// here. The dataProvider (./data-provider.ts) consults this table to build
// the request for each (resource, action) pair.
//
// EXISTING vs PENDING — this is the load-bearing honesty of this file:
//
//   `exists: true`   → the edge route is mounted TODAY (verified against
//                      apps/edge/src/index.ts + the route file). Wired live.
//
//   `exists: false`  → the edge route does NOT exist yet. Logged in
//                      docs/tech-debt.md (🟡). We do NOT fabricate a stub.
//
// As of the board CMS P1 cut, the only mounted board resource is the preset
// bots CRUD surface (creator_id-NULL template rows in pendingbot.bots),
// gated by Cloudflare Access (requireCfAccess + requireBoardAdmin). P2–P4
// resources (preset conversations/groups, tools, KV config) come in follow-up
// cuts and get added here then.
// ─────────────────────────────────────────────────────────────────────────

export type ResourceRoute = {
  // Base path under the edge origin, no leading /v1 (the dataProvider adds it).
  // e.g. 'board/preset-bots' → GET <EDGE>/v1/board/preset-bots
  basePath: string;
  // Whether the edge route is mounted today. false = pending (will 404).
  exists: boolean;
  // Which list-shaped response key the edge returns the array under, if it is
  // NOT the standard `{ data, total }`. The dataProvider normalises these.
  // The board list routes return `{ items: [...] }`.
  listKey?: string;
  // Human note surfaced in code + tech-debt.
  note?: string;
};

export const RESOURCE_ROUTES: Record<string, ResourceRoute> = {
  // 预设机器人 —— bots 表 creator_id NULL 模板行。EXISTS。
  preset_bots: {
    basePath: 'board/preset-bots',
    exists: true,
    listKey: 'items',
    note: 'EXISTING: /v1/board/preset-bots CRUD (Cloudflare Access gated).',
  },
  // 预设会话模板 —— preset_conversation_templates(slug 主键)。EXISTS (P2)。
  preset_conversations: {
    basePath: 'board/preset-conversations',
    exists: true,
    listKey: 'items',
    note: 'EXISTING: /v1/board/preset-conversations CRUD (P2).',
  },
  // 预设群模板 —— preset_group_templates(slug 主键)。EXISTS (P2)。
  preset_groups: {
    basePath: 'board/preset-groups',
    exists: true,
    listKey: 'items',
    note: 'EXISTING: /v1/board/preset-groups CRUD (P2).',
  },
  // 预设来信 —— preset_letters(slug 主键,signup 读 slug='readme')。EXISTS (P2)。
  preset_letters: {
    basePath: 'board/preset-letters',
    exists: true,
    listKey: 'items',
    note: 'EXISTING: /v1/board/preset-letters CRUD (P2).',
  },
  // tool 管理 —— tools(id 主键)。EXISTS (P3),只读+改(不建不删)。
  tools: {
    basePath: 'board/tools',
    exists: true,
    listKey: 'items',
    note: 'EXISTING: /v1/board/tools list/get/patch (P3, no create/delete).',
  },
  // MCP server 注册 —— mcp_servers(id 主键)。EXISTS (P4),全 CRUD(纯配置)。
  mcp_servers: {
    basePath: 'board/mcp-servers',
    exists: true,
    listKey: 'items',
    note: 'EXISTING: /v1/board/mcp-servers CRUD (P4).',
  },
  // 模型预设(新建机器人用)—— model_presets(slug 主键)。EXISTS。
  model_presets: {
    basePath: 'board/model-presets',
    exists: true,
    listKey: 'items',
    note: 'EXISTING: /v1/board/model-presets CRUD.',
  },
};

export function routeFor(resource: string): ResourceRoute {
  const r = RESOURCE_ROUTES[resource];
  if (!r) {
    throw new Error(`[admin] no edge route mapped for resource "${resource}"`);
  }
  return r;
}
