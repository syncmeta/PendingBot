# Spec — PendingCrew session 当群成员：启动 / 世界观 / 读未读 / 输出（crew-comms 重接）

**2026-06-05 用户拍板的模型**。承接 PTY 重写（`feat/pendingcrew-runner-backends`，已合 main）——那次把 session 的对外通信接线拔了，本 spec 把它按新心智模型重接。

## 核心模型（钉死）

- **终端 = session 的"家"（私有工作区）**，默认**没人看**。
- **群（白板/`messages`）= 主战场（公共广场）**。
- **session 是一等群成员**：靠**主动调工具往群里发消息**跟人 / captain / 别的 session / bot 沟通，**不靠刮终端输出**。
- 人**只有要细聊 / 详控 / 针对某活动**时才进终端（"把人拉进自己家详谈"）。
- session 要有**世界观**：知道群是主战场、终端是自己家、要事往群发、白板里有谁、怎么协作。

这是个**反转**：不是"我们去终端抠 output"，而是"让 agent 当群成员主动 push"。

## 现状（PTY 重写后的缺口）

- 重写版 `CrewSessionRunner` **完全没接** proxy / 对外通信：不 publish、不消费命令、不发结构化事件。`CrewSessionServerLink` 被砍到只剩 `finish()`（关 server row）。`appendSessionEvent` caller-less。
- edge 侧通信基建**还在**：`post_to_crew`（T4.1，镜像进群聊 `messages`）、`ask_human` MCP（T4.3 / `ask-human-mcp.cjs`，**正是"agent 调工具往外发"的现成证明**）、session 世界观 prompt（T4.2）、captain 编排（J/K）、whiteboard/mailbox。
- **本 spec = 把 PTY agent 重新接到这些，用"工具 push"当输出真源**。

---

## 1. 启动：指令进 argv（杀掉 0.6s sleep）

两个 CLI 都支持**启动带 prompt 且仍交互式**（实测 help）——交互式 = 订阅主额度，不碰 Agent SDK 池。

- **claude** 2.1.156：`Usage: claude [options] [prompt]`，"starts an interactive session by default"。→ `claude --dangerously-skip-permissions [--model m] "<指令>"`
- **codex** 0.137.0：`Usage: codex [OPTIONS] [PROMPT]`，无子命令即交互式，`[PROMPT]` = "user prompt to start the session"。→ `codex -a never --sandbox workspace-write [--model m] "<指令>"`

改动（4 处）：
- `AgentTerminalSession.argv(...)` 加 `initialPrompt:`，作为**最后一个 positional** 追加。
- `AgentTerminalSession.init` 透传。
- `CrewSessionRunner.start` 把 `taskBrief` 当 `initialPrompt` 传。
- `CrewSessionWindowView.startSession` / `runQueuedSession` **删掉 0.6s sleep + `run.send(firstPrompt)`**。

**留作运行中追加用**：已在跑的 session 的追加指令 / steering / 唤醒注入仍走 `run.send()` 字节注入（进程没法重启）。即"启动那一下"进 argv，"跑起来之后"仍注入。

**探针**：
- claude `--resume <id> "<prompt>"` 大概率 OK；codex `resume` 是子命令（picker 语义），带 positional prompt 行不行**未验** → 验 / 不行就 fallback 回注入。
- positional prompt 是**自动提交跑**还是**只填进输入框**——help 强烈暗示前者（`claude "fix bug"` 常规行为），但 headless 测不了，**真机确认**。
- prompt 会出现在 `ps` 进程参数（coding 指令一般不敏感，知会即可）。

---

## 2. 世界观 prompt：极简 + 系统级，不污染

**原则**：静态极简（身份+心智模型），**不塞具体 roster/消息**——那些靠白板进上下文 + 工具按需查。

- **claude**：`--append-system-prompt`（或 `--append-system-prompt-file`）。核过 help：**不在 `--print` 限定组**，交互式可用；追加到系统提示 = always-on 但走 prompt cache、非用户消息、不占对话回合 = 最不污染。
- **不用 CLAUDE.md**（进用户 repo 污染树 / 或要 `--add-dir` out-of-tree，更麻烦）。
- **不用 skill 当身份**（skill 是"模型觉得相关才加载"，always-on 身份不可靠）。可选：skill 当"详细协作 playbook"按需加载，v1 先不做。
- **工具用法说明走注入的 MCP server 自己的 instructions**，不占系统提示。

世界观内容（短）：你是这个 crew 的一名 session 成员；**群是主战场**，要事往群里发（用工具）；白板内容会进你的上下文，别人的昵称/身份/消息都在那；**终端是你家**，只有人来找你细聊时才在这交互；需要更多信息用这些工具查（见 §4）。

**探针（codex）**：codex 没有 `--append-system-prompt`。走 `-c key=value` 改 config / 或 instructions 文件 / 或 `AGENTS.md`。要找**不污染 repo、也不污染全局 `~/.codex/AGENTS.md`** 的 per-session 注入法（可能 `-c experimental_instructions_file=<托管路径>`）——**未验，需探**。

---

## 3. 白板进上下文 + 读未读 + 空闲注入

### 白板每回合进上下文（push，不靠工具）

白板内容（昵称/身份/消息）**每回合自动注入上下文** → agent 总能看到当前白板，**读白板不需要工具**。

