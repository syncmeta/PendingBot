# 验收清单 — 早上醒来逐条复制粘贴

Branch: `claude/busy-dhawan-5f61ed` (worktree: `busy-dhawan-5f61ed`)

```
cd /Users/hey/Documents/Pendingname/PendingBot/dev/.claude/worktrees/busy-dhawan-5f61ed
```

## 1. Git 概览

```bash
git log --oneline | head -20
git status
git diff main...HEAD --stat
```

应该看到一系列 `feat(edge)` / `feat(packages)` / `chore(scaffold)` 等 commits，工作目录 clean。

## 2. 仓库结构

```bash
ls apps/ packages/ supabase/
```

期望：
- `apps/api/` — 老仓（B9 退役前不动）
- `apps/edge/` — **新建**（CF Workers + Hono）
- `apps/ios/` — iOS（B9 改造，今晚不动业务逻辑）
- `apps/web/` — web 骨架（W0 阶段才动）
- `packages/core/` — **新建**（pure logic / Tools registry）
- `packages/identity/` — **新建**（Supabase JWT 校验、middleware）
- `packages/shared-types/` — 已有
- `supabase/` — **新建**（migrations、config）

## 3. 类型检查（B0 完成度核心信号）

```bash
bun install
bun run typecheck
```

期望：所有 workspace `typecheck` 0 错。

如有错：见 `BLOCKED.md`。

## 4. apps/edge 单元测试

```bash
bun --filter @pendingbot/edge test
```

期望：vitest 跑通（B0 阶段没多少测试，但 framework 可跑）。

## 5. wrangler dev 跑通

```bash
cd apps/edge
bun run dev
```

另开终端：

```bash
curl http://localhost:8787/health
# 期望: {"ok":true,"service":"pendingbot-edge","environment":"dev","time":"..."}

curl http://localhost:8787/v1/health
# 同上
```

## 6. Supabase 本地（需要装 CLI）

```bash
brew install supabase/tap/supabase    # 如未装
cd /Users/hey/Documents/Pendingname/PendingBot/dev/.claude/worktrees/busy-dhawan-5f61ed
supabase start
```

首次启动 30-60s，拉 docker images。

```bash
supabase db reset                      # 应用 migrations 0001_init.sql
```

期望：无错误，所有 `pendingbot.*` 表创建成功。

打开 `http://localhost:54323`（Supabase Studio）→ Table Editor → schema `pendingbot` → 应看到：
- users, bots, conversations, conversation_participants, messages
- attachments, user_unread_counts, audit_log, model_pricing
- skills, skill_subscriptions, tools, bot_reflections
- surf_runs, review_runs, invites
- user_settings, user_quota, device_tokens, ai_picks, portraits, discuss_settings

## 7. RLS 速验

在 Supabase Studio SQL editor 跑：

```sql
-- 模拟匿名 user 看不到任何 messages（RLS 阻挡）
set local role anon;
select count(*) from pendingbot.messages;
-- 应返回 0（即便有数据）

reset role;
```

## 8. iOS（不动逻辑，仅看编译）

如果手边有 Xcode（命令行工具够）：

```bash
cd apps/ios
xcodebuild -scheme PendingBot -destination 'generic/platform=iOS' clean build 2>&1 | tail -20
```

期望：B0 阶段 iOS 没动业务代码，编译通过。

iOS 真正改造在阶段 4（如果今晚没跑到，明天做）。

## 9. 你睡前给我的 secrets（如已就位）

`apps/edge/.dev.vars` 应包含：

```
SUPABASE_URL=
SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=
SUPABASE_JWT_SECRET=
OPENROUTER_API_KEY=
DAYTONA_API_KEY=
DAYTONA_API_URL=
HONCHO_API_KEY=
HONCHO_WORKSPACE_ID=
ALLOWED_ORIGIN=http://localhost:5173
```

如果你没给 secrets，我用本地 `supabase start` 默认值（`SUPABASE_URL=http://localhost:54321`）跑 dev 验证。**没部署 staging**——那个等你给 CF API token 后我才会做。

## 10. Plans

```bash
ls /Users/hey/.claude/plans/pendingbot-rewrite/
cat /Users/hey/.claude/plans/pendingbot-rewrite/00-index.md | head -30
```

11 个文档。睡前我们一起改的最终版。

## 如果有问题

`BLOCKED.md` 文件如果存在，先读这个（我撞墙的事）。

`PROGRESS.md` 里有当晚每阶段完成度 + 我做的偏离决策（如有）。
