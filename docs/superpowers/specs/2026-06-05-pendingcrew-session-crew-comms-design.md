# Spec — PendingCrew session 当群成员：启动 / 世界观 / 读未读 / 输出 / 额度（crew-comms 重接）

**2026-06-05 用户拍板**。承接 PTY 重写（`feat/pendingcrew-runner-backends`，已合 main）——那次把 session 的对外通信接线拔了，本 spec 按新心智模型重接。**本版已纳入：codex 改走 app-server、captain 终止权 + 权能透明、急插三层、额度监控。**

## 核心模型（钉死）

- **终端/会话 = session 的"家"（私有工作区）**，默认**没人看**。
- **群（白板/`messages`）= 主战场（公共广场）**。
- **session 是一等群成员**：靠**主动调工具往群里发消息**沟通，**不靠刮终端输出**。
- 人**只有要细聊 / 详控**时才进 session（"把人拉进家详谈"）。
- session 有**世界观**：群是主战场、家是私有、要事往群发、**知道 captain 能干什么**、怎么跟别的 session/bot 协作。

## Runner 拆成两后端（本版关键变更）

回最初方向：**claude 走 PTY、codex 走 app-server**，收进一个共同 `RunnerBackend` 抽象（启动 / 注上下文 / 发消息 / 读输出 / 状态 / 停 / 额度 七个口子各自实现）。

| 维度 | **claude = PTY**（SwiftTerm 内嵌真终端，现状） | **codex = app-server**（JSON-RPC over stdio，新） |
|---|---|---|
| 计费 | 交互式 TUI 吃订阅主额度（铁律） | auth 决定（`auth_mode`+ChatGPT tokens）；rollout 里 `rate_limits.limit_id="codex"` = 走订阅。⚠️ app-server 是否仍订阅 = 探针 |
| "进家细聊" UI | 真终端（人可看可敲） | **无真终端** → 结构化 chat 详情视图（或把结构化事件回灌进一个 SwiftTerm 视图假装终端，保 UI 统一，多点活） |
| 上下文/急插 | 见 §3（hook + 注入，工具边界粒度） | **原生**：你掌控每条请求的 messages，随时插、每次带最新白板 trivial |
| 输出 | MCP 工具 push + transcript 辅助（§4） | 结构化事件直出（不用 tail transcript）+ 工具等价物 |
| 状态 | transcript 回合边界 + 终端 bell（§5） | `notify turn-ended` + 结构化事件 |
| 额度 | transcript `usage` 累加（只消耗，无剩余，§7） | 协议 `rate_limits`（limit/resets_at/reached，有剩余，§7） |

---

## 1. 启动：指令随调用一起带

两端都**启动即带首条指令**，且都**交互式/订阅计费**（不碰 Agent SDK / 不走 headless exec）。

- **claude（PTY）**：positional `[prompt]`。`claude --dangerously-skip-permissions [--model m] "<指令>"`（help 实证：交互式默认，非 `--print` 限定）。改 `AgentTerminalSession.argv` 加 `initialPrompt:` 作末位 positional；删掉 `CrewSessionWindowView` 的 0.6s sleep + 事后 `send`。
- **codex（app-server）**：起 app-server 后,首条 user message 即 `<指令>`（你构造协议消息，天然带）。
- **探针**：claude `--resume <id> "<prompt>"` 大概率 OK；positional 是自动提交还是只填框 → 真机确认。codex app-server resume/初始消息协议形状 → 实接确认。

---

## 2. 世界观 prompt + captain 权能透明

**原则**：静态极简（身份 + 心智模型 + **captain 能干什么**），不塞具体 roster/消息（那些靠白板进上下文 + 工具按需查）。

世界观内容（短）：你是这个 crew 的一名 session 成员；**群是主战场**，要事用工具往群发；白板内容会进你的上下文，成员昵称/身份/消息都在那；**家是你的私有工作区**，只有人来细聊才在这交互；**captain 是机长，它能：起/终止 session、招临时 bot、建子 crew、编排调度——它叫停你时照做**；需要更多信息用工具查（§4）。← **"captain 能干什么"写进每个 session 的世界观 = 全员透明。**

