# 路线图

> 这一篇是**地图,不是账本**:给产品决策者 v1.0 的全局视野——要交付哪几块、按什么顺序推。**它只写计划与意图、不带状态**:"做没做"以 Task 系统为准、"整体到哪了 / 当前真实状态"以 `docs/progress.md` + `docs/state/` 为准、结构风险以 `docs/tech-debt/` 为准——本篇只给向下的指针,不复制它们的流水(否则必然漂移)。
>
> 重大产品转向(为什么从 A 变成 B)单独成篇:[重大转向史](pivots.md)。

## 逻辑 — v1.0 在做什么

大绿豆 v1.0 是**两个产品一次发**:[PendingBot](../../pendingbot/vision.md)(普通人的三端主动 AI 朋友 IM)+ [PendingCrew](../../pendingcrew/vision.md)(开发者的 crew 编排台)。两者共享一套[身份地基](../concepts/subject.md)、[计费](../concepts/billing-subject.md)和基础设施,所以路线图按**共享地基 → 各自功能**的顺序推进,而不是两条独立产品线并跑。

v1.0 的范围由一份实现路线图(`docs/superpowers/plans/2026-05-28-v1-0-implementation-roadmap.md`)切成 6 个 phase、20+ 个 task:

| Phase | 主题 | 这一阶段产出什么 |
|---|---|---|
| 0 | 基础建设 | 三端 / 双端 SwiftUI 工程脚手架(PendingBot iOS+iPad+Mac、PendingCrew iPad+Mac) |
| 1 | 身份地基 | Subject + 群账号权限矩阵 + 扫码登录 + PendingBot 三端 IM 基础壳 |
| 2 | Crew 核心 | Crew / Captain / DAG 责任比例的数据与规则 |
| 3 | 本地 crew 闭环 | PendingCrew 在本机跑通 Claude Code / Codex 一整个 session |
| 4 | 通信 + Bot 扩展 | Session ↔ 群聊通信、权限审批、bot 主动发起 crew、跨端遥控 |
| 5 | BYOK + 整合 | PendingCrew 未登录 BYOK 路径 + 端到端 QA |

原估一人 11–13 周。这是**做事顺序**,不是产品规格 —— 任何产品逻辑细节以本手册各 `concepts` / `features` 篇为准,不以路线图为准。

## 为什么 — 这篇存在的理由

四个账本各管一段,但都不站在产品高度给"v1.0 整体要交付什么、按什么顺序推"的一页地图:

- **Task 系统** 答"这个可提交单元做没做";
- **`docs/progress.md`** 答"当前真实状态 + 阻塞 + 下一步"的编年叙事;
- **`docs/state/`** 答"每个概念 / 功能现状逐条到哪了";
- **`docs/tech-debt/`** 答"哪里有结构风险 / 关不掉的尾巴"。

本篇就补这一格:给手册读者一张**一页纸路线图**——先有全局的"做什么、什么顺序",要落到"做没做 / 到哪了 / 风险"时顺着指针下钻到上面那几个账本。所以它**刻意保持薄**,只留会长期稳定的计划骨架,把易变的状态流水留在账本里。

## 注意 — 别拿这篇当事实源

- **数字会变,本篇不追。** 周数、commit hash、vitest 条数、"未合 / 已合 main"这类易变事实,都在 `docs/progress.md` 里维护;本篇只给方向。看到本篇与 progress 冲突,**以 progress 为准**并回头修本篇(它过时了)。
- **"未合 main"字样在 progress 里曾大面积漂移过** —— 2026-06-16 一次对账发现多个标"未合"的分支其实已合(codex-app-server / crew-machine / model-blindbox / session-crew-comms 等)。这正是"易变事实别进手册"的反面教材:本篇不复制这类标记。
- **roadmap 文档本身是 2026-05-28 的草案**,部分 task 描述(如 captain"三种 / 四种来源"、双轨路由)已被后续转向覆盖,**别照搬 roadmap 的旧措辞**,以 [pivots](pivots.md) + 各 concept 篇为准。
