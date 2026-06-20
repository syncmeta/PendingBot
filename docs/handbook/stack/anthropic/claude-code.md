# Claude Code(嵌入式 runner)

> 系统全景里 **Claude Code 作为一个被 PendingCrew 拉起的 runner** 在系统里扮演什么角色。形态与取舍的产品故事在 [Runner 后端](../../pendingcrew/features/runner-backends.md)、协议/接线在代码与 stage docs;本篇只到「它是什么、在系统里什么位置」。相关:[Session 与世界观](../../pendingcrew/concepts/session-and-world-model.md) · [人在回路](../../pendingcrew/concepts/human-in-the-loop.md) · [子进程安全](../../pendingcrew/concepts/subprocess-safety.md) · 同类 runner:[Codex](../openai/codex.md)。

**逻辑** — Claude Code 是 Anthropic 官方的 coding agent CLI(`claude`)。PendingCrew 不调它的 API、不重写它,而是**把用户机器上已装好的那个 `claude` 程序本身拉起来跑 session**——接进一个内嵌的真终端(SwiftTerm),字节级双向托管:读 = 终端原样显示 claude 的交互式 TUI,控 = 转发按键 + 程序化注入字节(发指令 = 往终端打字 + 回车,打断 = ESC,停 = SIGTERM→宽限→SIGKILL)。在系统里它是 **crew 的一种"干活的手"**:一个 claude session 就是一个 worker(或机长 captain),由本地白板唤醒、按世界观干活。

**为什么 — 为什么是"嵌真终端"而不是调协议/API**
- **订阅计费只认交互式 TUI。** 官方明载:headless 路径(Agent SDK / `claude -p`)在订阅计划走单独的小额度池,只有**真正的交互式 TUI** 吃订阅主额度。要让用户用上自己的 Claude 订阅(而不是被迫按 API key 计费),就必须跑那个交互式终端本体 → 必须有终端模拟器宿主(SwiftTerm 的 `LocalProcessTerminalView`)。这是"claude 留在终端"的根因,不是实现偷懒。
- **不管凭证,复用本地登录。** PendingCrew 不做登录流、不存 key、刻意**不注入 `ANTHROPIC_API_KEY`**(注入 key 会把订阅认证顶掉)。判据很简单:在那个目录下手动跑 `claude` 能用,session 就能用。两点对齐到此为止——**工作目录** = session 的 cwd、**登录** = 用户本地已有的登录。
- **和 Codex 的不对称是刻意的。** 只有 codex 搬去结构化 app-server,claude 不动:两个 agent 的最佳后端形态本就不同(claude 必须终端 / codex 适合协议),强行统一只会牺牲一边。详见 [Runner 后端](../../pendingcrew/features/runner-backends.md)。

**用在哪·长什么样** — claude session 的右栏 = 一个内嵌真终端,看到的就是 claude TUI 原貌(滚动输出、spinner、它问你确认时直接在终端里敲)。下方共用 composer(把输入注入这个 session)。系统对它的角色编排是 agent-无关的:世界观、白板未读、审批都走 claude 自己的扩展点(见下),上层 crew runner / UI 只认那层薄控制协议(start / send / interrupt / stop + 状态)。

**permGates = computer-use —— 审批怎么接** — 危险动作的人工审批,通过 claude 的 **PreToolUse hook** 拦截接进系统的[待审批 UI](../../pendingcrew/concepts/human-in-the-loop.md):工具名命中 gate 的 → 升起一条待审批、阻塞等人答 → 答了再放行/拦截。v1 的默认 gate 只有一个值:**`computer-use`**——只拦最敏感的桌面控制类工具。crew 自家工具(`post_to_crew` / `read_whiteboard` / `ask`,都是 `mcp__crew__` 前缀,子串不含 `computer-use`)是 session 自己的可信通道,**刻意不进审批门**。世界观注入走 `--append-system-prompt-file`(追加、不替换 claude 默认 system prompt),每轮白板未读走 PostToolUse hook 注入。这些都是用 claude 已有的扩展点接,不改 claude 本身。

> 说明:`computer-use` 是这里**审批 gate 列表的一个匹配字符串**(默认只 gate 桌面控制类工具),与本仓库别处用来截 Mac UI 的 computer-use 工具是两码事,别混。

**边界**
- 本篇只讲"claude 作为 runner 在系统里的角色 + 它的扩展点怎么被用",**不讲** SwiftTerm 的 API、hook 的 JSON 形状、argv 细节(实现,出处见文末)。
- claude **不会搬到结构化协议后端**;它就是终端,这是结论不是过渡态。
- 跨设备只能看 claude 的状态、不能远端载终端字节(SSH 式隧道是后续),详见 [跨设备控制](../../pendingcrew/features/cross-device-control.md)。

**注意 — 别写回的旧方向**
- ❌ **"claude + codex 统一 PTY 终端、app-server 已弃"** —— 账本一度记错(方向翻过两次:先统一终端、又把 codex 翻回 app-server)。**现状:claude 终端 / codex app-server,以此为准。**
- ❌ **早期一次性 `claude --print` / JSONL 事件流 runner**(`LocalCodingAgentProcess` / `RunnerEventParser` 等)—— 已干净拔掉,撑不起"编排/控制 coding agent"的定位,换成内嵌真终端。
- ❌ **claude 跑 `--dangerously-skip-permissions` / 全 bypass** —— runner-backends 初版曾这么写;现状是 **`--permission-mode auto`(auto mode 分类器),不是 bypass**,危险动作仍经 PreToolUse gate 兜到人。
- ⚠️ 别注入 `ANTHROPIC_API_KEY`(顶掉订阅认证)。

**现状** — 🟨 代码全落、本机闭环 build + 单测绿;像素级真验(终端托管 / 字节注入 / 交互)随 Mac GUI QA 收尾。SwiftTerm 接入、`send/interrupt/stop` 字节注入、`--permission-mode auto`、世界观 / 白板 / 审批 hook 接线都已落地并单测;flag 本机实测过。完整真机 QA(本机 claude 登录态起 app 验)是已知尾巴(见 tech-debt)。

**出处指针**(向下,不在手册重抄):Runner 形态与取舍 → [`pendingcrew/features/runner-backends.md`](../../pendingcrew/features/runner-backends.md);计费铁律 + argv → spec `docs/superpowers/specs/2026-06-04-pendingcrew-runner-backends-design.md`;hook / 审批机制实证 → spec `2026-06-08-claude-mechanism-spike-findings.md` + `2026-06-08-pendingcrew-ask-approval-design.md`。
