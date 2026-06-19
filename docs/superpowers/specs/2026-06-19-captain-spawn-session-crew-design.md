# Captain 自主新建 session / 子 crew — 设计

- **日期**: 2026-06-19
- **分支**: `feat/captain-spawn`
- **状态**: 设计已批准,待写实现计划
- **范围**: 本地模式(BYOK/local)。登录态/edge 路是将来 relay block 3 的事,本次不碰。

## 背景 / 问题

机长(captain)是一个本地跑的 coding agent session(claude PTY / codex app-server),通过 `apps/pendingcrew/Sources/Mcp/McpServer.swift` 的 MCP 工具与外界交互。它目前的自主能力只有:`post_to_crew` / `read_whiteboard` / `ask`(通用)+ `answer_decision` / `rename_crew`(机长专用)。

两个缺口:

1. **`start_session` prompt/实装漂移**(已记 [docs/tech-debt.md:61](../../tech-debt.md)):`crew-captain.zh.md` 已经教机长用 `start_session(brief, runner?)` 把明确编码任务排队,但 McpServer **没这个工具** —— 机长调了会收到「未知工具」。
2. **建子 crew 无程序入口**:本地子 crew 链路对 UI 全是现成的(`LocalCrewStore.attachParent` 已禁环、`CreateCrewSheet(parentCrewId:)`、`CrewDetailInspector` 的「新建子 crew」按钮),schema 甚至预留了第 4 种 captain 来源 `spawned_by_captain`,但机长没有对应工具。

用户诉求:机长能**自主**(无需人类逐次确认)新建「以当前 crew 为父的子 crew」和「当前 crew 里的新 session」。

## 目标 / 非目标

**目标**
- 给机长两个专用 MCP 工具:`start_session` 与 `create_child_crew`,在本地模式下端到端可用。
- 全自主:机长判断后直接执行,不走人类确认。配可见性 + 可停 + 子 crew 深度护栏。
- 清掉 tech-debt:61 的 prompt/实装漂移。

**非目标**
- edge / 登录态路径(走 `create_child_crew_inheriting_responsibility` RPC + bot 鉴权 + relay)。本地模式只记结构父边,不做 responsibility 分摊继承。
- 机长空闲超时回收 / 自动起的 per-crew 开关(既有 tech-debt:132,本次不一并解决)。
- 跨设备遥控建 session(那是 relay `task_request` + hub 的范畴)。

## 设计基准与方案选择

**唯一合身的方案:照搬 `rename_crew` 的控制通道模式。**

机长的 MCP helper 是**离线子进程**(`McpHelperMain` re-exec,带 `--mcp-serve`),碰不到运行中的 app 进程,也不联网,只能读写 `--dir` 下的共享文件。`rename_crew` 就是靠这个:工具把一条 `CrewMetaChange` 写进 `<crewId>.crewmeta.json`,app 侧 `CrewStore` 靠目录监听感知 → 排空 → 落地到 `LocalCrewStore.setTitle`。

新两个工具沿用同一管道:**工具写请求文件 → `CrewStore` 排空 → 执行(起 session / 建子 crew)**。

被否的替代:
- ❌ 给 helper 开 IPC/XPC 直连 app:helper 现为纯文件离线设计,为此引 IPC 太重,破坏既有模型。
- ❌ 走 edge RPC:当前 crew 是本地 `local-<uuid>`,机长无 edge 鉴权,依赖未完成的 relay block 3。属将来登录态路径。

## 组件设计

### 1. 两个机长专用工具(McpServer.swift)

在 `tools/list` 的 `isCaptain` 分支注册(worker session 看不到也调不动,与 `answer_decision`/`rename_crew` 一致):

```
start_session(brief: string, runner?: "claude"|"codex", isolation?: boolean)
create_child_crew(brief: string, title?: string)
```

「当前 crew」隐含 = helper 启动时带的 `crewId`,机长无需指定。工具 handler 把请求写入命令通道(下条),立即乐观返回(与 `rename_crew` 一致),不阻塞 turn。

### 2. 命令通道(队列,扩展现有 control store)

`rename_crew` 是 last-write-wins 单文件;起 session / 建子 crew 是**可重复**动作(机长可能连起多个),所以用**队列**:

- 每条请求一个独立文件:`<crewId>.<uuid>.crewcmd.json`,内容 `CrewCommand { kind: "start_session" | "create_child_crew", payload, ts }`。
- 与 `.crewmeta.json`(rename)/`.json`(白板)/`.approvals.json` 后缀不同,不冲突;共用 `LocalWhiteboardStore.defaultDirectory`,写盘即触发 app 的 `directoryChanged`。
- 实现:扩展 `LocalCrewControlStore` 增 `enqueueCommand(...)` / `drainCommands() -> [CrewCommand]`(各自删文件),或并列一个 `LocalCrewCommandStore`(实现时定,二选一,行为同)。
- durable:app 没在跑就先躺文件,下个 tick 捡;app↔helper 并发沿用既有 last-write-wins/各文件独立的低频可接受 tech-debt。

### 3. `start_session` 执行(app 侧)

`CrewStore` 排空到一条 `start_session` 命令时:

- **复用现成 worker 启动路**:`CrewRelayAgent.handleTaskRequest` 已有「请求 → 本地起 session」成套逻辑(kind → isolation workdir → 世界观 → 本地 comms,**不带** `--captain`)。抽出可复用的「按 (brief, kind, isolation) 起 worker session」例程,命令通道与 relay 共用。
- `brief` → `initialPrompt` / `taskBrief`;工作目录继承 crew(`LocalCrew.workingDirectory`)。
- **runner**:留空 → crew 的 `captainAgentKind`(无则默认 codex);`"claude"`/`"codex"` 覆盖。
- **isolation**:可选,**默认 off = 共享 crew 目录**(与机长自身一致、不堆分支)。传 `true` → 独立 worktree + 新分支(`SessionWorkspace.resolve`;非 git repo 自动退回共享)。
- 新 session 启动后自己会 `post_to_crew` 报到,机长就看到了。

### 4. `create_child_crew` 执行(app 侧)

`CrewStore` 排空到一条 `create_child_crew` 命令时:

- 复用现成本地子 crew 链路:`LocalCrewStore.createCrew` + `attachParent`(已禁环)。
- **继承**父 crew:工作目录、`captainAgentKind`、machine(本地)。机长只给 `brief`(干什么)+ 可选 `title`(不给 → 地名占位,子机长自己 `rename_crew`)。
- 子 crew **自动起自己的机长**(复用 `captainAutostartRequest` 流;对应 schema `spawned_by_captain` 语义)。`brief` 作为子机长开场任务。
- 本地模式只记**结构父边**(DAG 展示用);responsibility 分摊继承是 edge-only,本次不碰。
- 执行后往**父 crew 白板**回一条「已建子 crew「X」」系统消息,让父机长 + 人类知道。

### 5. 自主与安全护栏

对应用户选定的「全自主直接执行」:

- **可见**:新 session / 子 crew 立即出现在侧栏 + 群聊,与手动建的一样。
- **可停**:沿用既有停 session / 停机长入口。
- **子 crew 深度上限**:子机长能再建孙 crew → 可能递归。深度 cap **默认 3**(根 crew 记为 depth 0,即最长链 `根→c1→c2→c3`):执行 `create_child_crew` 前算当前 crew 的父边深度 `d`,若 `d + 1 > 3`(当前已在 depth 3)则工具回错误(机长收到「已达子 crew 深度上限」),不建。配合 `attachParent` 既有禁环。

### 6. Prompt 更新(crew-captain.zh.md)

- 补 `create_child_crew(brief, title?)` 用法 + 何时用:**只在「一块事大到该独立成组、要有自己的机长和群聊」时拆子 crew,别滥拆**。
- `start_session` 措辞跟实际参数(含可选 `isolation`)对齐。
- 清掉 tech-debt:61 的漂移记录。

## 数据流(机长建 session 为例)

```
captain agent 调 start_session(brief, runner?, isolation?)
  → McpServer handler(isCaptain 校验)
  → LocalCrewControlStore.enqueueCommand(<crewId>.<uuid>.crewcmd.json)
  → 工具乐观返回「已起 session」
       ↓ (写盘触发 directoryChanged)
  CrewStore 目录监听 tick → drainCommands()
  → 取 crewId 的 CrewDetail(工作目录/captainAgentKind)
  → 复用 worker 启动例程 (kind→isolation workdir→世界观→comms, 不带 --captain)
  → CrewSessionRunner.start(role: .worker, taskBrief: brief)
       ↓
  worker session spawn → post_to_crew 报到 → 群聊 + 侧栏可见
```

建子 crew 类似:drain → `LocalCrewStore.createCrew` + `attachParent` + 置 `captainAutostartRequest`(子机长自动起)+ 父白板回执。

## 错误处理

- `start_session`:crew 无工作目录 → 工具回错误;并发护栏沿用 runner 既有;非 git repo + isolation=true → `SessionWorkspace` 既有的优雅退回共享目录。
- `create_child_crew`:深度超限 → 工具回错误;无可继承的工作目录 → 错误。
- 命令通道:app 未运行 → 请求文件留存,下次启动/下个 tick 执行(durable)。非机长 session 调这两个工具 → `tools/list` 根本不暴露,`tools/call` 再加 `isCaptain` 守卫回错误。

## 测试

- 命令通道队列写入/排空单测(仿现有 `LocalCrewControlStore` 改名测)。
- 子 crew 深度 cap 逻辑单测。
- drain → 执行接线(mock runner / mock store):`start_session` 调到 `runner.start`(role=.worker、brief 透传、runner/isolation 默认与覆盖);`create_child_crew` 调到 `createCrew + attachParent + captainAutostartRequest` 且深度超限被拦。
- `xcodebuild` Mac build。
- **真机活验记为尾巴**(同既有 captain 真机尾巴):真起 claude/codex worker、真建子 crew 看子机长自动报到。

## 待办 / 推迟

- edge / 登录态路径(`create_child_crew_inheriting_responsibility` + bot 鉴权 + relay 同步)。
- 机长空闲回收 / 自动起 per-crew 开关(tech-debt:132)。
- 子 crew 深度 cap 是否要做成可配置(先硬编码 3)。
