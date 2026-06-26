# 声明式对账(账本系统)

> [Crew] PendingCrew 的引擎,也是「**声明式自然语言创作平台**」这个北极星的落地心智:**你用自然语言声明要什么(期望),系统对照现状、把差交给人审、生 session 去补。** 给"创作"的 Terraform —— 只是 spec 是人话、执行者是 AI agent。相关:[PendingCrew 定位](../vision.md) · [驾驶舱](cockpit.md) · [Captain](captain.md) · [人在回路](human-in-the-loop.md)。

## 逻辑 — 三层 + 两段式

三层(借 Terraform 的 desired / state / actual):
- **期望**(desired)—— 期望 handbook,纯自然语言意图,**该是什么**。
- **现状**(observed)—— 现状 handbook,结构化、**每 session 强制刷新**,**实际是什么**。
- **代码 / 产物**(actual)—— 真实跑着的东西。

两段式(人审,不自动):
- **对齐 = 比对 期望 vs 现状**(像 `terraform plan`,把差摆给人看)。
- **补差 = captain 生 session 去做**(像 `apply`,人审批,不自动 converge)。

整个产品的引擎就是这个环:**改期望 → 冒出差 → 人审 → 生 session 补 → 刷现状**。"改文档就构建应用"说的就是它。

## 为什么 — 祖宗与命门

- **落在 Terraform 端,不是 K8s 端。** K8s 持续自动 converge,多 agent 自动起活易失控;我们要**两段式 + 人在中间审**(同 [人在回路](human-in-the-loop.md) 的"卡在 planning")。
- **比 SDD 多半个环。** Kiro / Spec Kit 只有前向流(意图 → spec → 执行),没有把现状反哺回意图的对账环 —— 我们补的正是那半环。
- **强制刷新现状 = `refresh`,命门所在。** Terraform 的盲区是"测不到没纳管的资源";映射过来:**现状 handbook 不强制每 session 刷,对账就失明**。这条纪律是整套的命:失效永远是纪律没跟上,不是工具的错。

## 三本账 + 怎么记

- **期望 handbook**(`docs/handbook/`)—— 纯意图,**不带状态**。
- **现状 handbook**(`docs/state/`)—— 结构化、**镜像 `docs/handbook/` 的路径**、**每 session 强制刷**;每条 = `status:`(枚举,不放 emoji)+ 一句现状 + 证据指针 + **链到相关 task**。
- **task 系统** —— 细粒度"做没做",**喂现状**;**反链回 handbook 概念**(双向:现状条→task,task 描述→期望页)。约定(借 Claude Code + org-mode):状态**绑事件翻 + 留时间戳痕**(captain turn 完 / 决策定那一刻翻,不攒)· 一 task 一 owner(不 co-own,拆小)· `completed = 已验证`(非"有代码",带显式 `pending-qa` 中间态)· 依赖是 id 字段、不做 urgency 评分。

## per-crew = 显示层

存储**仓库级**(一份期望 + 一份现状 + 一个 task)。**per-crew / 项目都只是过滤视图**(沿 DAG 子树切片,派生无损、零额外存储 —— 借 Logseq 的查询派生子图)。

## 边界(都是有意不做)

- **不自动检测 drift** —— 差一点不必对齐、也难做;对齐靠人读两本。
- **不自动 converge / 不做 chip 队列** —— captain 看差直接生 session,最小工程。
- **不重解析文档** —— 既然不自动判 drift,cockpit 只渲染两本 + 人读差,不必把文档解析成 AST。
- **不从代码自动重生文档** —— 意图永远领先代码;living-docs 那套会侵蚀"期望是源"。
