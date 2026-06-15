# PendingCrew — 侧栏按 machine 组织（设计）

- 日期：2026-06-15
- 分支：`feat/sidebar-by-machine`
- 状态：设计已与用户对齐，待写实现计划
- 前置：[2026-06-14 machine 概念 + 新建流程](./2026-06-14-pendingcrew-machine-and-create-flow-design.md)

## 目标

把 Mac 侧栏从「**Crew** 一段（平铺 DAG 树）+ **Machines** 一段（死占位）」改成
**按机器分组**：每台机器是一个分组，crew 挂在它所属机器的组里。同时把这个分组
真正接通数据层——让多机器是真的，不是占位。

## 背景与一次模型纠偏

用户原始诉求：侧栏不要「crew 和 machine」两段并列，而要 machine 当组织容器、
crew 住在机器组里。

讨论中纠正了一个我先前的误判：**macOS 上 backend 已经恒为 `LocalBackend`**
（`AppModel.backend`，6-10「接合 v2：本地为家」定的）——登录只是 `isAuthenticated`
能力叠加，**不切数据源、本地 crew 不会因登录消失**。先前担心的「登录后看不到本地
crew」是 iOS 路径（iOS 无本地后端才走 EdgeBackend），Mac 上不存在。

但用户模型的另一半在 Mac 上是**空转**的。登录本应做两件事——把本机注册进账号、
拿到访问账号其它机器的权限——`PendingCrewApp` 登录时确实调了
`registerSelfMachine()` / `refreshMachines()`，但因为 backend 恒是 `LocalBackend`：

- `registerSelfMachine()` → **no-op**（没真往 edge `POST /v1/machines/register-self` 注册）
- `listMachines()` → 只返回**合成的「本机」一台**（从不调 `GET /v1/machines`）
- `listCrews()` → 只读本地

所以「按机器分组」在 Mac 今天只有「本机」一个组可分——多机器读取链路压根没接。
machine 表 / edge 端点都建好了（#335-339），Mac 客户端没用上。

## 心智模型（定调）

**每台机器对自己的 crew 本地优先；账号层共享的是「机器清单」，不是 crew。**

| 概念 | 归属 | 说明 |
|---|---|---|
| 某机器的 crew | **该机器本地** | 本机 crew 在 `LocalCrewStore`，本机 runner 跑。**不**镜像进 edge（用户明确否决「登录即上云」）。 |
| 机器清单（machine 表） | **账号级 / edge** | 登录后每台设备真注册自己 + 真拉账号全部机器。RLS 限本账号。 |
| 跨机器看/控别人的 crew | **遥控（relay）** | iPad → 本机 等。不是 edge crew-mirror，是按需遥控。属 #242 轨，本任务只把"机器可被寻址"做实，不做遥控投影。 |

登录 = 拿到访问账号其它机器的权限 + 把本机注册进账号。
登出 = 账号不再持有本机（本机 crew 本地照旧在，只是账号视角看不到这台机器了）。

## 数据层（让机器组是真的）

机器是账号概念（edge），crew 是本地概念——所以这两件事**分开走**，不强塞进单一
backend 抽象：

1. **真注册本机**：`CrewStore.registerSelfMachine()` 在 `isAuthenticated` 时走
   **edge** `POST /v1/machines/register-self`（用 `AppModel.loggedAPIClient()`），
   不再落 `LocalBackend` 的 no-op。未登录则跳过。
2. **真拉机器清单**：`CrewStore.refreshMachines()` 在 `isAuthenticated` 时
   `GET /v1/machines`，与「本机」去重合并（本机 = `deviceId == DeviceIdentity.current`
   的那行；edge 已返回它即用 edge 行，否则补合成本机）。未登录 = 仅合成「本机」。
   失败静默回落「本机」（不挡用）。
   - 这两个 account-level 操作**绕开 crew backend**，crew 数据源仍是 `LocalBackend`
     （home 不变）。
3. **crew 数据源不变**：仍走 `backend.listCrews()`（Mac = 本地）。本机 crew 全部
   归到「本机」组。
4. **per-crew machineId（前向兼容、低优先）**：`CrewSummary` 加 `machineId: String?`
   （decoder 缺键兜 nil），`LocalCrewStore.summary` 透传已有的 `LocalCrew.machineId`。
   分组键统一成「crew.machineId 解析到的机器，nil → 本机」。edge `GET /v1/crews`
   返回 `machine_id` 留给后续遥控投影 / iPad（本任务 Mac 不读 edge crew，可不动 edge，
   但契约上补一行 map 也无害——计划里标为可选尾巴）。

## 侧栏 IA（`CrewSidebarView` 重构）

