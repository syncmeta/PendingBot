# PendingCrew 任务清单 (Task List)

> [声明式对账](../handbook/pendingcrew/concepts/reconciliation.md) 三本账之一:**期望** `docs/handbook/` · **现状** `docs/state/` · **task**(本目录)。细粒度「做没做」的事实源,喂现状、链期望,供[驾驶舱](../handbook/pendingcrew/concepts/cockpit.md)渲染。
>
> **PendingCrew 自有,不接 Claude Code TaskList**(借其思想:离散单元 + 依赖 DAG + 一 owner + 状态绑事件,但 repo 持久 + 链 handbook + crew 归属 + completed=已验证)。设计见 [spec](../superpowers/specs/2026-06-26-pendingcrew-task-ledger-design.md)。

**一任务一文件** `<id>.md`,目录即列表。`id = <yyyymmdd>-<2 位短后缀>`(并行 session 零冲突)。frontmatter:

| 字段 | 含义 |
|---|---|
| `status` | `todo` / `doing` / `pending-qa` / `done` / `dropped`。**`done` = 已验证可用**(非「代码写了」);需人工/真机才能判 done 的停在 `pending-qa`;作废用 `dropped`(留痕)。 |
| `owner` | 单一(crew / session / 人),不 co-own;要多人 = 拆小 |
| `crew` | 归属 crew(驾驶舱沿 DAG 子树过滤);无归属 `~` |
| `expects` | 链期望:区前缀 handbook relpath(无扩展名),可多 |
| `state` | 链现状:区前缀 + 现状 `## key`,可多;与现状条 `task:` 互为反链 |
| `deps` | blockedBy 的 task id(依赖 DAG,**不做 urgency / 优先级数字**) |
| `created` / `updated` | 时间戳,状态绑事件那一刻翻、不攒 |

**互链 + 校验**:`task → 期望`(expects)、`task ↔ 现状`(state ↔ 现状条 task:)、`期望 ↔ 期望`(markdown 互链)。`bun scripts/reconcile-check.ts` 断言每条跨账链闭合(链到不存在的篇/条/id → 红灯),进 lefthook pre-commit。详见 [spec §4](../superpowers/specs/2026-06-26-pendingcrew-task-ledger-design.md)。