- **claude**：`--append-system-prompt`（或 `-file`）——系统级、走 prompt cache、非用户消息、不污染 repo。**不用 CLAUDE.md**（中途改不生效 + 进 repo 污染树）、**不用 skill 当身份**（按需加载不可靠；可选当详细 playbook，v1 不做）。
- **codex**：app-server 你构造 system/developer message，直接带（比 claude 更直接）。
- 工具用法说明走注入的 MCP server 自己的 instructions（claude）/ 协议工具定义（codex），不占系统提示。

---

## 3. 白板进上下文 + 读未读 + 急插（三层）

### 白板进上下文（per-turn 基线）

白板内容（昵称/身份/消息）**每回合进上下文** → 读白板**不用工具**。

- **claude**：`UserPromptSubmit` hook（旧 `SteeringChannel` 机制，为 PTY 重建）。文档实证：**只在每次提交 prompt 时触发**（非 per-model-request），输出落对话**尾部** → 大前缀继续命中 cache（cache 友好）。**CLAUDE.md 做不到这个**（会话开始读一次、中途改不生效）。
- **codex**：你掌控每条请求的 messages → 想多新鲜多新鲜，trivial。

### 读/未读 + 空闲注入（对齐 PendingBot IM）

- 白板消息对 session S 有**已读游标**（复用 `messages` 表 + 读状态）。**agent 回合里读了白板 = 标已读**。
- **忙 + 未读** → 下回合白板进上下文自然收到。
- **空闲 + 未读** → 注入**就五个字「看一下白板」**唤醒（白板已在上下文，不贴内容不调工具）。
- **已读** → 不动。

### 急插：长任务中途被急问（三层升级，文档实证）

| 紧急度 | 机制 | 打断? |
|---|---|---|
| routine | 白板随回合进（上面） | 否，下回合见 |
| **急（任务中）** | **claude**: `run.send("急问…")` 或 `PostToolUse` hook 注入 → 落**同回合下一次模型请求**（工具边界，文档实证非回合末）。**codex**: 协议直接插一条 message（原生） | 否，**中途插入不打断** |
| 必须立刻停 | **claude**: Esc 取消当前工具 / **captain 强行终止**（§6）。**codex**: 协议中断 / captain 终止 | 是 |

- **限制**：claude 的中途插入是**工具边界**粒度——卡在某个超长单工具里要等它返回；那种就 Esc / captain 终止。
- **残留待测**：claude 注入到达是"下个工具边界"还是"回合末"，文档措辞略含糊 → 真机量一次钉死。

---

## 4. 输出：主路径 = 工具/结构化 push，辅助 = transcript

### 主路径

- **claude**：`--mcp-config` 注入 crew-comms MCP server，agent 调工具 push 结构化消息直接落群（复活被重写搁浅的 `post_to_crew` / `ask_human`）。
- **codex**：app-server **结构化事件直出**——assistant 消息 / tool_call / 完成都是协议事件，直接拿，不用 tail transcript。crew-comms 工具走 codex 的 tool/MCP 接口。

工具集（两端等价）：`post_to_crew(text)`、`message(target,text)`、`ask_human(question)`、深查类 `list_crew_members()` / `read_board(filter)` / `look_at_session(id)`。工具调用**同时喂 `SessionProxyDO`/群** → viewer/captain/群聊都看到 → 用"工具 push"数据源把 T4.5 跨端实时接回来（非刮屏）。

### 辅助：transcript（主要 claude 用）

- **on-demand「检查工作」**：别的成员想知道某 session 具体在干啥 → 拉它 transcript 细看（claude `~/.claude/projects/<cwd>/<sid>.jsonl`、codex `~/.codex/sessions/.../rollout-*.jsonl`，交互式也写，已实证）。
- **claude 状态传感**：回合边界喂运行/空闲（§5）。
- **更新延迟**：文档只说 "continuously"（近实时），**无 SLA → 真机量**。codex 因结构化直出，状态/输出不靠 tail。

---

## 5. 状态：运行 / 等待 / 空闲

