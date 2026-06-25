---
status: planned
---

# Todolist(给人看的清单)

> handbook / 仓库里一类 **per-crew 的 todo markdown 文件**:本地、git 跟踪、session 直接读文件。一份**随意的、给人看的**轻清单——crew 跑到哪了、有什么该你拍板、有什么该你亲自去做。它**跟着 crew 层级走,就是 handbook 的一部分**,和 [声明式对账](../../pendingcrew/concepts/reconciliation.md) / [cockpit](../../pendingcrew/concepts/cockpit.md) 同属「文件即账本」这套账本观。相关:[PendingBot 定位](../vision.md)。

**逻辑**

- **它是 repo 里的文件,不是云功能。** todolist 就是 handbook / 仓库里一个(或几个)markdown 文件,落盘、随 git 走、session 打开就能读。没有服务端状态、没有不可见的远端账本——它和代码、和 crew 的真实进展长在同一棵树上,改动有迹可循。
- **per-crew,跟着 crew 层级。** 一份 todolist 属于某个 crew / 某个子树,放在它对应的目录里。这呼应 [声明式对账](../../pendingcrew/concepts/reconciliation.md) 的心智:账本存仓库级、**per-crew 只是沿层级切出来的过滤视图**。todolist 是这套观念在「给人看的轻清单」上的一个具体落点——它本身就是 handbook 的内容,不是另起一摊。
- **给人看,很随意。** 它是一串**人**要知道 / 要拍板的事,不是给 agent 看的结构化看板。故意做得随意:随手记、随手勾、不强求结构,像便签而不像项目管理工具。

**为什么**

- **「是 repo 文件、不是云」正好化解 local-first 冲突。** 大绿豆的清单本来面临一个张力:要 git 跟踪(和代码不漂移)、又想随时随地加。把它**定义成仓库里的文件**就一刀切干净了——它不是云、是 repo 的一部分,所以不需要双主 sync、不需要自研同步层,也就没有 local-first 那套一致性难题要解。
- **随意保人愿意用,git 跟踪保不漂移。** 随意,人才愿意随手记(不被项目管理工具的仪式感劝退);git 跟踪,清单才和代码不脱节(它是仓库的一部分,不是另一个要单独维护、会和现实脱节的看板)。这两条是刻意的取舍,缺一不可。
- **轻清单就该只做轻清单。** 结构化的递归聚合、派活、drift 视图是 [cockpit](../../pendingcrew/concepts/cockpit.md) / [对账](../../pendingcrew/concepts/reconciliation.md) 的活;人真正要操心的那一小撮,抽出来做成读着舒服的轻清单就够了。两件事共用一套账本观,但各做各的,不互相吞。

**用在哪·长什么样**

- **形态**:handbook / 仓库里一个 per-crew 的 markdown 文件,一份轻量、可勾选的清单。条目可能来自 crew 的进展、等你拍板的请求,也可能是你随手记给自己的。底层就是 git 跟踪的文件,session 直接读写。
- **跟 crew 走**:放在对应 crew / 子树的目录下,沿层级派生出「这个 crew 此刻该人操心的事」。

**边界**

- **不单独造云功能。** 它就是 repo 文件,不起一套服务端、不做远端账本——这是它能避开 local-first 冲突的前提,别又把它做成云。
- **不和 cockpit 自动衔接、不做双主 sync。** 不和 [cockpit](../../pendingcrew/concepts/cockpit.md) 配成「机器视角 vs 人视角」的自动配对,不在两边之间同步状态。它只是和 cockpit / 对账**同属一套账本观**(文件即账本),引用到此为止,不做数据接缝。
- **想要移动端随时加 / 跨设备同步?用现成的,不造轮子。** 这类需求交给 **Apple 提醒事项 / Microsoft To Do** 这种成熟工具,不自研同步 / 不自建移动端清单。todolist 守住「repo 里给人看的轻清单」这一件事。
- **不抢 crew 编排。** 不做递归子树聚合、不做 drift chip 一键派活、不做结构化 task 看板——那些是 [cockpit](../../pendingcrew/concepts/cockpit.md) / [对账](../../pendingcrew/concepts/reconciliation.md) 的活;深度 crew 操作仍跳 PendingCrew。
