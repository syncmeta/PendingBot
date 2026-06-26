# 驾驶舱(cockpit)

> [Crew] [声明式对账](reconciliation.md) 的**呈现 + 控制面**——把那套引擎做成一块看得见、按得动的面。**看板半边**渲染 期望 / 现状两本 + task(像 `terraform plan`,把差摆给人看);**控制半边**让 captain 看着差直接生 session / crew 去补(像 `apply`,人审、不自动)。每个 crew 一块驾驶舱,沿 DAG 子树聚合——**项目级总览**只是从顶层 crew 往下看的那一坨。本篇只讲「长什么样 / 怎么用」,机制全引 [对账](reconciliation.md)。相关:[声明式对账](reconciliation.md) · [Crew 与 Captain](crew.md) · [DAG 与责任比例](dag-and-responsibility.md) · [人在回路](human-in-the-loop.md)。

## 逻辑

驾驶舱不持有任何机制,它是 [对账](reconciliation.md) 那个环(**改期望 → 冒出差 → 人审 → 生 session 补 → 刷现状**)的 UI。一块面分两半:

**看板半边 = 把两本账 + task 摆出来给人看。** 渲染 [对账](reconciliation.md) 的三本账:
- **期望**(纯自然语言意图)、**现状**(结构化、每 session 强制刷)两本并排;
- **task** 看板(细粒度"做没做")挂在旁边;
- 状态走 **frontmatter**(`status:`,不放 emoji)直接渲染成色块,不另解析正文。

它就是 `terraform plan` 的那一屏:**把期望和现状摆在一起,差留给人读**。驾驶舱不替人判 drift——不重解析文档、不比对 AST(见 [对账](reconciliation.md) 边界);"哪儿没对齐"是人扫两本看出来的,不是系统标出来的。

**控制半边 = captain 看着差直接生 session 去补。** 这是 `terraform apply`,但**人审、不自动 converge**:
- captain(或人)在看板上读出某处期望领先了现状;
- 直接在面里**生一个 session / 子 crew**,把那段期望当 brief 派下去；
- session 把代码 / 产物对齐 → 回来**刷现状**那本 → 看板上那处的差消失。

**没有 chip 队列、不冒 chip、不自动起活。** 控制半边就是"看着差、手动生 session"这一个最小动作(见 [对账](reconciliation.md):captain 看差直接生 session,最小工程)。改一笔期望不会自动派出一堆 agent,也不会先排成一列待办卡片等人点——人 / captain 直接从看板生活。

**per-crew = 过滤视图(显示层)。** 存储是**仓库级一份**(一份期望 + 一份现状 + 一个 task,见 [对账](reconciliation.md))。每个 crew 的驾驶舱只是**沿 DAG 子树切一刀的过滤视图**:
- 叶子 crew 的驾驶舱 = 只看自己那片;
- 顶层 crew 的驾驶舱 = 它下面整个连通分量(这就是"项目级"总览);
- 中间任何 crew = 自己 + 下面的子树。

派生**无损、零额外存储**——连边 / 断边(改 DAG)只改"怎么切",不改"存了什么"。所以"项目"(= 一个连通分量,见 [DAG](dag-and-responsibility.md))不必是一等实体:你通过某个 crew 的驾驶舱往下看,看到的就是那一坨。

## 为什么

- **看板 + 控制一体,才是对账环的操作台。** [对账](reconciliation.md) 是引擎;驾驶舱把这个环变成一块人能盯、能按的面——左边看清期望与现状的差(plan),右边一步生 session 补差(apply)。两半同屏,人不离开就能从"看出差"走到"派活补差"。
- **per-crew 是过滤而非存储,组织可随时重组而不丢东西。** 内容永远是仓库级那一份,驾驶舱只是"当前怎么沿 DAG 把子树归堆"的派生视图。任意粒度(从单个 crew 到整个连通分量)共用一套总览,顶层 crew 的驾驶舱自动就是"项目仪表盘",而不用造"项目"这个一等实体。这是"协作体随时建随时拆"那套轻量心智的延伸。
- **状态走 frontmatter、不重解析文档,所以驾驶舱"轻"。** 既然不自动判 drift(见 [对账](reconciliation.md)),驾驶舱只需读 frontmatter 渲染状态、把两本并排——不必把文档解析成 AST、不必跑 drift 算法。判差这件难事交还给人读,UI 这层就只剩"渲染 + 生 session"。
- **半自动而非全自动。** 改期望不自动起一堆 agent(易失控),而是落在看板上、由人 / captain 直接生 session 去补。human-in-loop 卡在 planning,跟 PendingCrew「[交互非审批](human-in-the-loop.md)」、[对账](reconciliation.md) 的"落在 Terraform 端不是 K8s 端"一脉相承。
- **递归自指是试金石。** 大绿豆自己这本 handbook + 配套账本(期望 / 现状两本 + task),就是驾驶舱要渲染 / 控制的东西的原型;先按 [对账](reconciliation.md) 把数据形状(两本账 + frontmatter 状态 + task)理顺,等驾驶舱建起来直接能渲染。