- **claude**：真源 = transcript 回合边界（tool_use 在飞=运行；assistant 回合结束无挂起=空闲）。**补充1** = §7 的 statusLine 脚本**每条 assistant 消息后触发**（debounce 300ms）= 干净的"回合结束"信号 + 上下文用量，一并到达。**补充2** = 终端 BEL/OSC 通知（SwiftTerm delegate 接 `bell`/`setTerminalTitle`，现没接），给"需要注意"。OSC 133（shell 标识）TUI 默认大概率不发 → 真机抓确认。claude 忙时灌输入会**排队**（`queue-operation` 实证）。
- **codex**：`notify=[..,"turn-ended"]` 出站事件 = **干净的"空闲了"信号**，不用解析。+ 结构化事件直接给细状态。

---

## 6. captain 终止权 + 编排（全员透明）

- **captain 工具 `terminate_session(session_id, reason)`**：门控 captain（验本 crew 机长）→ 经 **edge→Mac 通道**（复用现有 captain→Mac 的 queued/claim 轮询同款，或 SessionProxyDO command）下发终止 → runner 停（claude `AgentTerminalSession.stop()` SIGTERM→SIGKILL / codex app-server shutdown）。
- captain 既有编排（起 session / 招临时 bot / 建子 crew）已在；本条加"终止"补全控制面。
- **透明**：captain 权能写进 §2 每个 session 的世界观 + 可在群花名册/详情对人类展示，让全员知道机长能干什么、会不会被叫停。

---

## 7. 额度监控（剩余 + 消耗）

目标：用户/captain 起新 session 前知道还剩多少订阅额度，别把窗口跑爆。本地 session 跑用户自己的 claude/codex 订阅。**两端都有官方"剩余+重置"通道**（实证修正了草稿版"claude 给不了剩余"的错判——之前只查 transcript，漏了 statusLine）。

- **claude = `statusLine` 旁路（v2.1.80+，关键，借鉴 ccstatusline 那批）**：配 `--settings` 的 `statusLine.command` 指向一个小脚本，claude **每条 assistant 消息后**（debounce 300ms、跑本地不耗 token）把一坨 JSON 喂它 stdin：
  - **`rate_limits.five_hour` / `rate_limits.seven_day`** 各 `{ used_percentage, resets_at(epoch) }` —— **官方剩余 + 重置**（底层是 claude 解析的 `anthropic-ratelimit-unified-*` header 缓存透出；**Agent SDK 不暴露 → 只交互式 statusLine 拿得到**，又一条 PTY 优于 SDK 的理由）。
  - `cost.total_cost_usd`（本会话累计花费估算）+ `context_window.{used_percentage, current_usage.{input/output/cache_*}}`（上下文用量，比 transcript 重构干净）。
  - 脚本把整坨 JSON 转写到 per-session 旁路文件/socket，PendingCrew 读 → **一条 push 通道同时拿 cost / 上下文 / 官方剩余**（顺带也是个干净的回合/状态信号，见 §5）。
  - **坑（实现必处理）**：① 版本门 v2.1.80+（`context_window` 语义 v2.1.132 变过，`total_*` 由累计改当前）；② 仅 Pro/Max 订阅 OAuth 有，API key/Bedrock/Vertex 没有、首响应前缺；③ **bug #52326**：5h 窗口无数据时 `used_percentage` 会漏成 `resets_at` 那个大 epoch 数 → 必须 bounds-check `if(p<0||p>100)p=0`；④ bug #40094 某些 Max 20× 整段缺。
- **codex = 协议 `rate_limits`**（rollout/app-server，`limit_id`/`resets_at`/`reached`）→ 直接读剩余 + 重置。
- **兜底 = ccusage 式 JSONL 推断**：没 `rate_limits` 的环境（老版本 / 非订阅），sum `~/.claude/projects/**/*.jsonl` 的 `usage` 四字段 × LiteLLM 价表算消耗，按 5h 窗口 + 自推峰值/已知档位上限估剩余。**当降级路，不当主**。
- **落点**：PendingCrew per-session + crew 汇总，两端显"剩余 % + 重置时间"；claude 同一 statusLine 旁路顺带 cost + 上下文用量。

---

## 8. 长跑韧性 / 安全闸 / 打包（本轮 Claude Code 扩展面调研，部分待真机核）

