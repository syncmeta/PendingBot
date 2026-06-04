# PendingCrew Runner 改造 — 内嵌真终端跑交互式 claude/codex（统一生终端 + 自动审批）

**日期**：2026-06-04
**分支**：`feat/pendingcrew-runner-backends`
**定位**：让 PendingCrew "比较完整地编排/控制/使用 Claude Code + Codex"——**能读、能控**。显示用生 TUI 即可，不追求结构化 UI。**推翻** spec v2 §8.1"一次性裸 CLI exec"。

> **本 spec 已按用户 steer 大幅简化**（2026-06-04）：放弃 Codex app-server JSON-RPC + Claude TUI 状态机 + 原生权限卡片那套（见 git 历史的初版）。核心洞察：**把交互式 CLI 直接内嵌进一个真终端视图**——读=终端显示原样、控=转发按键 + 程序化字节注入。两端对称、零协议解析、最健壮。

---

## 1. 背景与铁律

现状（`apps/pendingcrew/Sources/Mac/LocalRunner/`）：`LocalCodingAgentProcess` 一次性 spawn `claude --print` / `codex exec --json`，写 stdin 即关；多轮靠 `--resume`+hook，权限只 auto/bypass，human-in-loop 靠自建 ask_human MCP，`RunnerEventParser` 解析两家 JSONL。**撑不起"编排/控制 coding agent"的定位**。

**计费铁律（决定必须交互式 + PTY）**：官方 headless 文档明载 **2026-06-15 起 Agent SDK 和 `claude -p` 在订阅计划走单独的小额度池**，只有**真正的交互式 TUI** 吃订阅主交互额度 → 必须 PTY 跑交互式 `claude`。Codex 交互式同理走 ChatGPT 订阅。交互式 = ANSI TUI = 必须有终端模拟器宿主。

---

## 2. 核心设计：一个终端会话，按 kind 参数化

**不要** `RunnerBackend` 双实现抽象（两端只差 binary + flags + resume 语法，YAGNI）。一个类型搞定。

### 2.1 依赖：SwiftTerm（SPM）
- 用 SwiftTerm 的 **`LocalProcessTerminalView`**（macOS/AppKit）——它本就是"在 PTY 里跑子进程并渲染终端"的现成组件，自带终端模拟、PTY 管理、`startProcess(executable:args:environment:)` 和向子进程发字节的 API。
- **project.yml 当前无任何 SPM 依赖** → 加 `packages: SwiftTerm: {url: https://github.com/migueldeicaza/SwiftTerm, from: <ver>}` + target `dependencies: - package: SwiftTerm`，再 `xcodegen`。MIT，对可开源定位无碍。
- 实施第一步**核查 SwiftTerm 真实 API**（`LocalProcessTerminalView.startProcess` 签名、向子进程发数据的方法名 `send(...)` / `feed`、process 退出 delegate），以官方为准（[[feedback_official_docs_for_integrations]]）。

### 2.2 `AgentTerminalSession`（新）
`apps/pendingcrew/Sources/Mac/LocalRunner/AgentTerminalSession.swift`，`@MainActor` ObservableObject（持有 NSView 需主线程）。
- 持有一个 `LocalProcessTerminalView`，按 `LocalCodingAgentKind`（已有：claude_code / codex）+ 工作目录启动交互式 CLI。
- **argv（交互式 + 自动审批）**，实施时**核 `--help` 定确切 flag**：
  - claude：交互式 + 跳过权限（`--dangerously-skip-permissions` 或等价的全自动 permission-mode）。**不设** `ANTHROPIC_API_KEY`（保订阅认证）。
  - codex：交互式 + 自动审批 + sandbox（`--dangerously-bypass-approvals-and-sandbox` / `--full-auto` / `-a never` 一类，核确切 flag）。
