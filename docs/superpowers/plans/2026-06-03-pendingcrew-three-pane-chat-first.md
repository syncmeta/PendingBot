# Plan — PendingCrew Mac 三栏「群聊优先」重排（按 spec v2 §9）

**起因**：实现跑偏了 spec §9。现在中栏放的是 crew 详情/设置，右栏要先填表单（标题+初始 prompt）才有 session。用户要的是文档早已定义的形态：

| 栏 | 目标（spec §9） | 现状 | 差距 |
|---|---|---|---|
| 左 | crew 列表（像群聊列表） | `CrewSidebarView` ✓ | 基本到位 |
| 中 | **群聊会话页**（§9.1 白板+沟通渠道） | `CrewCenterView` 放 crew 详情 | **整页换成群聊**；详情挪 inspector |
| 右 | **常驻 session 交互面**（§9.3 详细 IO，像 Codex Desktop） | `CrewSessionWindowView` 显 IO，但要 `CreateSessionSheet` 表单先建 | **零配置开 session**；砍标题/初始 prompt |

外加：**所有 session 级配置上提到「建 crew」**（§8.3 工作目录已是 crew 级；runner 模式/分支等也归到建 crew）。session 启动 = 零配置，像 Claude/Codex Desktop 开新对话。

## 单元（有序，各自提交）

### A. edge：crew 级白板 GET（小）
- `get_crew_whiteboard(crew_id)` RPC 已存在，但只在 `GET /:sessionId/inbox` 里被调。加 `GET /v1/crew/:crewId/messages`（`requireSubjectAuth(['crew:read'])`）返回整白板给中栏渲染。
- typecheck + 部署。

### B. API 层（PendingCrewAPI）（中）
- `listCrewWhiteboard(crewId) -> [CrewWhiteboardEntry]`（接 A）
- `postCrewMessage(crewId, text, mentions) -> Void`（接已有 `POST /:crewId/messages`）
- 新模型 `CrewWhiteboardEntry`（id / sender / text / kind / createdAt / 卡片 payload）

### C. 中栏 = 群聊会话页（中大）
- 新 `CrewChatView`：消息时间线（白板）+ 底部 composer（输入 + @session 提及 + 发送）。轮询/realtime 刷新白板。交互卡（「Agent 在问你」）也并入这条时间线（复用 RemoteSessionsView 的 interaction 逻辑）。
- `CrewCenterView` body 从 detail → `CrewChatView`。

### D. crew 详情/设置 → inspector（中）
- 现 `CrewCenterView` 的 header/机长/父子crew/责任比例/工作目录 整体搬进一个 inspector sheet（顶栏「ⓘ 详情」按钮）。
- 「服务端 session」入口保留（或并进右栏 session 切换器）。

### E. 右栏 = 零配置常驻 session（大）
- 砍 `CreateSessionSheet`（745 行配置表单）。右栏顶部放一个「**开始 session**」按钮：用 crew 默认（工作目录 + runner kind + 权限模式）直接起，**无标题、无初始 prompt**。
- `CrewSessionWindowView` 成为常驻交互面：转写 + 底部 composer（送 prompt / steering，复用已建的 send_prompt 通道）。多 session 时顶部用切换器（segmented / dropdown），MVP 可先单 active。

### F. 建 crew 配置补全（中）✅ 核心已满足 + 一处刻意延期
- **已满足**：`CreateCrewSheet` 本就要求工作目录（`canSubmit` 守 `workingDirectory != nil`）+ captain + subject + runtimeLocation。这正是右栏零配置起 session 所需。
- **简化（不是移到 crew，是直接砍）**：原 `CreateSessionSheet` 的「工作目录模式/分支/worktree/model/权限模式」全砍 —— session 零配置用 crew 默认；runner kind 在右栏 composer 留了个轻量 claude/codex picker（像 Desktop 开新会话时选），权限模式默认 auto。
- **刻意延期（记 tech-debt）**：crew 级 `default_runner_kind` / `default_permission_mode` 列 —— 要新的共享 prod 迁移 + edge + UI，UX 增量小（picker 一下 / auto 是合理默认），重排中途不再起一轮 prod 迁移摩擦。worktree/分支隔离同样先砍，用户自己用 git 管（spec §8.3.1 本就这么说）。

## 验证门
- 每单元 typecheck（edge）/ macOS build。
- 收尾真机：左选 crew → 中群聊发消息 → 右零配置开 session → 转写出 → ask_human 交互卡在群聊/右栏闭环。

## 暂不做（YAGNI / 记 tech-debt）
- 多 session tab 的完整管理（先单 active + 简单切换器）。
- per-session 配置覆盖（worktree/分支/模式）——v1 砍掉，全用 crew 默认。
- iPad 端适配（本 plan 只管 macOS；iPad 复用同 view 但本地 runner `#if os(macOS)` 隔离，后续单独验）。
