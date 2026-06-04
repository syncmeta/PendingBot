# PendingCrew Runner 改造 — Claude PTY + Codex app-server + 统一 RunnerBackend

**日期**：2026-06-04
**分支**：`feat/pendingcrew-runner-backends`
**定位**：让 PendingCrew "比较完整地编排/控制/使用 Claude Code + Codex"——持久多轮 session、原生逐动作权限审批、结构化事件，收进一个统一抽象。**推翻** spec v2 §8.1"只用裸 CLI、不用 Agent SDK、一次性 exec"。

---

## 1. 背景与动机（为什么推翻一次性裸 CLI）

现状（`apps/pendingcrew/Sources/Mac/LocalRunner/`）：`LocalCodingAgentProcess` 一次性 spawn `claude --print --output-format=stream-json` / `codex exec --json`，prompt 写 stdin 后即关闭。多轮靠 `--resume`+hook 尾注入（`SteeringChannel`），权限只有 auto/bypass 两档，human-in-loop 靠自建 `ask_human` MCP（`InteractionChannel`）。`RunnerEventParser` 把两家 JSONL 各自解析成 `RunnerEvent`。

够"看一眼"，但**撑不起编排/控制 coding agent 的定位**：没有真正的交互式多轮（每轮重启进程）、没有原生逐动作权限弹窗、转向靠 hack。

### 1.1 计费/认证铁律（决定两端各自的接法）
- **Claude → PTY 交互式**（不用 Agent SDK / 不用 `claude -p`）。官方 headless 文档明载：**2026-06-15 起 Agent SDK 和 `claude -p` 在订阅计划走一个单独的月度 "Agent SDK credit" 小额度池，与交互用量分开**。只有**真正的交互式 TUI** 吃订阅主交互额度 → 必须 PTY 跑交互式 `claude`。代价：交互式是 ANSI TUI，得在伪终端里跑终端模拟器维护屏幕模型、检测 UI 态、注入按键（**最大脆弱点**）。
- **Codex → app-server**（JSON-RPC over stdio）。官方文档齐全（developers.openai.com/codex/app-server）：`codex app-server`，newline-delimited JSON-RPC 2.0（线上省略 `"jsonrpc":"2.0"`）；`account/login/start type:chatgpt` = ChatGPT 订阅登录，不走 API 计费。结构化、稳。

### 1.2 决策（已与用户确认）
1. **Codex app-server 先行**（结构化、低风险，先验证 `RunnerBackend` 抽象），Claude PTY 第二。
2. **Claude PTY 底座 = SwiftTerm 的 headless `Terminal` 引擎**（MIT，对可开源定位无碍）维护屏幕模型，我们读其 buffer 检测状态 + 注入按键。
3. **Claude PTY v1 范围 = Parity+**：发 prompt · 渲染流式输出 · 检测并回答权限弹窗(y/n/always) · 中途 steer · interrupt(Esc) · resume。**不做**：slash 命令 / plan mode / 模型切换 / `/clear` 等全量 TUI（记 tech-debt 作为后续）。

---

## 2. 目标 / 非目标

**目标**：
- 统一 `RunnerBackend` protocol：start/resume session · 发 turn · 流式归一事件 · 权限请求回调 · 中途 steer · interrupt · stop。
- `CodexAppServerBackend`（Phase 1）：JSON-RPC over stdio，持久 thread，原生 approval。
- `ClaudePTYBackend`（Phase 2）：SwiftTerm headless + 屏幕状态机，Parity+。
- 原生权限审批 UI + steering 接进右栏 session 窗口（替掉 ask_human MCP 在本地 runner 路径上的角色）。
- 与既有 T4.5 跨端遥控（`SessionProxyClient`/DO）整合：远端 steer/cancel/approve 经同一 backend。

**非目标**：
- 不动 peer_device / fly_machine 远端 runner（未实装）。
- 不动 edge / DB（除非 T4.5 跨端权限审批需要小改，见 §7）。
- 不做 Claude 全量 TUI（v1 只 Parity+）。
- 不碰中栏群聊 UI（上一轮已做）。

---

## 3. `RunnerBackend` 统一抽象

新建 `apps/pendingcrew/Sources/Mac/LocalRunner/RunnerBackend.swift`。协议（async 流 + 回调）：

```swift
protocol RunnerBackend: Actor {
    /// 启动新 session(或 resume 已有)。返回 backend 解析出的 sessionId。
    func start(_ spec: RunnerLaunchSpec) async throws -> String
    func resume(sessionId: String, _ spec: RunnerLaunchSpec) async throws

    /// 提交一轮用户输入(prompt / 图片 / steer 文本)。
    func sendTurn(_ input: RunnerTurnInput) async throws
    /// 中途追加输入到进行中的 turn(steer)。
    func steer(_ text: String) async throws
    /// 取消进行中的 turn。
    func interrupt() async throws
    /// 终止 session(SIGTERM→grace→SIGKILL / app-server shutdown)。
    func stop() async

    /// 归一事件流(两家映射到同一 RunnerEvent)。
    var events: AsyncStream<RunnerEvent> { get }
    /// 权限请求流——UI 消费、调 resolve(decision) 回灌。
    var permissionRequests: AsyncStream<RunnerPermissionRequest> { get }
}
```

