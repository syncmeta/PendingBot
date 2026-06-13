# PendingCrew — session 窗口改 inspector + 解开新建 session

设计日期：2026-06-13 · 平台：macOS（`#if os(macOS)`，iPad/iOS 不涉及本次）

## 背景与问题

PendingCrew Mac 端现为三栏 `NavigationSplitView`：`侧栏(crew 列表) | 中栏(群聊 CrewChatView) | 右栏(常驻 session 终端 CrewSessionWindowView)`。两个用户痛点：

1. **右栏常驻不合心智**。用户希望 session 终端不是一个永远占着的栏，而是「点击群内 session 头像才看到」的详情子窗——即一个按需弹出的侧边栏 / inspector。
2. **「建了一个 session 就不能再建新的」**。底层 `CrewSessionRunner` 其实早已支持多 run 并存（`runs: [CrewSessionRun]`，`maxConcurrentRuns = 6`），但右栏 UI 没有「新建 session」入口：composer 的 `send()` 逻辑是「有 running 的 current → 注入当前 session；否则 → 开新 session」。一旦有 session 在跑，发消息永远注入它，开不出第二个。唯一的开新入口是「⚓ 启动 Captain」（每 crew 限一个）。

附带现实：本地 PTY session **当前不在群聊 roster 头像里**——`PendingCrewBackend.listCrewMembers`（本地路径）只返回 captain + 本机人类，注释明写「本地 session 成员留 chunk 4」。本地 session 唯一可视表示是右栏的「切换条 capsule」。要兑现「点 session 头像看详情」，必须先把本地 running session surface 成群聊里的头像。

## 设计

### 1. 三栏 → 两栏 + 原生 inspector

- `MacThreePaneView` 改为两栏 `NavigationSplitView`：`侧栏 | 中栏(群聊)`。删除常驻右栏。
- session 终端整套（切换条 + 终端 + composer + 内联审批卡片，即现 `CrewSessionWindowView` 全部内容）搬进 macOS 14 原生 `.inspector(isPresented:)`，挂在中栏（或 split view）上，按需弹出/收起。
- inspector 的呈现状态 `inspectorPresented: Bool` 提升到 `MacThreePaneView`，与 `sessionRunner`（已持有 `selectedRunId`）一起经 `@EnvironmentObject` / binding 下传。

### 2. 群聊 roster surface 本地 session 头像

- `CrewChatView` 渲染 roster 时，把 `sessionRunner.runs`（当前 crew 的本地 run）合进头像条——兑现 chunk-4 TODO。本地 run 映射成 `CrewSender(kind: .session, sessionStatus: running/exited)`，captain run 标 captain。
- 数据来源仍是 `listCrewMembers` 的 server/本地成员；本地 run 作为**额外**头像并入（避免依赖 server 注册）。去重：若某 server `code_session` member 的 `codeSessionId` 等于本地 run 的 `sessionId`，合并显示（不重复）。
- roster 头像可点：tap 某 session 头像 → `sessionRunner.select(run.runID)` + `inspectorPresented = true`。tap 非 session 头像（人/bot）暂不开 inspector（保持现状无操作）。

### 3. 新建 session 入口（解决问题 2）

- roster 头像条末尾加一个 `+` chip：tap → 进入「新 session」模式（见下）+ 打开 inspector。
- inspector 内切换条同样保留一个 `+`（与 roster 的 `+` 同语义）。
- 「⚓ 启动 Captain」保留在 inspector 切换条。
- 顶部 toolbar 加一个 inspector 开关按钮（`Label("Session", systemImage: "sidebar.trailing")`，可挂 ⌘⌥S）作兜底入口。

**「新 session」模式实现**：在 `CrewSessionWindowView`（inspector 内容）加 `@State composingNew: Bool`。
- `+` → `composingNew = true`（并开 inspector）。
- 终端内容区：`composingNew == true` 时显示 idle/新建态（kind picker + 「下第一条指令开始…」），而非当前 run。
- `send()`：`if composingNew || current == nil || current?.status != .running { startSession }`，否则注入 current。`startSession` 成功后 `composingNew = false`（新 run 已被 `runner.start` 追加并选中，自然显示）。
- composer 顶部 kind picker 的显隐条件由 `!isRunning` 改为 `composingNew || !isRunning`。

### 4. 边界 / 不在范围

- auto-claim 不动：当前整体关闭（`edgeQueueBindingReady = false`，等 block-3 信箱绑定），且 runner 已有 6 并发上限。
- 跨设备 / iPad / iOS 不涉及（session 终端是 macOS-only）。
- 不引入独立 `Window` 场景——用原生 `.inspector` 即满足「侧边栏详情」诉求，窗口管理成本最低。

## 验证

- `cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build` 通过。
- 改 `project.yml` 的话先 `xcodegen`（本次预计不动 project.yml）。
- 人工冒烟（需用户在场跑 GUI）：开 crew → 群聊 roster 出现 session 头像 → 点头像弹 inspector 显终端 → `+` 开第二个 session → 两个 session 并存可切换。GUI 冒烟记入 tech-debt 待用户真机确认。
