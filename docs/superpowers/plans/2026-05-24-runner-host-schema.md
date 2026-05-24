# Runner Host Schema 实施计划

> Spec: `docs/superpowers/specs/2026-05-24-crew-temporary-groups-design.md`
> Branch: `codex/temporary-groups-foundation`
> 日期：2026-05-24

## 目标

给云端 runner 和 macOS 本机 runner 建统一登记与 lease 边界：

- `runner_hosts`：某个 subject 可用的执行器，可能是 cloud，也可能是 macOS app 注册的本机 runner。
- `runner_leases`：单个 Crew session 拿到的短期运行授权。
- `crew_sessions.runner_host_id` 正式 FK 到 `runner_hosts`。

本阶段不实现 macOS runner 进程、不接 Cloudflare Sandbox，不发真实 lease token。

## 任务

1. 新建 migration：`runner_host_schema`。
2. 新建 `runner_hosts`、`runner_leases`。
3. 给 `crew_sessions.runner_host_id` 加 FK。
4. 新增 RLS helper 和 select policy。
5. linked DB push，生成 `apps/edge/src/db/schema.ts`。
6. typecheck、smoke、提交。