**归一模型**（演进现有 `RunnerEventParser.RunnerEvent`，加权限/turn 生命周期）：
- `RunnerEvent`：`.started(model,sessionId)` · `.turnStarted` · `.reasoning(String)` · `.assistantDelta(String)` · `.toolCall(title,detail)` · `.commandOutput(String)` · `.fileChange(path,diff)` · `.turnCompleted(status,costUSD?)` · `.failed(String)`。
- `RunnerPermissionRequest`：`id` · `kind`(command/fileChange/tool) · `title` · `detail`(命令/diff) · `options`([accept, acceptForSession, decline])，附 `resolve(RunnerPermissionDecision) async`。
- `RunnerLaunchSpec` / `RunnerTurnInput`：复用并精简现有 `LocalCodingAgentLaunchSpec`（kind / cwd / model / permissionMode / 初始 prompt）。

两家 backend 各自把原生事件/请求映射到这套——UI 与 `CrewSessionRunner` 只认归一模型，不再 `if kind == .codex`。

---

## 4. Phase 1 — `CodexAppServerBackend`

新建 `apps/pendingcrew/Sources/Mac/LocalRunner/CodexAppServerBackend.swift` + `CodexAppServerProtocol.swift`（线型）。

- **进程**：spawn `codex app-server`（默认 stdio）。复用 `LocalCodingAgentExecutable.resolve("codex")` + `LocalCodingAgentProcess` 的子进程/管道骨架（env 白名单、SIGTERM→grace→SIGKILL 保留）。
- **传输**：newline-delimited JSON-RPC 2.0（**省略** `"jsonrpc":"2.0"`）。一个 actor 维护 `id→continuation` 表（request/response 配对）+ notification 分发 + **服务端发起请求**（approval）处理。
- **握手**：`initialize`（clientInfo + `capabilities.optOutNotificationMethods` 屏蔽噪声通知）→ `initialized`。
- **认证**：`account/read` 查状态；未登录 → 走 `account/login/start type:chatgpt`（复用 Mac 上已有的 `codex login`，多数情况已登录）。
- **session**：`thread/start`（新）/`thread/resume`（按 threadId）→ `turn/start`（发 input）/`turn/steer`/`turn/interrupt`。
- **流式通知 → RunnerEvent**：`item/agentMessage/delta`→assistantDelta；`item/commandExecution/outputDelta`→commandOutput；`item/fileChange`→fileChange；`item/started|completed`→toolCall/turn 状态；`turn/started|completed`→turnStarted/turnCompleted；`turn/plan/updated`→(可选)reasoning。
- **原生 approval → RunnerPermissionRequest**：服务端发起请求 `item/commandExecution/requestApproval` / `item/fileChange/requestApproval` / `tool/requestUserInput` → 包成 `RunnerPermissionRequest` 抛给 UI；UI 决策回 JSON-RPC response（`accept`/`acceptForSession`/`decline`/`cancel`）。

测试：JSON-RPC framing/dispatch 用 fixture（录制真实 app-server stdout）做 TDD（PendingCrewTests 是 macOS XCTest bundle，纯 Foundation 逻辑可直接测）。

---

## 5. Phase 2 — `ClaudePTYBackend`（Parity+）

新建 `apps/pendingcrew/Sources/Mac/LocalRunner/ClaudePTYBackend.swift` + `ClaudeTUIStateMachine.swift`。

