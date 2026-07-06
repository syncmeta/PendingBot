# 驾驶舱路线段（roadmap）设计

日期：2026-07-07 · 分支：`feat/cockpit-roadmap` · 状态：待用户审

## 一句话

给对账体系加**第四本账 `docs/roadmap.md`**（期望的时间切片：先要哪块、走到哪了、当前主线是什么），驾驶舱加**第五分段「路线」**渲染它；阶段进度**不落盘**，渲染时从现状账派生。

## 定位与哲学

现有三本账都是「现在时」：期望 = 当前想要的样子，现状 = 当前实际的样子，task = 当前的活。roadmap 补时间/顺序维度，回答三个问题：

1. **接下来该做什么**（阶段划分 + 先后顺序，captain 和人看着它决定下一个 brief）
2. **走到哪一步了**（每阶段进度 = 该阶段挂的期望页在现状账里的 status 聚合）
3. **长期方向是什么**（账本开头一段主线声明，细节链接 handbook vision，不复制）

与 [cockpit.md](../../handbook/pendingcrew/concepts/cockpit.md) 边界宣言同构：**roadmap 账只存人/captain 写下的骨架与归属，进度永远是现状账的实时投影**——驾驶舱不判 drift、不自动排期、不自动翻阶段状态，只渲染 + 复用「生 session 补差」。

维护权分工（已与用户确认）：**人定骨架，captain 填血肉**。

- 人（PM）：开头主线声明、阶段划分与顺序、阶段目标、翻阶段 status 的最终拍板。
- captain / session：在对账环里顺手维护——新期望页出现时归入阶段（默认归当前 doing 阶段，拿不准问人）、条目备注、阶段条目全绿时**提议**人翻阶段状态（不自己翻）。

## 账本格式：`docs/roadmap.md`

仓库级一份（与三本账同规：per-crew 是显示层沿 DAG 切片，不是存储切分）。格式与现状账同构——裸字段行，不用 YAML frontmatter，`CockpitParser` 现有风格直接复用：

```markdown
> 路线账。阶段按文件顺序排先后；条目挂期望页 relpath；进度由驾驶舱从现状账实时派生，本文件不记进度。

当前主线一段 prose：v1 在收什么、下一步往哪看。细的愿景见 [vision](handbook 链接)，此处不复制。

## v1 收口
status: doing
target: 2026-08
目标: 本地闭环全链路真机可用，登录叠加尾巴清完。
- pendingcrew/concepts/cockpit — 路线段本身也算这阶段
- pendingcrew/concepts/local-first
- shared/features/xxx

## v1.1 远端 runner
status: planned
目标: fly machine 开通 + 遥控执行链路。
- pendingcrew/concepts/runtime-location-and-machine
```

约定：

- `## <阶段名>` 一节一阶段，**文件顺序 = 先后顺序**（不搞编号字段，挪顺序 = 改排期）。
- `status:` 词表与 task 同构：`planned / doing / done / dropped`，复用 `cockpitStatusBucket()` 直接进现有色桶（`doing` → partial 桶）。
- `target:` 可选，粗粒度（月/季），只是人给自己的锚，不做任何到期检测。
- `目标:` 一句话，阶段卡副标题。
- 条目 = 列表项，首 token 是期望页 relpath（`area/key`，与 `CockpitTopic.expectationRelpath` 同一坐标系），可选 ` — 备注`。
- 开头到第一个 `## ` 之间是 preamble（引导 blockquote + 主线 prose），MarkdownText 原样渲。

## 进度派生（不落盘）

对每个阶段：条目 relpath → 在 `CockpitData.topics` 里找同 relpath 的现状条 → `cockpitStatusBucket(topic.status)`。

- 阶段进度条 = 按桶分段的色条（视觉同 dashboard 的状态分布条）+ `done/总数` 数字。
- relpath 在现状账里**没有对应条** → 归「无现状」灰桶。这本身是信号（期望还没进对账环），照实渲染，不报错、不判 drift。
- 全部在渲染时计算（`CockpitStats` 同款纯函数 rollup），roadmap 文件里永远不出现进度数字——不会漂。

## 模型与解析（CockpitModel.swift 扩展）

