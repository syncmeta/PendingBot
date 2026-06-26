# PendingCrew Task 账本设计

> 落 [声明式对账](../../handbook/pendingcrew/concepts/reconciliation.md) 里已定的 **task 系统**原则,成真正的第三本账。
> 三本账并立:**期望** `docs/handbook/`(纯意图)· **现状** `docs/state/`(状态镜像)· **task** `docs/tasks/`(本设计)。三者互链,供[驾驶舱](../../handbook/pendingcrew/concepts/cockpit.md)渲染、供 `reconcile-check` 断言。
>
> 2026-06-26。存储结构经用户拍板:**一任务一文件**。**PendingCrew 自有,不接 Claude Code TaskList**。

## 1. 定位 — 为什么要第三本账

[对账](../../handbook/pendingcrew/concepts/reconciliation.md) 的引擎是三本账的环:**改期望 → 冒出差 → 人审 → 生 session 补 → 刷现状**。其中:

- **期望**答「该是什么」、**现状**答「实际是什么」、**task** 答「细粒度做没做」并**喂现状**。
- 此前 task 借 Claude Code 内置 TaskList——但那是 **ephemeral、per-session、应用读不到**,无法被驾驶舱渲染、无法被脚本校验、无法跟两本账落成文件级互链。
- 故为 PendingCrew **自建**一套 repo 持久的 task 账本:**借 Claude Code task 系统的思想**(离散单元 + 显式依赖 DAG + 一 task 一 owner + 状态绑事件翻),但做成**仓库里的文件**、**链 handbook**、**带 crew 归属**、**completed = 已验证**。不接入、不依赖 Claude Code TaskList。

## 2. 存储 — 一任务一文件

`docs/tasks/<id>.md`,每个 task 一个带 YAML frontmatter 的文件;**目录即「一个 list」**。

**为什么不是单文件**:这仓库多 worktree 并行 session 是常态,单文件加任务会抢同一文件(合并冲突)——正是迁移系统当年从顺序号改时间戳前缀要躲的坑。一任务一文件零冲突、可扩展,且对齐 `docs/tech-debt/` 「一债一文件」的方向。

**id 方案**(防并发碰撞,不用纯顺序号):`<yyyymmdd>-<2 位短后缀>`,后缀随机或助记(如 `20260626-a3` / `20260626-cp`)。两个 session 同日各建,撞号概率极低且文件名即隔离。

## 3. task 文件格式

```yaml
---
id: 20260626-a3
title: <短标题>
status: todo            # todo | doing | pending-qa | done | dropped
owner: <crew / session / 人>      # 单一,不 co-own;要多人 = 拆小
crew: <crew-id 或 ~>              # 归属 crew(驾驶舱沿 DAG 子树过滤);无归属用 ~
expects: [pendingcrew/concepts/cockpit]   # 链期望(区前缀 handbook relpath,无扩展名),可多
state:   [pendingcrew/concepts/cockpit]   # 链现状(区前缀 + 现状 ## key),可多;与现状条 task: 互为反链
deps:    [20260626-a1]                     # blockedBy 的 task id,DAG;不做 urgency/优先级数字
created: 2026-06-26
updated: 2026-06-26
---

一句话上下文 + 验收标准(怎样算 done)+ 备注。
```

**状态语义**(借 Claude Code 的 pending→in_progress→completed,加 PendingCrew 的验证纪律):

| status | 含义 |
|---|---|
| `todo` | 未开始 |
| `doing` | 进行中(一 owner 在做) |
| `pending-qa` | 代码/逻辑落了,但**需人工/真机/部署才能判 done**,卡在活验 |
| `done` | **已验证可用**(非「代码写了」)——对账判「做没做」以此为准 |
| `dropped` | 作废/被取代,**留痕不删**(记 `note` 为什么) |

**绑事件翻 + 留时间戳**:owner 在「turn 完 / 决策定 / 验证过」那一刻翻 status 并改 `updated`,不攒。

