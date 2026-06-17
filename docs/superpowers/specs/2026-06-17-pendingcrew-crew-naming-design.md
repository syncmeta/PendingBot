# PendingCrew — crew 自动起名 + captain 标签式改名

- **日期**：2026-06-17
- **状态**：设计定稿（决策全锁）
- **范围**：纯本地（macOS `LocalBackend`）。不碰 edge、不碰 iOS、无迁移。

## 背景

新建 crew 选「自动」标题时，本地存成占位 **「未命名 crew」**（[`LocalCrewStore.createCrew`](../../../apps/pendingcrew/Sources/Stores/LocalCrewStore.swift)）。但每次建 crew，`CreateCrewSheet` 的 `ensureCrewGroundName()` 在 `.onAppear` 已经挑好了一个随机地名（如 `Lisbon`，用于 `~/CrewGround/<地名>` 目录）——这个地名没用在标题上。

目标两件事：

1. **初始名 = 那个已挑好的随机地名**，不再是「未命名 crew」。
2. **captain 有一个改名工具**，等它搞清楚 crew 在做什么，给 crew 起一个**短标签**（概括，不是描述）。

## 架构前提（决定了为什么这么做）

- macOS 上 backend 恒 `LocalBackend`（[`AppModel.backend`](../../../apps/pendingcrew/Sources/Stores/AppModel.swift)：「本地为家，edge 是邮差」）。captain 是本机 coding agent，`CreateCrewSheet` 也是 `#if os(macOS)`。**所以 captain 碰到的每个 crew 都在 `LocalCrewStore`，没有服务端 crew 要改** → 纯本地，无 edge 端点、无迁移。
- captain 的 MCP helper（[`McpServer`](../../../apps/pendingcrew/Sources/Mcp/McpServer.swift)）是**离线子进程**，只能读写 `--dir` 下的共享文件（`LocalWhiteboardStore` / `LocalApprovalStore` 都在这个 dir）。app 靠目录监听（FSEvents `directoryChanged`）感知子进程的写。**改名必须走「helper 写共享文件 → app 监听落地」这条既有通路。**

## 决策（已锁）

| 决策 | 选择 | 理由 |
|---|---|---|
| 范围 | 纯本地 | 见上；没有服务端 crew |
| 初始名地名语言 | **英文**（复用现有 `crewground_places.txt`） | 零成本；CrewGround 目录名与标题同名；就是用户看到的「那个地名」。Mac 端无中文地名池 |
| 标签长度 | **不限长**，只 trim + 去换行 + 拒空 | 「短标签别写描述」靠工具描述 + prompt 引导，不硬截断（与用户偏好一致） |
| 改名提示 | **静默**，不发白板系统消息 | 标题变化在侧栏可见，白板不加噪音 |
| 改名权限 | captain 专用（`isCaptain` 门控） | 用户：「captain 要有改名的 tool」 |
| 覆盖人类手动名 | **软引导**：captain 一律可改，prompt 提醒「人类已起有意义的名字就别动」 | 与「软引导」length 决策一致；零额外状态字段 |
| 改名时机 | captain 自主，搞清楚后改 1–2 次别 thrash（prompt） | 标签思想 |
| 工作目录 | 改名**不动**工作目录，只改显示标题 | 目录正被 session 用，改了会断；标题↔目录改名后分叉是有意的 |

## Part A — 初始名 = 随机地名

1. [`CreateCrewSheet.submit()`](../../../apps/pendingcrew/Sources/Mac/Views/CreateCrewSheet.swift)：自动模式下 `titleValue` 从 `nil` 改成已挑好的 `crewGroundName`（`onAppear` 已填，所有工作目录模式下都有值）。
2. 标题框：自动模式从「空 + 禁用 + 占位『Captain 来取名』」改成**只读显示 `crewGroundName`** + 一行小字「Captain 之后会改成更贴切的名字」。无「换一个」按钮；想自己起名切「手动」。
3. [`LocalCrewStore.createCrew`](../../../apps/pendingcrew/Sources/Stores/LocalCrewStore.swift) 的 `"未命名 crew"` 兜底 → `PlaceNames.all.randomElement() ?? "Crew"`，保证全链路再不出现「未命名」。
4. 存量已叫「未命名 crew」的 crew 不动；captain / 用户之后可手动改。

## Part B — captain `rename_crew` 工具

### 新增 `LocalCrewControlStore`（共享文件通道）

- 新文件 `apps/pendingcrew/Sources/Stores/LocalCrewControlStore.swift`，Foundation-only、`@unchecked Sendable`，仿 `LocalApprovalStore`，编进 **app + `pendingcrew-mcp` helper + 测试** 三处。
- 与 `LocalWhiteboardStore` / `LocalApprovalStore` 共用同一个 `--dir` —— **已确认** helper 的 `--dir` = `LocalWhiteboardStore.defaultDirectory`（[`LocalSessionLaunch.swift:18`](../../../apps/pendingcrew/Sources/Mac/LocalRunner/LocalSessionLaunch.swift)），正是 app `directoryChanged` 监听的目录，所以控制文件落盘即触发 app。
- 一条待改名 = 一个文件 `<dir>/<crewId>.crewmeta.json` = `{ "title": <name>, "ts": <iso8601> }`（atomic 写，last-write-wins）。与白板 `<crewId>.json` 后缀不同，不冲突。
- 方法：
  - `requestRename(crewId:, name:)` — 写/覆盖文件。
  - `drainRenames() -> [(crewId, title)]` — 读全部 `*.crewmeta.json`，返回并删除。

