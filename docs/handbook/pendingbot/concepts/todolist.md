# Todolist(给人看的清单)

> ⬜ 规划概念。PendingBot 在移动端充当 PendingCrew 的 crew 与人之间桥梁时,配套的一份**随意的、git 跟踪的、给人看的** todo list。它和 PendingCrew 给 crew / agent 看的 [cockpit 驾驶舱](../../pendingcrew/concepts/cockpit.md) **配对**——cockpit 是机器视角的递归驾驶舱,todolist 是人视角的轻量清单。相关:[PendingBot 定位](../vision.md) · [驾驶舱(cockpit)](../../pendingcrew/concepts/cockpit.md)。

## 逻辑

- **一份给人看的清单,不是给 agent 看的看板。** todolist 是一串**人**要知道 / 要拍板的事:crew 跑到哪了、有什么在等你点头、有什么该你亲自去做。它服务于「人在移动端怎么跟一坨在跑的 crew 打交道」这个场景,落在 PendingBot 这个移动端主战场上。
- **随意、轻。** 不是正式的 task 系统(那是 [cockpit](../../pendingcrew/concepts/cockpit.md) 聚合的、crew 持有的结构化账本)。todolist 故意做得随意:随手记、随手勾、不强求结构,像便签而不像项目管理工具。
- **git 跟踪。** 这份清单随仓库走、有版本历史——它落在文件里、跟着 git 一起改,而不是某个不可见的服务端状态。这让「人看的清单」和「代码 / crew 的真实进展」长在同一棵树上,改动有迹可循。

## 为什么

- **机器视角和人视角要分开两份。** cockpit 给 crew / agent 看:递归聚合整个子树的 文档 / task / 进度 / tech-debt / drift chip,是机器要消费、要派活的结构化面。人不需要、也不该被那一整套灌进脑子。todolist 把**人真正要操心的那一小撮**抽出来,做成人读得舒服的轻量清单——两者是同一件协作的两个视角,**配对**而非重复。
- **桥梁要落在人随身的设备上。** crew 在电脑 / 云端跑,但需要人拍板的时刻,人未必坐在电脑前。把「该你看 / 该你定」的事做成一份移动端的轻清单,人在手机上就能跟进、就能拍板——这正是 PendingBot 当 crew↔人 桥梁的具体抓手。
- **「随意 + git 跟踪」是刻意的取舍。** 随意保证人愿意用(不被项目管理工具的仪式感劝退);git 跟踪保证它和代码不漂移(清单是仓库的一部分,不是另一个要单独维护、会和现实脱节的看板)。

## 用在哪 · 长什么样(规划)

- **入口**:PendingBot 移动端(主战场),在 crew↔人 桥梁的语境里——大致挨着 Crew Tab 那条接缝,把「该人知道 / 该人定」的事汇成一份清单给人看。
- **形态**:一份轻量、可勾选的清单;条目可能来自 crew 的进展、等待人拍板的请求,也可能是人随手记给自己的。底层是 git 跟踪的文件。
- **与 cockpit 的关系**:同一坨协作,cockpit 是机器侧的全量驾驶舱(在 PendingCrew),todolist 是人侧的提要(在 PendingBot)。

## 边界

- **不是 task 系统 / 不是 cockpit。** 不做递归子树聚合、不做 drift chip 一键派活、不做结构化 task 看板——那些是 [cockpit](../../pendingcrew/concepts/cockpit.md)(PendingCrew)的活。todolist 只做「给人看的轻清单」这一件事。
- **不抢 crew 编排。** 它是桥梁的人侧界面,不在里面做深度的 crew 操作;深度操作仍跳 PendingCrew。

## 现状

⬜ **规划。** 概念已定(人视角轻清单 + git 跟踪 + 与 cockpit 配对,落在 PendingBot 移动端的 crew↔人 桥梁里)。具体形态 / 入口 / 与 git 的落盘方式 / 与 cockpit 的数据接缝**均未实现**——和 [cockpit](../../pendingcrew/concepts/cockpit.md)、移动端桥梁一起属规划区。
