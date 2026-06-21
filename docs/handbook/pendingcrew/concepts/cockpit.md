# 驾驶舱(cockpit)

> ⬜ 规划概念(task #439)。**每个 crew 都有一个驾驶舱(它的 dashboard)**,聚合「这个 crew + DAG 里它以下整个子树」的 文档 / task / 进度 / tech-debt / roadmap / 责任地图,**既是看板也是控制面**:你在文档上编辑,改动以 chip 的形式冒出来,一键派给子树里的 crew 去把代码对齐。本质 = 把规范驱动开发(SDD)做成多 agent 的递归项目协作台。相关:[Crew 与 Captain](crew.md) · [DAG 与责任比例](dag-and-responsibility.md) · [人在回路](human-in-the-loop.md)。

## 逻辑

**每个 crew 一个驾驶舱,递归向下。** 驾驶舱不是某个独立的"项目页",而是**挂在每个 crew 上的 dashboard**,它的视野 = 自己 + DAG 里它以下的整个子树:
- 叶子 crew 的驾驶舱 = 只有自己;
- 顶层 crew 的驾驶舱 = 它下面整个连通分量(这就是"项目级"总览);
- 中间任何 crew = 自己 + 下面的子树。

所以"项目"(= 一个连通分量,见 [DAG](dag-and-responsibility.md))不需要一个独立实体——你通过某个 crew 的驾驶舱往下看,看到的就是那一坨。

**crew = 账本所有者。** 每个 crew 持有自己那一份:文档子树 + task + 进度 + tech-debt + roadmap(计划 / 顺序 / 依赖)(结构化、住在 crew 的工作目录里)。驾驶舱**只聚合呈现**子树里各 crew 的账本,自己不另存——所以连边 / 断边(改 DAG)无损,内容永远挂在最小单位 crew 上。

**既是看板,也是控制面(两者一体)。** 同一个面里:
- **看板半边**:文档树、task 看板、进度 rollup、tech-debt 列表、crew 责任地图(沿 DAG)——一眼看清这个子树到哪了、谁负责什么、有哪些债;
- **控制半边**:你在文档 / spec 上编辑,系统把「文档意图 vs 代码现状」的差(drift)以 **chip** 的形式冒出来,一键就把这块活派给拥有它的 crew 去对齐。

**drift 走 chip,不是静态列表。** 每篇文档带状态(✅已落地 / 🟨部分 / ⬜规划)和「实现于」指针。文档被编辑、或被手动标「待对齐」、或 agent 发现该做的活 → 驾驶舱冒一张 **chip**(标题 = 要干的事,自带够 cold-start 的上下文)。你或 captain:
- **一键派活** → 在子树里拥有这块的 crew 起一个 session,chip 的内容作 brief;session 把代码对齐 → 完成回填状态 ✅,chip 消失;
- 或 **忽略** 掉。

(这套就是 spawn_task chip 的产品形态——把"该做、但出当前范围的活"甩成一个独立 session——挪进 crew 的驾驶舱。)

## 为什么

- **递归 / per-crew,而不是单独的"项目层"** —— DAG 本就是层级,每个 crew 天然有"我和我下面"这个范围。把驾驶舱挂在每个 crew 上、看自己子树,既不用造"项目"这个一等实体,又让任意粒度(从单个 crew 到整个连通分量)都有一致的总览。顶层 crew 的驾驶舱自动就是"项目仪表盘"。
- **项目级零存储,组织可自由重组而不丢东西** —— 内容永远挂在 crew 上,驾驶舱只是"当前怎么把子树归堆"的派生视图。连边断边只改"怎么看",不改"存了什么"。这是"协作体随时建随时拆"那套轻量心智的延伸。
- **看板 + 控制一体,才是 SDD 的多 agent 版** —— 单人用 spec→plan→task→实现已经很顺;驾驶舱把它扩到"多 crew 各管一块、各有自己的 spec 与账本,在一个 dashboard 下既看全貌、又能在文档上编辑即派活"。文档是意图源、crew 是执行 agent、chip 是派活的扳机。
- **半自动而非全自动** —— 改文档不自动起一堆 agent(易失控),而是冒 chip、人 / captain 一键派。human-in-loop 卡在 planning,跟 PendingCrew「[交互非审批](human-in-the-loop.md)」一脉相承。
- **递归自指是试金石** —— 大绿豆自己这本 handbook + 配套账本,就是驾驶舱要渲染 / 管理的东西的原型;先把数据形状(结构化文档 + 一债一文件的 tech-debt + 进度 rollup + task)对齐,等驾驶舱建起来直接能渲染。

## 用在哪 · 长什么样(规划)

- **入口**:任意 crew 的详情 / 侧栏有个「驾驶舱」视图,进去就是这个 crew + 它子树的聚合面。
- **看板**:文档树(可点开各 crew 的 spec)、汇总 task 看板(按 crew / 状态)、进度 rollup、tech-debt 列表、**roadmap 面板**(计划 / 顺序 / 依赖)、DAG 责任地图。
- **drift chip 区**:一串待办 chip,每张写清"要把哪块对齐 / 该做什么 + 派给谁",一键派活或忽略。
- **编辑即驱动**:在文档上改一笔 → 对应 chip 冒出来 → 一键 → 子树里那个 crew 起 session 干 → 干完状态回绿、chip 消。

## 示例(规划)

你在「鉴权重构」crew 的驾驶舱里,看到它下面有两个子 crew(edge 侧、iOS 侧),task / 债都汇总在一屏。你打开 edge 侧那篇 `登录-spec`,把"OTP 改成 6 位"这条意图改了 → 驾驶舱立刻冒一张 chip:「edge:登录改 6 位 OTP(spec 已改、代码未对齐)· 派给 edge-crew」。你一键 → edge-crew 起一个 session、拿这条 spec 作 brief 去改 → 改完 chip 消失、那篇 spec 状态回 ✅。整个过程你没离开驾驶舱、没手写一句 prompt。

## 边界

- **驾驶舱不是实体,项目不单独存储** —— 永远是"某个 crew + 其子树"的派生视图。任何"项目表 / 项目级字段"的设计都与此冲突。
- **本篇只定模型**(per-crew 递归驾驶舱 + crew 持账本 + 看板 / 控制一体 + drift 走 chip 一键派),不定具体 UI / schema / drift 检测算法——真动工(#439)时再设计。
- **半自动,不自动起活** —— 改文档不直接起 session;一律先冒 chip、人一键。
- 这是 **PendingCrew** 的 feature —— PendingBot 只"看见 crew",深度的项目编排 / 驾驶舱在 PendingCrew。

## 注意

- ⚠️ **当前账本是「仓库级一份」,不是「一 crew 一份」。** `docs/tech-debt.md` / `docs/progress.md` / roadmap / task 系统现在整个仓库共用一份;「一 crew 一份」是本概念(#439)落地时才切的。格式**计划**往「一债一文件 + frontmatter」对齐(为可渲染做准备),但这步也还没落地。
- ⚠️ **"项目 / 驾驶舱"当前都还没实现** —— crew 的父子 DAG 已经有(见 [DAG](dag-and-responsibility.md)),但"把子树聚合成驾驶舱 + drift chip 派活"整个是规划。别把 DAG 已实现当成驾驶舱已实现。
- **drift 检测的难点留到实装**:"文档意图 vs 代码现状有没有差"本身不好判;MVP 先用 文档状态标记 + 手动「标记待对齐」+ git 改动当 drift 信号,自动判 drift(让 agent 比对意图与代码)是后话。

## 现状

⬜ **规划(task #439)。** 模型已拍定(per-crew 递归驾驶舱 + crew 持账本 + 看板 / 控制一体 + 项目 = 连通分量纯派生 + drift 走 chip 一键派 + 本质多 agent SDD)。**MVP 设想**:每个 crew 一个驾驶舱,聚合自己子树的 文档树 / task / tech-debt / crew-map(看板半边)+ drift chip 一键派活(最简驱动:状态标记 + 手动「标记待对齐」+ 一键派,先不做自动 drift 检测)。dashboard / 渲染 / per-crew 账本切分 / chip 派活编排**均未实现**。