### `McpServer` 新工具

- `tools/list` 在 `isCaptain` 时追加 `rename_crew`（紧跟 `answer_decision`）。
- 入参 schema：`{ name: string }`（required）。
- description（教标签思想）：「给这个 crew 起一个**短标签**——一个概括，不是一句描述。等你搞清楚它在做什么再起，例：『鉴权重构』『深色模式』『语音重连』。别写长句、别带标点。」
- handler：`name` trim + 去换行；空 → 返回 `ERROR: name 不能为空`；否则 `control.requestRename(crewId: self.crewId, name:)`，返回「已把 crew 改名为「<name>」。」
- 非 captain 调 → `ERROR: 仅机长可用`（与 `answer_decision` 同款门控）。
- `McpServer.init` 增 `control: LocalCrewControlStore` 依赖；[`McpHelperMain`](../../../apps/pendingcrew/Sources/Mcp/McpHelperMain.swift) `--mcp-serve` 分支构造 `LocalCrewControlStore(directory: dir)` 传入。

### app 落地

- [`CrewStore`](../../../apps/pendingcrew/Sources/Stores/CrewStore.swift)（owns crew 列表）加一个**全局** rename 监听（macOS）：启动时 `LocalWhiteboardStore.shared.startWatching()` 后订阅 `directoryChanged`，每 tick `LocalCrewControlStore.shared.drainRenames()`，对每条 `LocalCrewStore.shared.setTitle(crewId, title)`，然后刷新 crew 列表 → 侧栏即时更新。启动时也排空一次（兜住漏掉的 tick / 重启）。
- 现有 per-crew 的 `whiteboardChanges` 不动；这是独立的列表级订阅。

### `LocalCrewStore.setTitle`

- `LocalCrew.title` 由 `let` 改 `var`；新增 `func setTitle(_ id:, _ title:)` 改 title + `updatedAt` + persist（空 title 忽略）。
- 本地 JSON 向后兼容，无 schema migration。

### captain prompt

- [`crew-captain.zh.md`](../../../apps/pendingcrew/Resources/Prompts/crew-captain.zh.md) 加一条「给 crew 起名」：初始是占位地名；搞清楚干什么后用 `rename_crew(name)` 改成短标签（概括不是描述）；一两次就够别反复改；人类要是已经起了个有意义的名字就别动。

## 实现步骤（有序，TDD）

1. `LocalCrewStore`：`title` 改 `var` + `setTitle` + 兜底换地名。**测试**：`setTitle` 改名+持久化；`createCrew(nil title)` → 地名非「未命名」。
2. `LocalCrewControlStore`（新）。**测试**：`requestRename` 后 `drainRenames` 返回且文件删除；多 crew；同 crew 覆盖。
3. `McpServer`：`rename_crew` 工具 + handler + `control` 依赖。**测试**：captain 调 → 写 control store；非 captain → 错误；空名 → 错误；`tools/list` 含/不含。
4. `McpHelperMain`：构造并注入 `LocalCrewControlStore`。
5. `CrewStore`：全局 rename 监听 + 排空 + 刷新（macOS）。**测试**：drain→apply 逻辑确定性单测（直接调）；FSEvents 接线靠 Mac build + 手动。
6. `CreateCrewSheet`：自动模式 title 用 `crewGroundName` + 框只读显示。
7. `crew-captain.zh.md`：加命名条。
8. `project.yml`：主 `PendingCrew` target glob `Sources` 自动收新文件（app + helper 同二进制）。但 **`PendingCrewTests` 是显式文件清单**，须手动追加 `Sources/Stores/LocalCrewControlStore.swift` + `Sources/Stores/LocalCrewStore.swift` + `Sources/Stores/PlaceNames.swift`（测试 `setTitle` / 地名兜底 / control store；测试 bundle 里 `Bundle.main` 找不到 `crewground_places.txt` → `PlaceNames` 回落 `["Atlantis"]`，断言「非『未命名』」仍成立）。跑 `xcodegen` 重生工程。

## 验证

- `cd apps/pendingcrew && xcodebuild test -scheme PendingCrew -destination 'platform=macOS'`（PendingCrewTests bundle，无 Package.swift）全过。
- Mac GUI build：`xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'platform=macOS' build` 过。
- 手动：建 crew → 标题是地名（不是「未命名」）；CrewGround 模式目录名与标题一致。
- captain 真机改名 = 要起 captain session 的重路径，单测覆盖工具+落地后，作为手动尾巴（记 progress）。

## 不做 / tech-debt

- **不做**：edge 改名端点、iOS、迁移、白板改名提示、目录跟着改名、中文地名池。
- **tech-debt**：`crew-captain.zh.md` 现在提到的 `start_session(brief, runner?)` 工具在 `McpServer` 里**没实装**——prompt 引用了未实现工具。本次只在加命名条时**不**碰它，单记一条 tech-debt。
