# PendingCrew — machine 概念 + 新建流程精简（设计）

- 日期：2026-06-14
- 分支：`feat/crew-machine`
- 状态：设计已与用户对齐，待落实现计划

## 背景与目标

PendingCrew 当前把"crew 在哪运行"建模成 `runtimeLocation` 三档枚举（`local_host` / `peer_device` / `fly_machine`），新建表单字段繁琐（标题、代表 subject、runtime、工作目录、标签、机长设置），其中多项是噪音。本设计把"运行位置"升级成一等的 **machine**（机器）概念，并把新建 crew 流程砍到极简。

核心决策（均经用户确认）：

1. **machine 是一张 Supabase 表**，本机是其中一台。`peer_device` 不删——它是给 iPad 准备的（iPad 远程操控已登录的电脑）；`fly_machine` 是云机器。三类机器统一进 machine 表。
2. machine 表 **RLS 仅限本账号**：只能看/管自己的机器。
3. **未登录时只有本机一台**，不显示 machine 选择，也不走任何本地机器表。
4. 新建表单精简成：标题（可选/自动）+ machine（登录且多机时才显示）+ 工作目录（三选一）。
5. **标签（tag）连根删除**，其"同项目归一类"的本职改用 **父 crew** 承载。
6. crew 由 `runtimeLocation` 枚举 + `peer_device_id` + `fly_machine_id` 三列，收口成单个 `machine_id` FK。
7. **一次全做**（不分阶段）。

## machine 概念

### 表结构 `pendingbot.machine`

| 列 | 类型 | 说明 |
|---|---|---|
| `id` | uuid PK | |
| `subject_id` | uuid FK → subjects | 归属（本人账号） |
| `kind` | text | `computer` \| `fly` |
| `device_id` | text null | 电脑的稳定安装标识（fly 行为 null）；与 `subject_id` 唯一 |
| `display_name` | text | 显示名（"我的 MacBook" / fly box 名） |
| `fly_machine_id` | text null | fly 行专用 |
| `last_seen_at` | timestamptz null | 在线判断（给 iPad 遥控） |
| `status` | text null | 可选：online/offline 等 |
| `created_at` / `updated_at` | timestamptz | |

约束：`unique(subject_id, device_id)`（同账号同设备只一行）。

### RLS

- `select` / `insert` / `update` / `delete` 全部限制 `subject_id` 属于当前用户（与现有 subject 体系一致：本人 subject 或本人为成员的群 subject——本表只挂本人 subject，不挂群）。
- 别的账号既看不到也改不到。peer 遥控只发生在同一账号的多台设备之间。

### 派生语义（不存死枚举）

- **本机** = `device_id == 当前设备标识` 的那行。
- **peer** = 其它 `kind=computer` 行（iPad 可遥控的已登录电脑）。
- **fly** = `kind=fly` 行。

### 设备注册

- Mac/iPad 登录 PendingBot 后，**upsert 自己这行**（按 `(subject_id, device_id)`，`kind=computer`，写 `display_name` + `last_seen_at`）。
- 设备标识复用 app 已有的稳定 device id（与 `user_devices` 同源，实现期确认）。

### crew 引用机器

- crew 表去掉 `runtime_location` / `peer_device_id` / `fly_machine_id` 三列，新增 `machine_id uuid null FK → machine`。
- `machine_id` 为 null ＝ 本机/本地（未登录或显式本机）。
- 迁移把存量 crew 的旧三列折算：`local_host` → null（或本机行）；`peer_device`/`fly_machine` → 对应 machine 行（存量预发阶段数据可忽略，按预发单环境处理）。

## 新建 crew 表单（精简后）

字段顺序：

1. **标题** — 可选，带"自动"档。
   - 选"自动"：建时 title 留空，**以后由 captain 总结填充**。
   - 占位：列表/标题位在 title 为空时显示"未命名"。
2. **machine** — *仅当已登录且机器数 > 1 时显示*；默认本机。未登录或只有本机 → 不显示该字段，crew `machine_id = null`（本机）。
3. **工作目录** — 三选一，**默认第三个**：
   - **手动选择**：NSOpenPanel 选目录。
   - **用上次的**：读 UserDefaults 持久化的"上次工作目录"；无历史则禁用/回退默认。
   - **CrewGround 开一个（默认）**：在 `~/CrewGround/` 下建 `<随机地名>` 子目录。