session 是**长跑**的，会撞上几个 claude code 机制，提前接：

- **🔴 compaction 韧性（最要紧的新发现）**：长 session 上下文满会**自动 compact（摘要化）** → **注入的动态 crew 上下文（白板 digest）可能被摘掉** → session "忘了"群里最新状态。补：`SessionStart`（matcher 含 `compact`/`resume`）+ `PreCompact` hook → **compact 后重注** crew 世界观 + 当前白板。
  - 调研称：系统提示 / CLAUDE.md / skill 在 compact 后**会自动重载**（若真，`--append-system-prompt` 的静态世界观能扛过 compact，只动态白板要 PreCompact 重注）——**信心不足，待真机核**。
- **安全闸（缓解"自动审批=放权误删" tech-debt）**：默认自动审批不变，但 `PreToolUse` hook（exit 2/deny）+ settings `permissions.deny` 可**无提示拦危险动作**（`rm -rf`、碰 `.env`、越界路径）→ 误删风险从"全靠 worktree 隔离"降到"隔离 + 黑名单双保险"，不破"无 human-confirm"体验。
- **状态信号补强 §5**：`Notification` hook（claude 等输入/权限时触发）= 比刮终端 bell 干净的"需要注意"；`Stop` hook（回合结束）= 干净空闲信号、且能 block 强制等待。
- **打包形态**：可把 hooks（SessionStart/PreCompact/PreToolUse/Stop）+ crew-comms MCP + 世界观 + 安全闸 settings 收成**一个 plugin**（`--plugin-dir` 非交互加载），而非 --settings/--mcp-config/--append-system-prompt 散一地。维护性好，留作落地容器形态（不阻塞，先散装跑通再收）。
- **MCP resources（pull 备选）**：深查类（`look_at_session` 等）可建成 MCP **resource**（agent 按需 live-fetch、天然扛 compact），而非纯 tool。白板主路仍走 push（你定的）；resource 给"按需深查"。

## 待探针（实现期验，非设计阻塞）

1. **codex app-server**：仍走订阅(非单独计费)？协议形状(initial message / resume / 工具 / 中断 / rate_limits 透出)——`generate-ts`/`generate-json-schema` 出绑定后实接。
2. **claude positional prompt**：自动提交 vs 只填框；`--resume + prompt`。
3. **claude 注入到达时机**：下个工具边界 vs 回合末（真机量）。
4. **claude transcript flush 延迟**（真机量）。
5. **claude 终端发什么**（bell/OSC/title）做状态补充。
6. **claude statusLine `rate_limits`**：本机版本（需 v2.1.80+）+ 用户订阅档（Pro/Max）实际可用？两个 bug（#52326 epoch 泄漏 / #40094 Max20× 缺）真实表现？statusLine→旁路文件 落地形状 —— 真机验。

7. **compaction 韧性**：`PreCompact` hook 能否经 `additionalContext` 把动态白板塞进 compact 后上下文？`--append-system-prompt`/skill 是否真"自动重载"扛过 compact？（§8，调研信心不足，真机核）。
8. **plugin / settings 精确键**：`--plugin-dir` 非交互加载、`permissions.deny`/`PreToolUse` deny 语法、settings 各键名 —— 调研给的 JSON 样例当方向，落地前逐个核实键名（别凭样例写死）。

## 验证门

- 每块 typecheck / macOS build；edge 改动 typecheck + vitest。
- 真机（归 T5.3 一类）：起 session 指令随调用即跑 → agent 调 `post_to_crew` 群里出现 → 空闲时别人 @ 它、注入「看一下白板」唤醒回话 → 长任务中途急插不打断 → captain 终止生效 → 额度面板显 codex 剩余 / claude 消耗。

## 暂不做 / YAGNI

- **PTY 字节隧道（远端看一模一样终端画面）**：本 spec 不依赖（输出靠工具/结构化、细节靠 transcript）。留给"真·共享终端"强需求。
- 多 session 并行的完整管理。
- claude/codex 跨后端的过度统一抽象——`RunnerBackend` 七口子够用，跑通再看要不要抽更多。
