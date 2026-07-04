# PendingBot「机组」tab 重做 — coding session 遥控台设计

日期:2026-07-05
分支:`feat/crew-tab-remote`
状态:实施中

## 定位

PendingBot(iPhone / iPad / Mac)= coding session 的**遥控器与监视器**:

- 看任务(session 列表)、看实时进度(transcript + live 状态)
- 批权限(permission requests)
- 插话引导(steer / send_prompt)
- 发起新任务(创建 queued session)、取消 session

执行永远在 runner(PendingCrew Mac);PendingBot 不本机执行。范式参照
ChatGPT 的 Codex tab / Claude app 的 Code tab:**任务卡片流**,不是 dashboard。

老 crew tab(commit `095dfc2b` 整体删除的 dashboard 风格)不复活;本设计从零。

## IA

### Tab 结构

「机组」回到 tab 栏,五 tab:消息 / 好友 / **机组** / 来信 / 我(机组第 3 位)。

- iPhone(compact):`NavigationStack`,列表 → 详情 push。
- iPad regular / macOS:沿用 `WideRootView` 三列壳,机组实现 `FeatureSurface`
  (`listColumn` = session 卡片流,`detailColumn` = session 详情),与
  消息/好友/来信 tab 同构。`Selection = String`(crew_sessions.id),
  详情列按 id 自取数据。

### 列表页 = 任务卡片流

- 每行:task_brief 首行截断(标题)+ 副行(crew 名 · runner kind
  claude/codex · 相对时间)+ 状态徽章。
- 状态徽章:排队中(queued/waiting_runner)/ 运行中(running)/
  **待审批(waiting_permission,琥珀,置顶)** / 受阻(blocked)/
  已完成 / 失败 / 已取消。
- 分段筛选:「进行中 | 全部」。进行中 = 非终态。待审批的 session 置顶。
- 空态:引导文案(去 PendingCrew Mac 端接 runner,或点「+」发第一个任务)。
- 顶部「+」→ 新任务 sheet。
- 数据:`GET /v1/crew/sessions`(新增聚合端点,见下)按 updated_at 倒序 +
  `GET /v1/crew` 补 crew 标题。下拉刷新;前台每 15s 轻轮询列表。

### 详情页

1. **状态 banner**:状态徽章 + progress_summary + live lastEvent 一行。
   live 来源 = SessionProxyDO viewer WS(`session.state` 帧);同时对
   非终态 session 每 5s 轮询 events + session 行(WS 只是加速器,
   轮询兜底 —— 当前 PendingCrew Phase 1 的 claude PTY 路径不发
   session.state,轮询是主通道)。
2. **transcript**:`GET /v1/crew/sessions/:id/events` 渲染过程流。
   降噪哲学(参照 pendingcrew `CodexTranscriptView`):
   - 过程信号(tool_call / tool_result / status / started / runner_selected
     / context_injected / artifact_created …)= dim 圆点一行式
     (`• 动词 摘要`),弱视觉。
   - agent 正文(`posted_to_crew` 的 summary,completed/failed 的收尾
     summary)= 全亮度 `MarkdownText`。
   - `permission_requested` / `permission_resolved` 行内做锚点,不重复渲染
     (权限卡单独渲染,见下)。
3. **权限请求内联卡**:`GET /v1/crew/sessions/:id/permission-requests`
   (新增端点)拉 pending 卡;复用已有 `PermissionRequestCardView` +
   `PermissionRequestPayload`。批准/拒绝走已有
   `POST /v1/permission-requests/:id/decide`,同时向 WS 发
   `permission.decision`(runner 双通道解锁)。WS 收到 `permission.request`
   帧 → 触发一次 permission-requests 重拉(帧里可能没有 id)。
4. **composer**:发文本 = WS `session.command {kind:"send_prompt",
   payload:{text}}`(steer / 插话)。工具栏:
   - 取消 session:WS `session.command {kind:"cancel"}`(DO 离线队列 +
     mailbox 持久,runner 下次拉 inbox 也能收到)。
   - permission-mode 切换:`PATCH /v1/sessions/:id/permission-mode`
     `{mode: "auto"|"manual"|null}`(null = 继承 crew 默认)。

### 新任务 sheet

1. 选 crew:`GET /v1/crew` 列表;每个 crew 标注 runner 在线状态
   (`GET /v1/runner-hosts`,status=='online' 且 last_seen_at 3 分钟内 =
   在线;无在线 runner 标注「排队等 runner」,不阻止创建)。
2. 选 runner kind:claude(local_claude_code)/ codex(local_codex)。
3. 多行 brief(task_brief,≤12000 字)。
4. `POST /v1/crew/:crewId/sessions {runnerKind, taskBrief}` → queued
   session → 回列表并高亮新行。