**移除的字段**：

- 代表 subject —— 默认本人账号（`responsibleSubjectId = 本人 subject`）。
- runtime —— 被 machine 取代。
- 标签 —— 见下，连根删。
- 机长（captain）设置区 —— captain 仍自动建（`systemGenerated` 默认，无模板），但建时不出任何配置 UI；需要时去 crew 设置里改。

### CrewGround 随机目录

- 复用既有随机地名设施：`pendingbot.random_place_name()` RPC / `GET /v1/groups/random-name`（在线、已登录时）。
- **离线/未登录兜底**：app 内置一份地名列表，本地随机抽。
- **去重**：抽到的名字若已是 `~/CrewGround/` 下的子目录则重抽（避免撞已有 crew 目录）。
- `~/CrewGround/` 不存在则创建。

### "用上次的"持久化

- 每次成功新建 crew 后，把所用工作目录写入 UserDefaults（key 如 `pendingcrew.lastWorkingDirectory`）。
- "用上次的"选项读它；无值时该选项不可用。

## 删除标签（tag）

连根拔，覆盖：

- **DB**：crew 表 drop `tag` 列（迁移 + schema regen）。
- **edge**：`crews.ts` 的 zod schema 去 `tag`；`CreateCrewRequest`/响应去 `tag`；relay 转发去 `tag`。
- **iOS/Mac 模型**：`CrewSummary` / `CrewDetail.CrewBody` / `LocalCrew` / `CreateCrewRequest` 去 `tag`。
- **UI**：`CrewListView` 副标题去 tag 拼接；`CrewDetailInspector` 去 tag Label；`CreateCrewSheet` 去 tag 输入框。

## 父 crew 承接"分类"职责

tag 的本职（同一"项目"归一类）改用父 crew：

- **crew 设置（inspector）里可指定父 crew**：同项目挂同一个父 crew。
- **进了某个 crew 后可在其内新建子 crew**（建子 crew 时自动设父 = 当前 crew）。
- 复用现有 DAG：`parentCrewIds` 已在模型里，Mac 已有 DAG 树侧栏。
- 编辑父 crew 走已有/新增的 crew 关系端点（实现期确认 edge 是否已有 set-parent 能力，没有则补）。

## 影响面清单

- **DB / 迁移**：新建 `machine` 表 + RLS + 索引；crew 表加 `machine_id`、drop 旧三列 + `tag`；折算迁移；schema regen。
- **edge**：crew 创建/读取/更新路由去 tag、去 runtime 三件套、接 `machine_id`；新增 machine 注册/列表端点（upsert self、list machines）；父 crew set 端点（按需）。
- **Mac（PendingCrew）**：登录 upsert 本机；`CreateCrewSheet` 重构；CrewGround 目录逻辑 + 上次目录持久化；inspector 加父 crew 选择；crew 内"新建子 crew"入口；去 tag；machine 选择器。
- **iPad**：machine 列表消费（遥控 peer 的基础）；登录 upsert 本机；表单同步精简。
- **离线/BYOK（未登录）路径**：machine 选择隐藏、`machine_id=null`、CrewGround 用本地兜底地名。

## 不做（YAGNI / 本次范围外）

- iPad 真正"遥控 peer 电脑执行"的字节隧道/远程执行链路（仅把 machine 列表/在线状态备好，遥控执行是后续 [project_pendingcrew_runner_direction] Phase 2 的活）。
- fly machine 的开通/计费链路（仅表结构 + 选择 UI 就位）。
- 父 crew 的高级视图（看板/分组聚合）——本次只做"指定父 + 建子"。

## 验证

- edge：`bun --filter='@pendingbot/edge' run typecheck` + vitest。
- DB：`supabase db push --linked` → `types:db` regen → typecheck。
- Mac：`xcodebuild ... -destination 'platform=macOS' build`，并进 app 实测新建流程（标题自动 / 工作目录三选 / CrewGround 真建目录 / 无 tag）。
- iPad：`-destination 'generic/platform=iOS Simulator' build`；登录后 machine 列表含本机。
- 未登录路径：新建不显示 machine、CrewGround 仍能建目录。
