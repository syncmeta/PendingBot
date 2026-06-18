#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const outPath = path.join(root, 'docs/architecture-file-map.md');

function repoFiles() {
  try {
    return execFileSync('rg', ['--files'], { cwd: root, encoding: 'utf8' })
      .split('\n')
      .filter(Boolean);
  } catch {
    return execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8' })
      .split('\n')
      .filter(Boolean);
  }
}

function readText(file, maxBytes = 20_000) {
  const abs = path.join(root, file);
  if (!existsSync(abs)) return '';
  try {
    return readFileSync(abs, 'utf8').slice(0, maxBytes);
  } catch {
    return '';
  }
}

function firstHeading(file) {
  const text = readText(file);
  const line = text.split('\n').find((l) => /^#\s+/.test(l.trim()));
  return line?.replace(/^#\s+/, '').trim() ?? null;
}

function firstComment(file) {
  const text = readText(file, 8_000);
  const lines = text.split('\n').slice(0, 40);
  const comments = [];
  for (const raw of lines) {
    const line = raw.trim();
    if (!line) {
      if (comments.length > 0) break;
      continue;
    }
    const cleaned = line
      .replace(/^\/\/\/?\s?/, '')
      .replace(/^\/\*\*?\s?/, '')
      .replace(/^\*\s?/, '')
      .replace(/\*\/$/, '')
      .trim();
    if (cleaned && cleaned !== 'MARK:' && (line.startsWith('//') || line.startsWith('/*') || line.startsWith('*'))) {
      comments.push(cleaned);
      continue;
    }
    if (comments.length > 0) break;
  }
  return comments.join(' ').slice(0, 180) || null;
}

function slugWords(file) {
  const base = path.basename(file).replace(/\.[^.]+$/, '');
  return base
    .replace(/^\d+_?/, '')
    .replace(/^\d{14}_?/, '')
    .replace(/[-_]/g, ' ')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .trim();
}

const specific = new Map([
  ['README.md', '仓库总览：产品定位、monorepo 布局、运行方式。'],
  ['CLAUDE.md', '仓库工作流约定：分支、worktree、合并、测试、部署、账本。'],
  ['package.json', 'Bun workspace 根 manifest：全仓脚本、依赖 override。'],
  ['bun.lock', 'Bun 依赖锁文件。'],
  ['lefthook.yml', 'Git hook 配置：schema regen、edge typecheck。'],
  ['apps/edge/src/index.ts', 'Cloudflare Worker 总入口：Hono 路由、DO 导出、cron、queue、Sentry。'],
  ['apps/edge/wrangler.jsonc', 'Cloudflare 部署与资源绑定：routes、DO、R2、KV、Queue、Container、secrets 说明。'],
  ['apps/edge/src/types.ts', 'Worker Env / Hono vars 类型定义，对齐 wrangler 绑定。'],
  ['apps/pendingbot/Sources/PendingBotApp.swift', 'PendingBot SwiftUI app 入口。'],
  ['apps/pendingbot/Sources/Networking/APIClient.swift', 'PendingBot 调 Edge REST/SSE 的通用客户端。'],
  ['apps/pendingbot/Sources/Networking/SupabaseStack.swift', 'PendingBot Supabase Auth/PostgREST 客户端单例。'],
  ['apps/pendingbot/Sources/Networking/RealtimeSocket.swift', 'PendingBot 连接 RealtimeHubDO 的 WebSocket 客户端。'],
  ['apps/pendingbot/Sources/Storage/LocalDatabase.swift', 'PendingBot 本地 GRDB/SQLCipher 缓存。'],
  ['apps/pendingcrew/Sources/PendingCrewApp.swift', 'PendingCrew SwiftUI app 入口。'],
  ['apps/pendingcrew/Sources/Stores/AppModel.swift', 'PendingCrew 顶层状态、auth/device grant、backend 选择。'],
  ['apps/pendingcrew/Sources/Services/PendingCrewAPI.swift', 'PendingCrew 调 Edge 的 REST/WS API 客户端。'],
  ['apps/pendingcrew/Sources/Services/PendingCrewBackend.swift', 'PendingCrew EdgeBackend / LocalBackend 抽象边界。'],
  ['apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift', 'macOS 本地 coding agent session runner。'],
  ['apps/pendingcrew/Sources/Mac/LocalRunner/SessionProxyClient.swift', 'PendingCrew 连接 SessionProxyDO 的 runner/viewer WebSocket 客户端。'],
  ['packages/identity/src/index.ts', '共享鉴权包出口。'],
  ['packages/identity/src/middleware.ts', 'Supabase JWT session/admin Hono middleware。'],
  ['packages/identity/src/jwt.ts', 'Supabase JWT 校验实现。'],
  ['apps/admin/src/main.tsx', 'Admin SPA React/Vite 入口。'],
  ['apps/admin/src/providers/data-provider.ts', 'Admin Refine data provider，只访问 Edge API。'],
  ['apps/admin/src/providers/resource-map.ts', 'Admin resource 到 Edge route 的映射表。'],
]);

function inferRole(file) {
  if (specific.has(file)) return specific.get(file);

  if (file.endsWith('.md')) {
    return `文档：${firstHeading(file) ?? slugWords(file)}。`;
  }
  if (file.startsWith('supabase/seeds/') && file.endsWith('.sql')) {
    return `Supabase seed：${slugWords(file)}。`;
  }
  if (file.endsWith('.sql')) {
    return `Supabase migration：${slugWords(file)}。`;
  }
  if (file.endsWith('.test.ts')) {
    return `Vitest 测试：覆盖 ${slugWords(file).replace(/\btest\b/i, '').trim()}。`;
  }
  if (file.endsWith('Tests.swift') || file.includes('/Tests/')) {
    return `Swift 测试：覆盖 ${slugWords(file).replace(/\btests?\b/i, '').trim()}。`;
  }
  if (file.startsWith('apps/edge/src/routes/')) {
    return `Edge route：${slugWords(file)} 相关 HTTP/SSE/WS API。`;
  }
  if (file.startsWith('apps/edge/src/durable-objects/')) {
    return `Cloudflare Durable Object：${slugWords(file)} 状态/实时/控制逻辑。`;
  }
  if (file.startsWith('apps/edge/src/llm/')) {
    return `LLM 层：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/edge/src/billing/')) {
    return `计费层：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/edge/src/lib/bot-reply/tools/')) {
    return `Bot 工具实现：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/edge/src/lib/')) {
    return `Edge 业务库：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/edge/src/cron/')) {
    return `Edge cron task：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/edge/src/db/')) {
    return `数据库类型/访问辅助：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/edge/src/mcp/')) {
    return `MCP 集成：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/edge/tests/')) {
    return `Edge 集成测试/helper：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingbot/Sources/Networking/')) {
    return `PendingBot 网络层：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingbot/Sources/Storage/')) {
    return `PendingBot 本地存储/缓存：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingbot/Sources/Features/')) {
    return `PendingBot 功能界面/逻辑：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingbot/Sources/Components/')) {
    return `PendingBot 共享 UI 组件：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingbot/Sources/Models/')) {
    return `PendingBot 数据模型：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingbot/Sources/Mac/')) {
    return `PendingBot macOS 端界面/逻辑：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingcrew/Sources/Mac/LocalRunner/')) {
    return `PendingCrew macOS 本地 runner：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingcrew/Sources/Mac/Views/')) {
    return `PendingCrew macOS UI：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingcrew/Sources/Mac/Services/')) {
    return `PendingCrew macOS service：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingcrew/Sources/Services/')) {
    return `PendingCrew 服务/API 层：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingcrew/Sources/Stores/')) {
    return `PendingCrew 状态/本地 store：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingcrew/Sources/Views/')) {
    return `PendingCrew 跨平台 UI：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingcrew/Sources/Auth/')) {
    return `PendingCrew 登录/auth UI 或逻辑：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingcrew/Sources/Mcp/')) {
    return `PendingCrew MCP/helper：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingcrew/Sources/Chat/')) {
    return `PendingCrew chat UI adapter/vendor shim：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/pendingcrew/Sources/Models/')) {
    return `PendingCrew 数据模型：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/admin/src/pages/')) {
    return `Admin 页面：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/admin/src/components/')) {
    return `Admin UI 组件：${slugWords(file)}。`;
  }
  if (file.startsWith('apps/admin/src/providers/')) {
    return `Admin 数据/路由 provider：${slugWords(file)}。`;
  }
  if (file.startsWith('packages/identity/src/')) {
    return `共享身份鉴权模块：${slugWords(file)}。`;
  }
  if (file.startsWith('infra/grafana/')) {
    return `Grafana dashboard/provisioning：${slugWords(file)}。`;
  }
  if (file.startsWith('scripts/')) {
    return `工程脚本：${slugWords(file)}。`;
  }
  if (file.includes('.xcodeproj/')) {
    return `Xcode project 生成/工程元数据：${slugWords(file)}。`;
  }
  if (file.includes('.xcassets/') || /\.(png|svg|json)$/.test(file) && file.includes('/Resources/')) {
    return `App 资源/asset catalog：${slugWords(file)}。`;
  }
  if (file.endsWith('.plist')) return `Apple plist 配置：${slugWords(file)}。`;
  if (file.endsWith('.entitlements')) return `Apple entitlement 配置：${slugWords(file)}。`;
  if (file.endsWith('.json') || file.endsWith('.jsonc')) return `JSON 配置/数据：${slugWords(file)}。`;
  if (file.endsWith('.ts') || file.endsWith('.tsx')) return `TypeScript 源码：${slugWords(file)}。`;
  if (file.endsWith('.swift')) return firstComment(file) ?? `Swift 源码：${slugWords(file)}。`;
  if (file.endsWith('.sh')) return `Shell 脚本：${slugWords(file)}。`;
  return `项目文件：${slugWords(file)}。`;
}

function domainOf(file) {
  if (file.startsWith('apps/edge/')) return 'apps/edge - Cloudflare 后端';
  if (file.startsWith('apps/pendingbot/')) return 'apps/pendingbot - PendingBot 客户端';
  if (file.startsWith('apps/pendingcrew/')) return 'apps/pendingcrew - PendingCrew 客户端';
  if (file.startsWith('apps/admin/')) return 'apps/admin - 后台管理';
  if (file.startsWith('apps/voice-container/')) return 'apps/voice-container - 群语音容器';
  if (file.startsWith('packages/identity/')) return 'packages/identity - 共享鉴权';
  if (file.startsWith('supabase/')) return 'supabase - 数据库真源';
  if (file.startsWith('infra/')) return 'infra - 观测/看板';
  if (file.startsWith('scripts/')) return 'scripts - 工程脚本';
  if (file.startsWith('docs/')) return 'docs - 设计与账本';
  return 'root - 仓库配置';
}

function escapeMd(value) {
  return value.replace(/\|/g, '\\|').replace(/\n/g, ' ');
}

const files = repoFiles()
  .filter((file) => file !== 'docs/architecture-file-map.md')
  .sort((a, b) => a.localeCompare(b));

const byDomain = new Map();
for (const file of files) {
  const domain = domainOf(file);
  if (!byDomain.has(domain)) byDomain.set(domain, []);
  byDomain.get(domain).push(file);
}

const generatedAt = new Date().toISOString();

let md = `# Architecture and File Map\n\n`;
md += `Generated by \`node scripts/generate-architecture-map.mjs\` at \`${generatedAt}\`.\n\n`;
md += `This document is a searchable map of the repository. The file-level roles are inferred from path conventions, known entry points, and leading comments, so treat it as a living index: correct important rows by improving path-specific rules in the generator.\n\n`;
md += `## System Shape\n\n`;
md += `\`\`\`mermaid\n`;
md += `flowchart TB\n`;
md += `  PB["apps/pendingbot\\nSwiftUI IM client"] --> Edge["apps/edge\\nCloudflare Worker / Hono"]\n`;
md += `  PC["apps/pendingcrew\\nSwiftUI crew workbench"] --> Edge\n`;
md += `  Admin["apps/admin\\n/board SPA"] --> Edge\n`;
md += `  Edge --> Supa["supabase\\nPostgres + Auth + RLS + RPC"]\n`;
md += `  Supa --> Notify["pg_net webhook\\n/v1/realtime-internal/notify"] --> Edge\n`;
md += `  Edge --> DO["Durable Objects\\nRealtimeHub / Projection / Wallet / SessionProxy / Voice"]\n`;
md += `  Edge --> R2["R2 uploads"]\n`;
md += `  Edge --> KV["KV memory + prompts"]\n`;
md += `  Edge --> AI["Cloudflare AI Gateway\\nLLM providers"]\n`;
md += `  Edge --> Billing["Polar + RevenueCat"]\n`;
md += `  PC --> Local["macOS local runner\\nClaude PTY / Codex app-server / MCP"]\n`;
md += `  Local --> Edge\n`;
md += `\`\`\`\n\n`;

md += `## How To Read The Repo\n\n`;
md += `- Start at \`apps/edge/src/index.ts\` for backend route mounting and runtime entry points.\n`;
md += `- Start at \`apps/pendingbot/Sources/PendingBotApp.swift\` for the main IM app.\n`;
md += `- Start at \`apps/pendingcrew/Sources/PendingCrewApp.swift\` and \`apps/pendingcrew/Sources/Stores/AppModel.swift\` for the crew app.\n`;
md += `- Treat \`supabase/migrations\` as the data truth ledger: schema, RLS, RPC, triggers.\n`;
md += `- Treat \`docs/progress.md\`, \`docs/decisions.md\`, and \`docs/tech-debt.md\` as the project state ledgers.\n\n`;

md += `## Directory Responsibilities\n\n`;
md += `| Directory | Responsibility |\n|---|---|\n`;
md += `| \`apps/edge\` | Backend hot path: REST/SSE/WS API, Cloudflare Durable Objects, queues, billing, LLM routing, realtime fan-out. |\n`;
md += `| \`apps/pendingbot\` | PendingBot native client: chat, friends, voice, local cache, Supabase auth, edge API client. |\n`;
md += `| \`apps/pendingcrew\` | PendingCrew native client: local-first crew workbench, device grant login, local agent runner, session proxy. |\n`;
md += `| \`apps/admin\` | Internal board/admin SPA, backed by Edge APIs. |\n`;
md += `| \`apps/voice-container\` | Containerized media engine used by group voice. |\n`;
md += `| \`packages/identity\` | Shared Supabase JWT verification and Hono middleware. |\n`;
md += `| \`supabase\` | Postgres migrations, RLS, RPC, DB webhooks, source-of-truth schema. |\n`;
md += `| \`infra\` | Grafana dashboards and observability support files. |\n`;
md += `| \`scripts\` | Repo automation, checks, generation utilities. |\n`;
md += `| \`docs\` | Specs, implementation plans, decisions, progress, deploy notes, tech debt. |\n\n`;

md += `## File Responsibilities\n\n`;
for (const [domain, domainFiles] of byDomain) {
  md += `### ${domain}\n\n`;
  md += `| File | What it does |\n|---|---|\n`;
  for (const file of domainFiles) {
    md += `| \`${escapeMd(file)}\` | ${escapeMd(inferRole(file))} |\n`;
  }
  md += `\n`;
}

writeFileSync(outPath, md, 'utf8');
console.log(`Wrote ${path.relative(root, outPath)} with ${files.length} indexed files.`);
