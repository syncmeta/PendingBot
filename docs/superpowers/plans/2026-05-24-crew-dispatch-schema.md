# Crew Dispatch Schema 实施计划

> Spec: `docs/superpowers/specs/2026-05-24-crew-temporary-groups-design.md`
> Branch: `codex/temporary-groups-foundation`
> 日期：2026-05-24

## 目标

这一阶段给 Crew 的 coding-agent 编排落状态机地基：

- `crew_sessions`：每个 coding agent 运行实例。
- `session_events`：过程输出和结构化进度，不刷进群消息流。
- `session_dependencies`：显式依赖和 blocker。
- `session_mailbox_items`：session 之间传状态、问题和交接。
- `session_file_claims`：声明路径占用，降低并行 session 互相踩文件的概率。
- `permission_requests`：高风险操作的审批请求。

本阶段仍不接 runner，不发 lease，不调用本机或云端 coding agent。

## 任务

### Task 1：新建 migration

```bash
supabase migration new crew_dispatch_schema
```

内容：

- 新建六张 dispatch 表。
- 新增 helper：
  - `can_view_crew_session(crew_session_id, user_id)`
  - `can_control_crew_session(crew_session_id, user_id)`
- RLS：
  - Crew session 可见者可读 session、非 private event、dependencies、mailbox、file claims。
  - responsible subject 控制者可读 permission request。
  - service role 负责写入和状态推进。

### Task 2：应用 linked DB 并生成类型

```bash
supabase db push --linked
bun --filter='@pendingbot/edge' run types:db
```

### Task 3：smoke 验证

```bash
supabase db query --linked "select to_regclass('pendingbot.crew_sessions') as crew_sessions;"
supabase db query --linked "select to_regclass('pendingbot.session_events') as session_events;"
supabase db query --linked "select to_regclass('pendingbot.permission_requests') as permission_requests;"
```

### Task 4：检查并提交

```bash
bun --filter='@pendingbot/edge' run typecheck
supabase db push --linked --dry-run
git add supabase/migrations/<timestamp>_crew_dispatch_schema.sql apps/edge/src/db/schema.ts docs/superpowers/plans/2026-05-24-crew-dispatch-schema.md
git commit -m "db: add crew dispatch schema"
```

