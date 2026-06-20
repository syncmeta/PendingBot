# 项目驾驶舱(project cockpit)

> ⬜ **规划概念(task #439)。** 把多 crew 协作做成一个「项目级」的协作台:每个 crew 拥有自己的一份文档子树 + task / 进度 / tech-debt 账本,crew 之间的 DAG 边构成层级,**「项目」= crew DAG 的一个连通分量 = 纯派生视图**。一个项目一个 dashboard,聚合该连通分量内所有 crew 的文档 + task + 进度 + tech-debt。本质 = 把规范驱动开发(SDD)做成多 agent 的项目协作台。相关:[Crew 与 Captain](crew.md) · [运行位置与 Machine](runtime-location-and-machine.md)。

## 逻辑

**crew = 所有者。** 每个 crew 不只是「一组群聊 + agent」,它还**拥有一份属于自己的账本子树**:
- 一份文档子树(这个 crew 负责的那块的 spec / 设计 / 说明);
- 自己的 task 列表(做没做的事实源);
- 自己的进度 rollup;
- 自己的 tech-debt(结构风险 + 关不掉的尾巴)。

**DAG 边 = 层级。** crew 之间的父子边(见 [Crew 与 Captain](crew.md) 末尾指向的 DAG 概念)构成组织层级:父 crew 统领子 crew,层层分解。

**项目 = crew DAG 的连通分量 = 纯派生视图。** 「项目」这个东西**不单独存储**——它就是「把通过 DAG 边连在一起的那一坨 crew 看成一个整体」。所以:
- **连边 = 合并两个项目**(两个原本独立的连通分量被一条边连起来 → 变成一个项目);
- **断边 = 拆分一个项目**(连通分量断开 → 拆成两个项目);
- 这两个操作**都是无损的**,因为项目级零存储:所有内容都挂在 crew 上,项目只是「当前怎么把它们归堆」的一个视图。

**一个项目一个 dashboard。** 这个 dashboard 聚合该连通分量内**所有 crew** 的:文档 + task + 进度 + tech-debt + 各自的负责 crew。它是这个多 crew 协作体的「驾驶舱」——一眼看清整个项目到哪了、谁负责什么、有哪些债。

## 为什么

- **项目级零存储,是为了让组织结构可以自由重组而不丢东西。** 如果「项目」是一张实体表、内容挂在项目上,那合并 / 拆分 crew 群就得迁移数据、对账、处理孤儿。把项目做成「DAG 连通分量的派生视图」,内容永远挂在最小单位(crew)上,连边断边只改变「怎么看」,不改变「存了什么」——组织怎么演化都无损。这是「轻量化、可临时」协作心智的自然延伸:协作体随时建、随时拆,基础设施不该为此叫苦。
- **本质是把 SDD(spec-driven development)做成多 agent 协作台。** 单人用 spec → plan → task → 实现这套规范驱动流程已经很顺;项目驾驶舱要把它扩到「多个 agent / 多个 crew 各管一块、各有自己的 spec 与账本、在一个 dashboard 下汇总」。每个 crew 是一个有边界、有文档、有 task 的工作单元,DAG 把它们组织成项目,dashboard 把它们的状态聚合呈现——这正是多 agent 版的 SDD。
- **递归自指是这个设计的试金石。** 大绿豆自己这本 handbook + 配套的 `docs/tech-debt/`(一债一文件 + frontmatter)+ `docs/progress.md` + task 系统,**就是项目驾驶舱要渲染 / 管理的东西的原型**——结构化文档子树 + 结构化债 + 进度 rollup + task 事实源。手册的写作规约里已经写明「账本结构化、可被未来 PendingCrew 项目驾驶舱渲染」,「一债一文件 + frontmatter」「现在是仓库级一份、『一 crew 一份』是 #439 的事、格式先对齐」——这些都是在为驾驶舱**先把数据形状对齐**,等驾驶舱建起来时直接能渲染。

## 用在哪 · 长什么样(规划)

- **dashboard 视图**:一个项目(连通分量)进去,看到该项目内所有 crew 的聚合——文档树、汇总的 task 看板、进度 rollup、tech-debt 列表,以及「哪个 crew 负责哪块」的责任地图(沿 DAG 层级)。
- **crew 编辑**:在 crew 设置里指定父 crew(连边)/ 解除(断边),实时反映成项目的合并 / 拆分。
- **账本就地挂在 crew 上**:每个 crew 的文档子树 / task / 进度 / tech-debt 由它自己持有,dashboard 只做聚合呈现,不另存一份。

## 边界(规划)

- **项目不是实体,不单独存储**——它永远是 DAG 连通分量的派生视图。任何「项目表 / 项目级字段」的设计都与此冲突。
- **本篇只定模型**(crew 所有权 + DAG 层级 + 项目 = 连通分量 + dashboard 聚合),不定具体 UI / schema / 渲染管线——那些到真正动工(#439)时再设计。
- 这是 PendingCrew 的 feature,不是 PendingBot 的——PendingBot 只「看见 crew」,深度的项目编排在 PendingCrew。

## 注意

- ⚠️ **当前账本是「仓库级一份」,不是「一 crew 一份」。** `docs/tech-debt.md` / `docs/progress.md` / task 系统现在都是整个仓库共用一份;「一 crew 一份」是本概念(#439)落地时才切的。**格式计划往「一债一文件 + frontmatter」对齐**(为将来可渲染做准备),但**这步本身也还没落地**——现状仍是单文件 `docs/tech-debt.md`;更别急着真切成 per-crew。先让形状对上,等驾驶舱来。
- ⚠️ **「项目」当前在产品里还没有这个一等概念**;crew 的父子 DAG 已经有(见 [Crew 与 Captain](crew.md)),但「把连通分量呈现成项目 dashboard」整个是规划。别把 DAG 已实现当成项目驾驶舱已实现。
- 早期 spec 里「标签(tag)」承担「同项目归一类」的职责——tag **已连根删**,这个职责改由**父 crew** 承载(见 [运行位置与 Machine](runtime-location-and-machine.md) 与 create-flow 设计)。所以「项目 = 连通分量」是建立在「父 crew 做分类」这个已落地的前提上的。

## 现状

⬜ **规划(task #439)。** 模型已拍定(crew 所有权 + DAG = 层级 + 项目 = 连通分量纯派生 + dashboard 聚合 + 本质是多 agent SDD),账本数据形状**计划**为它对齐(规范化成一债一文件 + frontmatter,尚未落地),dashboard / 渲染 / per-crew 账本切分也**均未实现**。