去掉现有「Crew」单 section + 占位「Machines」section，改成**每台机器一个可折叠
section**：

- **机器分组**：来自 `refreshMachines()` 的合并清单。排序：**本机置顶** → 其它
  computer(peer) → fly；同类按 displayName。**含空机器**（没 crew 也显示，用户选定）。
- **section header**：机器图标（`desktopcomputer` / `personalhotspot` / `cloud`）+
  名称（本机带「本机」小标）+ 在线点 + 折叠箭头 + 右侧操作位。
  - **本机组**：header 带「+」→ `CreateCrewSheet` 预选本机（本地建）。
  - **其它机器组**：**暂不带「+」**（在别的机器上建 = 遥控派发，#242 未验，留后续）。
    它们是真机器、不是假占位。
- **section body**：
  - **本机组** = 本机的本地 crew，沿用现有 **DAG 折叠树**（`CrewDAGTreeView` 改成
    接受「限定子集」参数；组内根 = 子集里无父或父不在本组的 crew，childMap 限定在
    子集内）。
  - **其它机器组** = 本机上看不到其 crew 内容（local-first，没 edge-mirror）→ 一行灰
    提示「在该机器上 · 遥控查看（稍后）」。**不**伪造 crew 列表。
  - **空的本机组** → 灰提示「还没有 crew · 点 + 新建」。
- **折叠态**：`@State Set<String>`（按 machine.id），默认展开。
- **选中 / footer / 工具栏全局「+」/ 刷新**：不动。
- **去掉每行的 本机/云端 location tag**：被组头取代，冗余。
- **解析不到机器的 crew**：落末尾「其它」桶，仅非空时出现（防脏数据）。

## 分组逻辑（纯函数 helper，可单测，跨平台可复用）

输入 `crews`、`machines`、本机 deviceId；输出有序 `[(machine, rootCrews)]` + 可选
「其它」桶。规则见上（解析、排序、组内根）。放到平台无关文件，iPad 后续复用。

## 范围 / 非目标

**本次做**：
- Mac：`registerSelfMachine` / `refreshMachines` 真接 edge；侧栏按机器分组；
  分组 helper + 单测；`CreateCrewSheet` 接受预选 machineId（本机组「+」用）。
- `CrewSummary.machineId` + `LocalCrewStore` 透传（分组键统一）。

**非目标（留后续 / 别的轨）**：
- **遥控投影**：在 Mac 上看/控其它机器的 crew 内容（属 #242 遥控 v1，E2E 未验）。
- **遥控建 crew**：在其它机器上新建（其它机器组暂不带「+」）。
- **本机 crew 上云 / 跨设备 crew 同步**：用户明确否决「登录即上云」。
- **iPad 侧栏**：iPad 是另一套 `CrewListView`/`IPadShell`；分组 helper 写成可复用，
  iPad 改造留后续。本任务只保证数据层（注册 + 机器清单）对 iPad 遥控不挖坑。
- **fly 开通 / 计费**：只在机器清单里显示，不做开通。

## 影响面

- `apps/pendingcrew/Sources/Stores/CrewStore.swift` — `registerSelfMachine` /
  `refreshMachines` 改走 edge（authed 时），合并去重本机。
- `apps/pendingcrew/Sources/Models/CrewSummary.swift` — 加 `machineId`。
- `apps/pendingcrew/Sources/Stores/LocalCrewStore.swift` — `summary` 透传 machineId。
- `apps/pendingcrew/Sources/Mac/Views/CrewSidebarView.swift` — 机器分组布局，
  去占位 section，机器 header（图标/名/在线点/本机「+」/折叠）。
- `apps/pendingcrew/Sources/Mac/Views/CrewDAGTreeView.swift` — 接受限定子集。
- 新增 `MachineGrouping`（纯函数 helper）+ 单测。
- `apps/pendingcrew/Sources/Mac/Views/CreateCrewSheet.swift` — 可选预选 machineId。
- （可选尾巴）`apps/edge/src/routes/crews.ts` — `GET /v1/crews` 返回 `machineId`。

## 验证

- 分组 helper：单测（nil→本机；匹配 id→对应机器；空机器仍出组；本机置顶；
  解析不到→其它桶）。
- Mac：`xcodebuild ... -destination 'platform=macOS' build`；起 app 实测——未登录一个
  本机组裹现有 DAG 树；（若有账号 + 第二台机器）登录后出现其它机器组（空内容 + 遥控
  提示）；本机组「+」能建、其它组无「+」。
- edge（若动可选尾巴）：typecheck + vitest。
- 账本：对账 #342（crew-machine 模拟器实测）相关条目；新增 tech-debt 若有（如其它机器组
  内容留空是已知缺口，指向遥控投影 #242）。