## 用在哪 · 长什么样(规划)

- **入口**:任意 crew 的详情 / 侧栏有个「驾驶舱」视图,进去就是这个 crew + 它子树(沿 DAG 切片)的聚合面。
- **看板半边**:期望 handbook 与现状 handbook 两本并排(可点开各自的篇)、task 看板(按 crew / 状态)、frontmatter 状态渲染成色块、DAG 责任地图。一眼看清这片子树到哪了、谁负责什么、期望和现状差在哪。
- **控制半边**:在看板上读出差后,**一步生 session / 子 crew**——选一段期望当 brief 派下去;不排队、不冒 chip。
- **补差即刷现状**:派下去的 session 干完 → 回来刷现状那本 → 看板上那处差消失、frontmatter 状态回绿。

## 示例(规划)

你在「鉴权重构」crew 的驾驶舱里,看到它下面有两个子 crew(edge 侧、iOS 侧),两本账 + task 都沿 DAG 汇总在一屏。你打开 edge 侧期望 handbook 里那篇 `登录`,把"OTP 改成 6 位"这条意图改了。看板半边立刻显出差:期望那本写的是 6 位,现状那本还是旧的——一眼能读出 edge 侧这块期望领先了现状。你不等系统标 drift、也没有 chip 排队,直接在控制半边**生一个 session**、把这段期望当 brief 派给 edge 子 crew 去改。改完那个 session 刷现状那本 → 看板上这处差消失、`登录` 那篇 frontmatter 状态回绿。整个过程你没离开驾驶舱,差是你读出来的、活是你一步派下去的。

## 边界

- **驾驶舱只是呈现 + 控制面,机制全在 [对账](reconciliation.md)。** 三层 / 两段式 / 强制刷现状 / 三本账怎么记,都不在本篇定义——本篇只定"长什么样 / 怎么用"。改机制改 [对账](reconciliation.md),不改这里。
- **不冒 chip、不做 chip 队列、不自动派活。** 控制半边是"看着差手动生 session"一个动作;不把待办排成一列卡片、不一键自动起活(见 [对账](reconciliation.md):不自动 converge / 不做 chip 队列)。
- **不自动检测 drift、不重解析文档。** 差靠人读两本看出来;驾驶舱不跑 drift 算法、不把文档解析成 AST(见 [对账](reconciliation.md) 边界)。
- **驾驶舱不是实体,项目不单独存储。** 永远是"某个 crew + 其子树"沿 DAG 的派生过滤视图。任何"项目表 / 项目级字段 / per-crew 独立账本"的设计都与此冲突——存储是仓库级一份。
- **本篇只定模型**(对账的呈现 + 控制面 + per-crew 过滤视图 + 看板 / 控制一体),不定具体 UI / schema——真动工(#439)时再设计。
- 这是 **PendingCrew** 的 feature —— PendingBot 只"看见 crew",深度的项目编排 / 驾驶舱在 PendingCrew;人侧的轻量提要是 PendingBot 的 [todolist](../../pendingbot/concepts/todolist.md)(机器视角 vs 人视角,配对)。

## 注意

- ⚠️ **当前账本是「仓库级一份」,本就该这样——per-crew 是过滤视图不是存储切分。** `docs/tech-debt/` / `docs/progress.md` / task 现在整个仓库共用一份;"一 crew 一份"指的是**显示层沿 DAG 切片**(#439 落地时才切),**不是**把账本拆成多份存。别把"per-crew"理解成"每 crew 一个独立仓库 / 一套独立账本"。
- ⚠️ **格式正从 emoji 状态迁向 frontmatter** —— 驾驶舱靠读 frontmatter(`status:`)渲染状态色块,所以现状那本的状态得先从 emoji 迁成 frontmatter(见 [对账](reconciliation.md))。这步与驾驶舱本身都还没落地。
- ⚠️ **"项目 / 驾驶舱"当前都还没实现** —— crew 的父子 DAG 已经有(见 [DAG](dag-and-responsibility.md)),但"沿子树聚合成驾驶舱 + 看板渲染两本 + 控制半边生 session"整个是规划。别把 DAG 已实现当成驾驶舱已实现。