- env 白名单 + `TERM=xterm-256color`（复用现有 `LocalCodingAgentSpec.env()` 白名单思路）。
- 控制 API（程序化，供 captain 编排 + 跨端 + 手动注入）：
  - `send(_ text: String)` —— 写文本 + 回车到 PTY（发 prompt / steer，本质都是"往终端打字"）。
  - `interrupt()` —— 发 Esc（或 Ctrl-C）。
  - `stop()` —— 终止子进程（SIGTERM→grace→SIGKILL，复用现有骨架）。
  - `resume(sessionId:)` —— 以 `claude --resume <id>` / codex 对应 resume 起交互式进程。
- 状态：`running / exited(code)`（来自 SwiftTerm process-terminated delegate）。

### 2.3 权限 = 不处理（真终端天然解决）
- 默认全自动审批（上面的 flag）。
- 万一仍冒出权限提示：**它就显示在真终端里**，人直接按键回答。**不建**任何原生权限卡片 / 审批协议 / `ask_human` MCP。这是放弃 app-server/状态机后最大的化简红利。

### 2.4 读 = 终端显示；结构化回报另有其道
- "读"对人 = 看真终端。
- "读"对 captain（程序化）= **走已有的 crew 回报通道**（agent 用 `post_to_crew` 工具把关键节点发白板；runner 每轮注入白板/mailbox 上下文，task G3 已做）——**不靠解析 TUI**。本 spec 不动这条通道。

---

## 3. UI：右栏 session 窗口换成终端

- 新建 `AgentTerminalView.swift`：`NSViewRepresentable` 把 `AgentTerminalSession` 的 `LocalProcessTerminalView` 宿主进 SwiftUI。
- `CrewSessionWindowView.swift`：把现在渲染 `RunnerEvent` 的结构化 transcript **换成** `AgentTerminalView`（生终端）。底部可留一个**程序化输入框**（手动给会话发 prompt/steer，调 `session.send`）——也可省，直接在终端里打字。
- 用户在终端里键盘交互 = SwiftTerm 原生转发，零额外代码。

---

## 4. 退役 / 复用（Phase 1 范围）

- **退役**：`LocalCodingAgentProcess`（一次性 pipe 子进程）、`RunnerEventParser`（JSONL 结构化解析）、`SteeringChannel`（hook 尾注入）、`InteractionChannel`（ask_human MCP）、`LocalCodingAgentSpec.argv()` 的 `--print`/`exec --json` 分支。
  - 删 `InteractionChannel` 前**确认 ask_human MCP 仅 runner 本地路径用**（grep 别处引用）。
- **复用**：`LocalCodingAgentKind`、`LocalCodingAgentExecutable`（resolve binary）、env 白名单思路。
- `CrewSessionRun`（`CrewSessionRunner.swift`）改为持有 `AgentTerminalSession`；`events: [RunnerEvent]`/stdout 累积/`RunnerEventParser` 调用去掉，transcript 改由生终端承载。
- **`SessionProxy` 推送暂留、降级**（不删，避免破 #204 传输）：Phase 1 里 `CrewSessionRun` 给服务器只发**粗粒度生命周期**（started / exited(code)），`session.command`(远端→本机) 映射到 `AgentTerminalSession.send/interrupt`（远端控仍通）。`RunnerEvent` 类型保留作这层粗粒度 + Phase 2 改载终端字节帧。逐 token 结构化推送在 Phase 2 被终端字节隧道取代（§5）。

---

## 5. T4.5 跨端遥控 = 终端字节隧道（SSH-like）

**重新定位**（2026-06-04 用户 steer）：跨端不再发结构化 `SessionState` 摘要，而是把 PTY 当成一条 SSH 式的字节隧道——`RunnerEvent`/parser/结构化 state 这套被**整体替掉**。两端都是"接在同一个 PTY 上的终端"，完全对称。