## 4. 互链拓扑 + reconcile-check 断言

三者互链(期望保持纯意图、被链向;task 与现状双向):

```
task ──expects──▶ 期望(handbook 篇)
task ──state───▶ 现状(docs/state 条)
现状 ──task────▶ task               (互为反链)
期望 ──[..]────▶ 期望               (已有 markdown 互链)
task ──deps────▶ task               (依赖 DAG)
```

`reconcile-check` 扩出**跨账断言**(借 Beancount balance assertion + reconciliation.md 的例,**只报错、不自动改账**):

- `task-expects-missing` — task.expects 链到不存在的 handbook 篇
- `task-state-missing` — task.state 链到不存在的现状条
- `state-task-missing` — 现状条 `task:` 链到不存在的 task(反向)
- `task-dep-missing` — task.deps 含不存在的 task id
- `bad-task-status` — status 不在枚举内

以上是**链完整性 + 枚举**断言,语义无歧义、先落(第 3 步)。

**跨账状态一致**(harder,语义要拿准、后置):`state-done-task-open` —— 某现状条 status=`done`,但它链的某条**新账本 task** 还没 `done` → 报错(现状声称做完、底下活没完)。**只这一个方向**:现状条常挂多条 task,「某条 task done」不蕴含「整条现状 done」,故不做反向。

(现状条 `task:` 字段现状里混着 Claude Code `#NNN` 与 roadmap `Tx.y` —— 反向 / 跨状态断言只对**新账本 id 形态**(`yyyymmdd-xx`)生效,`#NNN`/`Tx.y` 视为历史/外部引用豁免,见 §6。)

## 5. per-crew = 过滤视图,不是存储切分

存储**仓库级一份**(`docs/tasks/` 一个目录)。驾驶舱按 `task.crew` 沿 [DAG](../../handbook/pendingcrew/concepts/dag-and-responsibility.md) 子树过滤出 per-crew / 项目级视图——派生无损、零额外存储(同 [cockpit](../../handbook/pendingcrew/concepts/cockpit.md) 的 per-crew 心智)。不造「项目表 / per-crew 独立账本」。

## 6. 存量迁移 — 只迁活跃,不动历史

新账本对**往后**的 PendingCrew 工作生效。现状里现有的 `#NNN` 是 Claude Code id:

- **只把当前活跃的少数**(驾驶舱 / Mac·真机 QA 批次 / reconcile-check / 本 task-账本 自身)import 成新 id 的 t-file,并回填对应现状条的 `task:` 链。
- **历史 completed 的不迁**——留 `#NNN` 作历史痕,reconcile-check 反向断言豁免非新账本 id。
- **递归自指**:本账本第一批任务就是「建大绿豆驾驶舱 / 对账引擎」这摊活自己(handbook 说的「大绿豆 handbook 自身即首个对账对象」)。

## 7. 落地顺序

1. **本 spec**(✓)
2. `docs/tasks/` + `README.md`(格式说明)+ bootstrap 活跃任务 t-file + 回填现状链
3. 扩 `scripts/reconcile-check.ts` 跨账断言(TDD)+ lefthook glob 加 `docs/tasks/**`
4. 驾驶舱渲染三本 + 沿 DAG 过滤(**后续,另立** —— 仍卡 cockpit.md 未定的 UI/schema)

## 8. 边界

- **不接 Claude Code TaskList**:本账本是 PendingCrew 产品/对账系统的事实源;Claude Code 的内置 TaskList 只是 agent 跑某个 session 时的临时工作记忆,二者不打通。
- **不做 urgency / 优先级评分**:排序靠依赖 DAG(`deps`)+ 人判,不引入数字优先级(借 Claude Code,避免假精确)。
- **task 不写进期望 handbook**:期望页保持纯意图、不带状态、不挂 task 链(链是 task→期望 单向 + task↔现状 双向)。
- **本 spec 只定 task 账本的数据模型 + 校验**;驾驶舱怎么渲染三本是 cockpit.md + #439 的事,不在此。
