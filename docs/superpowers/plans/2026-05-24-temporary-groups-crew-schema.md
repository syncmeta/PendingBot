# 临时群与 Crew Schema 实施计划

> Spec: `docs/superpowers/specs/2026-05-24-crew-temporary-groups-design.md`
> Branch: `codex/temporary-groups-foundation`
> 日期：2026-05-24

## 目标

这一阶段只落数据库和类型地基，让系统正式认识两种新会话：

- `temporary_group`：机器人创建的临时协作群。
- `crew`：人类创建的 coding-agent 编排临时群，也是本机/云端 coding agent 权限边界。

本阶段不启动 runner、不创建 coding session、不替换旧 `subagent` 工具。这样可以先把会话类型、归因 subject、成员、求助入口和 RLS 访问模型固定下来。

## 不做

- 不接入 Cloudflare Sandbox。
- 不接入 macOS 本地 runner。
- 不做 iOS/macOS Crew UI。
- 不改消息发送主流程。
- 不删除旧 `subagent` 历史路径。

## 任务

### Task 1：新建 migration

新增迁移：

```bash
supabase migration new temporary_groups_crew_schema
```

内容：

- 扩展 `conversations_conversation_type_check`，加入 `temporary_group`、`crew`。
- 新建 `temporary_group_meta`。
- 新建 `temporary_group_members`。
- 新建 `human_help_requests`。
- 新增访问 helper：
  - `is_temporary_group_human_member(conversation_id, user_id)`
  - `can_view_temporary_group(conversation_id, user_id)`
- 给三张新表开启 RLS。
- `temporary_group_meta` / `temporary_group_members`：成员或 responsible subject 控制者可读。
- `human_help_requests`：被请求用户、请求者、responsible subject 控制者可读。
- service role 可写。

### Task 2：应用 linked DB 并生成类型

```bash
supabase db push --linked
bun --filter='@pendingbot/edge' run types:db
```

预期：

- linked DB 应用新 migration。
- `apps/edge/src/db/schema.ts` 出现三张新表和 helper RPC。

### Task 3：最小 smoke 验证

查询 linked DB：

```bash
supabase db query --linked "select conname from pg_constraint where conname = 'conversations_conversation_type_check';"
supabase db query --linked "select to_regclass('pendingbot.temporary_group_meta') as temporary_group_meta;"
supabase db query --linked "select to_regclass('pendingbot.temporary_group_members') as temporary_group_members;"
supabase db query --linked "select to_regclass('pendingbot.human_help_requests') as human_help_requests;"
```

预期：

- constraint 存在。
- 三张表都存在。

### Task 4：检查

```bash
bun --filter='@pendingbot/edge' run typecheck
supabase db push --linked --dry-run
```

预期：

- typecheck PASS。
- linked DB up to date。

### Task 5：提交

```bash
git add supabase/migrations/<timestamp>_temporary_groups_crew_schema.sql apps/edge/src/db/schema.ts
git commit -m "db: add temporary group and crew schema"
```

## 后续阶段

Phase 3 再做：

- `crew_sessions`
- `session_events`
- dependencies/mailbox/file claims/permission requests
- Crew coordinator API
- subject debit path 接入真实 session 费用