- **claude**：`UserPromptSubmit` hook（旧 `SteeringChannel` 那套机制：托管目录放 `settings.json` 注册 hook + `hook.sh` 吐白板 digest）。每次提交 prompt 时 hook 把最新白板塞进上下文。**为 PTY 重建**（重写时拔了）。
- **探针（codex）**：codex 的 per-turn 上下文注入 hook 等价物**未验，需探**。

### 读/未读 + 空闲 → 注入（对齐 PendingBot IM）

- 白板消息对 session S 有**已读游标**（复用 `messages` 表 + 读状态，跟 PendingBot IM 一套）。**agent 回合里读了白板 = 标已读**。
- **忙 + 未读** → 不管，下一回合白板进上下文它自然收到。
- **空闲 + 未读** → 它不会自己读，**注入唤醒**：注入**就五个字「看一下白板」**。白板内容本来就在上下文（靠 hook），所以**不贴内容、不调工具**，戳醒它自己看即可。
- **已读** → 不动。

三件套：① 空闲判定（= §5 transcript 回合边界）② 每 session 读游标（edge）③ 空闲+未读时 `run.send("看一下白板")`。

---

## 4. 输出：主路径 = 工具 push，辅助 = transcript

### 主路径：注入 MCP crew-comms 工具

给 agent `--mcp-config` 注入一个 crew-comms MCP server，agent 调工具 = 主动往外发结构化消息，**直接落群**（复活被 PTY 重写搁浅的 `post_to_crew` / 白板 / `ask_human`）：

- `post_to_crew(text)` — 往群发言（已有 edge 路径）。
- `message(target, text)` — @ 某个 session / bot。
- `ask_human(question)` — 阻塞式问人（已有 `ask-human-mcp.cjs`）。
- **深查类**（按需 pull，§2 世界观里告诉它有这些）：
  - `list_crew_members()` — 找所有 crew 成员。
  - `read_board(filter)` — 看不是只 @ 自己的消息等。
  - `look_at_session(id)` — 拉别的 session 的 transcript「检查工作」（见下）。

MCP 工具的调用**同时喂 `SessionProxyDO` / 群** → viewer 实时 banner / captain / 群聊都看到 → **用"工具 push"这个数据源把 T4.5 跨端实时接回来**（不是终端刮屏）。

### 辅助：transcript

- **on-demand「检查工作」**：别的 session / bot / 人想知道某 session **具体在干啥**，拉它的 transcript 细看。claude 写 `~/.claude/projects/<cwd>/<sid>.jsonl`、codex 写 `~/.codex/sessions/.../rollout-*.jsonl`，**交互式也写**（已实证）。
- **状态传感**：回合边界喂运行/空闲（§5）。
- 这俩都是**按需查**，不往群实时推——符合"主战场是群、终端是家"。

---

## 5. 状态：运行 / 等待交互 / 空闲

**真源 = transcript 回合边界**（确定）：tool_use 在飞 = 运行；assistant 回合结束、无挂起 = 空闲/可输入。

**终端信号当补充（不当真源）**：
- 通用的"在 prompt / 可输入"标识是 **OSC 133**（shell integration）——但那给 shell，claude/codex 是全屏 TUI，**默认大概率不发**（真机抓一次确认）。
- claude 等输入/完成会发 **BEL / OSC 通知**（"需要你了"）→ **SwiftTerm delegate 能抓**（`bell` / `setTerminalTitle`），现在 `AgentTerminalSession.Delegate` 没接 → **接上当 attention 补充信号**。但它给的是"注意我"，不一定干净区分"运行 vs 空闲"。

**可输入性的实证发现**：claude transcript 有 `queue-operation`（enqueue/dequeue）事件——**claude 忙时灌输入会排队不丢**。所以"必须等空闲才能发"对 claude 不成立，可随时发、它排队；空闲状态主要用于 UX + 知道"回合结束了"。codex 排队行为**未验**。

---

## 待探针（实现期验，非设计阻塞）

1. **codex per-session 指令注入通道**（`-c` / instructions 文件 / 不污染的 AGENTS.md）。
2. **codex per-turn 上下文注入** hook 等价物（白板进上下文）。
3. **codex `resume` + positional prompt** 行为。
4. **真机抓 claude/codex 终端发什么**（bell / OSC / title）做 attention 补充 + positional prompt 是否自动提交。
5. **计费确认**：交互式 + positional prompt 仍走订阅、不碰 Agent SDK（强预期，真机确认）。

## 验证门

- 每块 typecheck / macOS build；edge 改动 typecheck + vitest。
- 真机（归 T5.3 一类）：起 session 指令进 argl 即跑 → agent 调 `post_to_crew` 群里出现 → 空闲时别的成员 @ 它、注入「看一下白板」唤醒它回话 → 拉它 transcript 看细节。

## 暂不做 / YAGNI

- **PTY 字节隧道（远端看一模一样终端画面）**：这是另一条重路（spec runner §5 Phase 2），本 spec **不依赖**它——输出靠工具 push、细节靠 transcript，已够。字节隧道留给"真·共享终端"强需求。
- 多 session 并行的完整管理。
- 跨 CLI 的统一抽象层（claude / codex 各自注入通道先各写各的，跑通再看要不要抽）。