## 服务端(现成为主,新增两个最小读端点)

现成、勿改协议:

| 用途 | 端点 |
|---|---|
| 列 crews | `GET /v1/crew` |
| 单 crew 的 sessions | `GET /v1/crew/:id/sessions` |
| 创建 session | `POST /v1/crew/:id/sessions` `{runnerKind, taskBrief}` → `{sessionId}` |
| session events | `GET /v1/crew/sessions/:sessionId/events` |
| 权限决定 | `POST /v1/permission-requests/:id/decide` `{decision}` |
| permission-mode | `PATCH /v1/sessions/:sessionId/permission-mode` `{mode}` |
| runner 在线 | `GET /v1/runner-hosts` |
| viewer WS | `GET /v1/sessions/:sessionId/proxy/connect?role=viewer`(Bearer = supabase JWT) |

WS 帧协议 = `apps/edge/src/lib/session-proxy-protocol.ts`
(subscribe / session.command / session.state / permission.request /
permission.decision / session.command.ack / error)。

新增(本分支,`apps/edge/src/routes/crew.ts`,守 jsonError 信封 +
requireSubjectAuth 模式):

1. `GET /v1/crew/sessions` — 跨 crew 聚合 session 列表(列表页主数据)。
   user JWT 走 userClient(RLS `can_view_crew_session` 圈可见范围);
   device_grant 按 responsible_subject_id 过滤。按 updated_at 倒序,
   含 updated_at 字段,limit 100。
2. `GET /v1/crew/sessions/:sessionId/permission-requests` — 单 session 的
   permission_requests(详情页权限卡)。同样 user JWT 走 RLS;
   device_grant 校验 session 归属。倒序,limit 50。

## iOS 数据层(新建)

- `Sources/Networking/CrewSessionAPI.swift` — `extension APIClient`:
  `listCrews` / `listAllSessions` / `listSessions(crewId:)` /
  `getSessionEvents` / `listPermissionRequests(sessionId:)` /
  `createSession` / `setSessionPermissionMode` / `listRunnerHosts`。
  行结构体照 edge select 的 snake_case 字段。
- `Sources/Networking/SessionProxy/SessionProxyProtocol.swift` +
  `SessionProxyClient.swift` — VENDORED from
  `apps/pendingcrew/Sources/Mac/LocalRunner/`(文件头注 commit hash)。
  适配点(注在文件头):
  - 去掉 `#if os(macOS)` guard(pendingbot 是 iOS+macOS 双平台);
  - viewer 侧补 `permission.request` 帧解析(runner 向 parser 把它降级
    `.unknown`);
  - 连接请求从「init 时定死 token」改为 per-connect 取 token
    (supabase JWT 会刷新,重连要用新 token)。

所有新 UI 在 `Sources/Features/Crew/`。深浅色一律 Theme token;
能用原生组件不自绘。

## v1 范围外(明确不做)

- 本机执行(永远不做 —— PendingBot 定位就是遥控器)。
- crew 群聊搬进机组 tab(群聊仍在消息 tab)。
- 创建 crew(仍走消息 tab / PendingCrew)。
- runner 注册链路(PendingCrew 侧,另一 session 负责)。
- `runner_hosts` 写操作(只读在线状态)。

## 已知缺口(记录,不阻塞 v1)

- queued 且从未被 claim 的 session,「取消」只能把 cancel 命令排进 DO
  离线队列/mailbox,DB status 停在 queued,直到有 runner claim 后处理。
  服务端没有「viewer 直接取消 queued session」端点 —— 属协议改动,超范围。
- PendingCrew Phase 1 的 claude PTY 路径不发 `session.state` /
  结构化 events(终端是事实源),此类 session 的 transcript 可能很稀疏
  —— 详情页以事件流现状渲染,不造假数据。
- 真机 QA(登录态 WS、权限批准全链路、iPad 三列壳)归统一 QA 批次。

## 实现落地时的两点与 spec 偏差(已在代码内注明)

- **权限卡放在 transcript 顶部 pinned 区**,不是 §详情页 3 描述的「在事件流
  内锚点内联」。理由:pending 审批是最需要人处理的东西,置顶比埋在时间线里
  更符合遥控台的注意力模型。permission_requested / permission_resolved 事件
  在 transcript 里隐藏(卡单独渲染),与 spec 的「不重复渲染」一致。
- **新任务 sheet 的 runner 在线标注**按 crew.responsible_subject_id ↔
  runner_host.responsible_subject_id 匹配(status=online 且 last_seen 3 分钟
  内)。`GET /v1/crew` 已返回 responsible_subject_id,匹配是精确的;不是最初
  设想的「任意 host 在线即标全部在线」的粗略降级。