- **依赖**：加 SwiftTerm（SPM）。**project.yml 当前无任何 SPM 依赖** → 配 `packages: SwiftTerm: {url, from}` + target `dependencies: - package: SwiftTerm`，再 `xcodegen`。
- **PTY**：`forkpty`/`posix_openpt` 起伪终端，spawn 交互式 `claude`（cwd=工作目录，env 白名单 + `TERM=xterm-256color`，**不设** `ANTHROPIC_API_KEY**（保订阅认证）。
- **屏幕模型**：把 PTY 输出喂 SwiftTerm headless `Terminal` 引擎，维护 cols×rows 字符 buffer + 光标。
- **状态机** `ClaudeTUIStateMachine`：从 buffer 锚点检测态——`promptReady`（输入框出现）/ `streaming`（"esc to interrupt" 页脚）/ `permissionPrompt`（权限框 + 选项行）/ `idle`。检测到权限框 → 解析选项 → 抛 `RunnerPermissionRequest`；UI 决策 → 注入对应按键（数字/↑↓+Enter）。
- **动作 → 按键注入**：sendTurn=写文本+Enter；steer=streaming 态写文本+Enter；interrupt=Esc；resume=`claude --resume <id>` 起进程（仍 PTY 交互式）。
- **流式输出 → assistantDelta**：从 buffer 新增区域 diff 出 assistant 文本（锚定输出区，排除页脚/输入框）。

> **脆弱性是本 spec 的头号风险**（§8）。缓解：锚定稳定 UI 元素而非绝对坐标；pin 测过的 claude 版本；录制真实 TUI 会话做快照集成测试；状态机识别不了的态 → fail-loud（不静默猜）。

---

## 6. 迁移现有 LocalRunner

- `LocalCodingAgentService.runSession` 的调用方（`CrewSessionRunner.swift` 的 `CrewSessionRun`）改为持有 `RunnerBackend`，消费 `events`/`permissionRequests`。
- `RunnerEventParser` 的 Codex/Claude 解析逻辑**退役**（Codex 改 app-server 结构化、Claude 改 PTY 状态机）；`RunnerEvent` 枚举**保留并演进**（§3）。
- 一次性 `argv()`（`--print`/`exec --json` 分支）退役；env 白名单 + 子进程生命周期骨架（`LocalCodingAgentProcess` / `LocalCodingAgentExecutable`）**复用**。
- `SteeringChannel`（hook 尾注入）+ `InteractionChannel`（ask_human MCP）在本地 runner 路径**退役**——steer 走 `backend.steer`，权限走原生 `permissionRequests`。（注意：ask_human MCP 若别处也用，先确认仅 runner 路径用再删。）

---

## 7. UI + T4.5 跨端整合

- **右栏 session 窗口** `CrewSessionWindowView.swift`：transcript 渲染归一 `RunnerEvent`（reasoning 折叠 / assistant 流式 / toolCall 可展开 / fileChange diff）；底部加 **steer 输入条** + **原生权限卡片**（命令/diff + accept/always/decline，复用上一轮 PendingBot 视觉语言的卡片风格）。
- **T4.5 跨端**（`SessionProxyClient`/`SessionProxyDO`）：远端 viewer 的 `session.command`（cancel/send_prompt/set_steering）映射到 `backend.interrupt/sendTurn/steer`；**新增**远端 approve/deny 命令 → `RunnerPermissionRequest.resolve`。`session.state` 广播改发归一事件摘要。edge 侧可能需在 `session-proxy-protocol.ts` 加 approve/deny 命令类型（小改，Phase 3 再定）。

---

## 8. 风险 / tech-debt

- 🔴 **Claude PTY 解析脆弱**：claude TUI 升级可能改 UI 锚点 → 状态机失配。缓解见 §5；上线前 tech-debt 登记 + pin 版本 + 快照测试。**这是全 spec 最大不确定点**。
- 🟡 **Parity+ 砍了全量 TUI**：slash/plan mode/模型切换不做，记 tech-debt（后续按需补）。
- 🟡 **app-server / claude 版本漂移**：两者协议/TUI 都在演进，接入层要能 fail-loud 报"不认识的协议版本/UI 态"，别静默错。
- 真机验证：两端都需用户已 `codex login` / `claude` 订阅登录 + 本机有可跑的工作目录；headless CI 验不全，最终验在 Xcode GUI + 真实 CLI。

---

## 9. 验证

- Phase 1：JSON-RPC framing/dispatch 单测（fixture）；macOS build；**真跑** `codex app-server` 起一个 session 发一轮、看流式 + 触发一次命令 approval 回 accept 跑通。
- Phase 2：状态机快照测试（录制 TUI）；macOS build；**真跑**交互式 `claude` 发一轮、看流式、触发权限框回答、steer 一次、interrupt 一次。
- 整体：右栏 session 窗口端到端肉眼核对（需用户登录态 + 真实 CLI）。

---

## 10. 分期

1. **Phase 1（先）**：`RunnerBackend` protocol + 归一模型 + `CodexAppServerBackend` + 单测 + `CrewSessionRun` 接线 + 右栏渲染归一事件 + 原生权限卡片（先服务 Codex approval）。**自成可用闭环**。
2. **Phase 2**：SwiftTerm 依赖 + `ClaudePTYBackend`（Parity+）+ 状态机 + 快照测试 + 复用同一权限卡片/steering UI。
3. **Phase 3**：退役 `RunnerEventParser`/`SteeringChannel`/`InteractionChannel` 旧路径 + T4.5 跨端 approve/deny 整合（含 edge 小改）。

每期自成 spec→plan 不必，但**每期独立 plan + 验证 + 合并**。