- **读（本机→远端）**：本机 PTY 输出字节，除喂本地 SwiftTerm，也经现有 `SessionProxyClient`/`SessionProxyDO` WebSocket 流给远端；远端用**自己的 SwiftTerm 终端**（iOS/iPad 用 UIKit `TerminalView`）渲染原样 ANSI。
- **控（远端→本机）**：远端键盘字节回传 → 本机 `AgentTerminalSession` 注入 PTY。`session.command`(send_prompt/steer/cancel) 仍保留作高层命令。
- **协议**：`session-proxy-protocol.ts` + `SessionProxyProtocol.swift` 加 `terminal.output`(本机→远端，base64 字节块) / `terminal.input`(远端→本机，按键字节) 两类帧；退役逐 `RunnerEvent` 帧。
- **断连重放**：远端重连时本机重发当前屏幕快照（SwiftTerm `Terminal` 可导出 buffer），或简单地从头不重放只接续（v1 接续即可，记 tech-debt）。

### 5.1 分期
- **Phase 1（先，本机闭环）**：PendingCrew Mac 本地终端——PTY host + 显示 + 键盘/程序化控制 + 退役旧一次性路径。**不动 edge / 远端**，本机自成可用。
- **Phase 2（隧道）**：`SessionProxy` 协议改载终端字节 + 本机收发接线 + 远端 viewer（iOS/iPad PendingBot Crew tab / PendingCrew iPad 加 SwiftTerm 终端）。跨端 SSH-like 打通。

> **本 spec 的 §2–§4、§8 主要描述 Phase 1**；Phase 2 待 Phase 1 落地、本机终端验稳后单独出 plan。

---

## 6. 风险 / tech-debt

- 🟡 **跨端 viewer 看不到生终端**（§5）——本期只做本机；跨端镜像后补。记 tech-debt。
- 🟡 **自动审批 = 放权**：全自动跑 coding agent 有误删/误改风险。但这是 coding agent 工具的固有取舍，且工作目录隔离（git worktree，`GitWorktreeService` 已有）。默认自动、真终端可人工介入兜底。
- 🟢 **CLI flag/版本漂移**：claude/codex 的自动审批 flag 可能改名 → 启动失败要 fail-loud（报"agent 启动失败 + stderr"），别静默。
- 真机验证：需用户已 `claude`/`codex` 订阅登录 + 本机装了两个 CLI；headless 验不全，最终验在 Xcode GUI 跑起来真起一个 session。

---

## 7. 验证

- macOS build（含 SwiftTerm SPM 接入）。
- **真跑**（需用户登录态 + 本机 CLI）：右栏起一个 claude session，终端显示其 TUI、能打字交互、`send()` 程序化发一条 prompt 跑通、interrupt 能断、stop 能终止；codex 同样起一个验一遍。
- 账本：progress / tech-debt 更新。

---

## 8. 文件清单

| 文件 | 动作 |
|---|---|
| `apps/pendingcrew/project.yml` | 加 SwiftTerm SPM 依赖 + 重跑 xcodegen |
| `Sources/Mac/LocalRunner/AgentTerminalSession.swift` | 新建：终端会话(按 kind 起交互式 CLI + 字节注入控制) |
| `Sources/Mac/Views/AgentTerminalView.swift` | 新建：NSViewRepresentable 宿主 LocalProcessTerminalView |
| `Sources/Mac/Views/CrewSessionWindowView.swift` | 改：结构化 transcript → 生终端视图 |
| `Sources/Mac/Services/CrewSessionRunner.swift` | 改：CrewSessionRun 持 AgentTerminalSession |
| `Sources/Mac/LocalRunner/{LocalCodingAgentProcess,RunnerEventParser,SteeringChannel,InteractionChannel}.swift` | 退役(确认无他用后删) |
| `Sources/Mac/LocalRunner/LocalCodingAgentSpec.swift` | 改：去掉一次性 argv 分支,保留 kind/cwd/env |

单一 phase（不分期了——简化后体量小）。