```swift
struct CockpitPhaseEntry: Equatable { let relpath: String; let note: String }
struct CockpitPhase: Identifiable, Equatable {
    let name: String        // "## " 后的阶段名
    let status: String      // planned / doing / done / dropped
    let target: String      // 可空
    let goal: String        // 目标: 一句话
    let entries: [CockpitPhaseEntry]
    var id: String { name }
}
struct CockpitRoadmap: Equatable {
    let preamble: String    // 第一个 "## " 之前的 markdown 原文
    let phases: [CockpitPhase]
}
```

- `CockpitData` 加 `roadmap: CockpitRoadmap?`——文件不存在为 `nil`，路线段渲空态引导（一段说明 + 格式示例，不自动建文件）。
- `CockpitParser.parseRoadmapFile(content:) -> CockpitRoadmap`：纯 Foundation 函数，风格照抄 `parseStateFile`（`headingKey` / `field` helpers 直接复用），swiftc 可单测。
- `CockpitLoader.load` 顺手读 `docs/roadmap.md`。
- 进度 rollup 纯函数：`phaseProgress(phase, topics) -> [StatusCount]`（含「无现状」桶），单测覆盖。

## UI：第五分段「路线」

`CockpitView.Segment` 加 `case roadmap`，排在「总览」之后（总览/路线/期望/现状/任务）。

布局（单列纵向滚动，宽屏时内容列限宽居中）：

1. **preamble**：MarkdownText 渲主线声明。
2. **阶段卡列表**（文件顺序）：每卡 = 阶段名 + status 色点 + target + 目标一句话 + 派生进度色条 + 条目行列表。
3. **条目行**：期望页末段名 + 现状 status 色块 + 现状一句话 summary（无现状条则灰块「未入账」）。
   - 点击 → 跨账跳转（复用现有机制：跳期望段该页 / 现状段该条）。
   - 现状桶非 done 的行 → 行尾「⚡ 生 session 补差」，直接复用 `spawnBrief(for:)`，不新造任何机制。
4. **dashboard 联动**：总览段顶部加「当前阶段」摘要卡（第一个 `doing` 阶段的名字 + 进度条），点击切到路线段。原「模块按 area 分布」保留不动（回答的是另一个问题）。

空态：`docs/roadmap.md` 不存在时，路线段渲说明文案 + 格式示例块（可复制），引导人手建。

## captain 维护约定（世界观）

session-world-model prompt 模板加一小节（走既有 prompt 通道，不内联 const）：

- 刷现状账的同一拍看一眼 roadmap：自己刚落的期望页若不在任何阶段，归入当前 doing 阶段（拿不准 → ask 人）。
- 阶段条目全绿时向人提议翻 status，**不自己翻**；不改 preamble、不动阶段划分与顺序。
- 派活优先从当前 doing 阶段的非绿条目里挑 brief。

## 坏链的呈现（无自动断言）

> 2026-06-26 用户已撤回 reconcile-check 自动断言（「不自动检测 drift，差靠人读两本」，脚本+lefthook 门已删）。roadmap 不重建任何校验门。

- 条目 relpath 在 `docs/handbook/` 下无对应 `.md` → 条目行渲成**警示色 +「期望页不存在」**，纯呈现，靠人读后手改 roadmap。
- 未归入任何阶段的期望页不做任何报告——期望段本来就列全部页，上不上路线是人的取舍。

## 落地范围

**In scope**：`docs/roadmap.md` 首版（人写骨架，本次由用户/我按现状草一版供改）、parser + 模型 + 单测、路线段 UI + dashboard 摘要卡、spawnBrief 复用接线、世界观 prompt 小节、cockpit.md / reconciliation.md 期望页回写 roadmap 概念 + 对应现状条 + docs/tasks 账目。

**Out of scope（本期不做）**：per-crew DAG 切片视图（随驾驶舱既有切片尾巴一起）、时间轴/甘特图渲染、target 到期提醒、任何自动排期或自动翻状态、对外分享形态。

## 验证

- `xcodebuild test`（parser + 进度 rollup 单测）+ macOS build 绿。
- 模拟器/本机 GUI 自查：路线段渲真实 roadmap.md、跨账跳转、生 session 按钮出现在正确的行。
- 「生 session 补差」端到端真机活验归入 #443 GUI QA 批次（pending device QA 尾巴，不阻塞合并）。
