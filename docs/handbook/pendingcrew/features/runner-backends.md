# Runner 后端(Claude Code / Codex)

> PendingCrew 直接拉起 coding agent **程序本身**来跑 session。但两个 agent 拉起来后长得不一样:Claude Code 是一个**内嵌终端**,Codex 是一个**结构化客户端**。本篇讲这两种 runner 后端各自是什么形态、为什么一个是终端、一个不是,以及它们在产品上呈现成什么。相关:[Session 与世界观](../concepts/session-and-world-model.md) · [三栏布局](three-pane-ui.md) · [人在回路](../concepts/human-in-the-loop.md) · [子进程安全](../concepts/subprocess-safety.md)。

## 逻辑

一个 session 的右栏窗口形态,由它用哪个 runner 决定。两种 runner、两种后端形态:

| | Claude Code | Codex |
|---|---|---|
| 形态 | **内嵌交互式终端** | **结构化 app-server 客户端** |
| 怎么跑 | 拉起 `claude` 程序,接进一个真终端(SwiftTerm),字节级双向 | 拉起本地子进程 `codex app-server`,走 stdio JSON-RPC 协议 |
| 右栏长什么样 | 一个真终端窗口(看到 claude 的 TUI 原貌) | 结构化 transcript:消息气泡 / 折叠推理 / 命令卡(命令 + 输出 + 退出码)/ 文件改动 / 工具调用 |
| 发指令 | 往终端写字节 | 发一个 `turn/start` |
| 打断 / 停 | ESC / SIGTERM→SIGKILL | `turn/interrupt` / 关 stdin + 终止子进程 |

**两个 runner 共用一层薄控制协议**(start / send / interrupt / stop + 状态),所以上层(crew runner、UI、世界观注入、审批)不用关心底下是终端还是协议;只有**右栏那个窗口视图**按 runner 类型分叉:Claude → 终端视图,Codex → transcript 视图。

**两个 runner 都"就是在本机跑 codex / claude"**——用的是用户机器上已装好的 `claude` / `codex`、已登录的本地凭证。PendingCrew 不管登录、不存任何 key:如果在那个目录下手动跑 `claude` / `codex` 能用,session 就能用。两点对齐到此为止:**工作目录** = session 的 cwd、**登录** = 用户本地已有的登录。

## 为什么

- **Claude 留在终端,是因为它的交互式 TUI 是订阅计费的必经形态。** Claude Code 没有等价的「结构化协议后端」;要用上订阅(而不是按 API key 计费),就得跑它那个交互式终端本体。所以 claude 老老实实接一个真终端(SwiftTerm),字节级托管,看到的就是 claude TUI 原貌。
- **Codex 搬到 app-server,是因为它**有**一个结构化协议、且终端形态喂不饱产品。** `codex app-server` 是 codex 官方的本地协议后端(stdio JSON-RPC),能拿到分门别类的结构化事件(消息 / 推理 / 命令执行 + 退出码 / 文件 diff / 工具调用),还能读到订阅计费的 token 用量 tick。把这些渲染成结构化 transcript,比一个裸终端可读得多——所以 codex 做成「原生结构化客户端」(形态像 codex desktop,只为帮人理解、非对标),而不是又一个终端。
- **「只有 codex 搬,claude 不动」是刻意的不对称。** 两个 agent 的最佳后端形态本就不同:claude 必须终端、codex 适合协议。强行统一只会牺牲一边。共用的只是那层薄控制协议(让 runner / UI 不分叉),窗口视图该分就分。
- **不管凭证、复用本地登录,是 local-first 的直接结果。** PendingCrew 不做登录流、不注入 key(尤其 codex:导出 `OPENAI_API_KEY` 会把订阅悄悄翻成按量付费,所以 child 环境刻意不带它)。它只是个「在你机器上、你的目录里、用你的登录」拉起 agent 的外壳。

## 用在哪 · 长什么样

- **右栏 = 选中 session 的窗口**(见 [三栏布局](three-pane-ui.md))。claude session → 内嵌终端;codex session → 结构化 transcript。窗口下方都是同一个 composer(把输入注入这个 session)+ 就地的待决策 / 待审批答复卡片。
- **codex transcript 的渲染参照 codex desktop**(像它,不是对标它):每一轮的消息、推理(可折叠)、命令执行(命令 + 输出 + 退出码一张卡)、文件 diff、工具调用各有自己的行样式;遇到没见过的新事件类型,落「未知」原样渲染、不崩。
- **世界观注入按 runner 走不同通道**(同一份内容,见 [Session 与世界观](../concepts/session-and-world-model.md)):claude 经 `--append-system-prompt-file` 追加文件;codex 经 `thread/start.developerInstructions` 传字符串。每轮的白板未读:claude 走 hook 注入;codex 走 `turn/start` 的 additionalContext。
- **审批**(危险命令 / 改文件)两边都接进同一套[人在回路](../concepts/human-in-the-loop.md)的待审批 UI:claude 经 PreToolUse hook 拦截、codex 经 app-server 的审批 server-request——人答了再放行。crew 自家工具(`post_to_crew` / `read_whiteboard` / `ask`)是可信通道,不进审批门。

## 示例

你在一个 crew 里同时开了两个 session。一个 claude worker:右栏是个真终端,你看到 claude 的 TUI 在滚动、它问你确认时你直接在终端里敲。另一个 codex worker:右栏是结构化 transcript,你看到它「执行 `grep -r requireAuth`」一张命令卡(带输出和退出码 0)、下面跟一段可折叠的推理、再下面一条 agent 消息「找到两处定义」。两个 session 用同一个 composer 风格发指令、同一套审批卡片答复——你不用记「这个是终端那个是协议」,只是看到两种合适的呈现。

## 边界

- **本篇讲两种 runner 后端的形态与取舍**,不讲 codex app-server 的协议字段 / 帧格式 / 解码细节(那是实现,出处见文末指针)。
- **claude 不会搬到 app-server**,codex 不会退回终端——这个不对称是结论,不是过渡态。
- **session 的世界观注入 / 白板 / 审批**本篇只点到「两 runner 各走什么通道」;通道背后的概念见 [Session 与世界观](../concepts/session-and-world-model.md) / [白板](../concepts/whiteboard.md) / [人在回路](../concepts/human-in-the-loop.md)。
- **v1 codex 不做逐字流式**:transcript 在每个 item「完成」时整条渲染(权威终态),没有 token-by-token 打字机效果——「看不清它实时在干嘛」的另一半,defer 到后续。

## 注意 — 已改的旧方案(别写回)

- ❌ **codex 用「占位交互式终端」** —— 早期 codex 和 claude 一样接 SwiftTerm 终端(占位),那只是没补真后端时的临时形态。现已搬到 `codex app-server` 结构化客户端。任何「codex 是终端」的描述都过时。
- ❌ **「claude + codex 统一 PTY 终端,app-server 已弃」** —— 这是账本里一度记错的方向(翻过两次:先统一终端、又把 codex 翻回 app-server)。**现状:claude 终端 / codex app-server,双轨已废**,以本篇为准。
- ❌ **早期「一次性 JSONL 事件流 runner」(`RunnerEventParser` 等结构化推送旧路径)** —— 已干净拔掉,换成「claude 真终端 / codex app-server」两条。
- ⚠️ **codex 审批的两类回包形状**:危险命令 / 改文件审批走 `*/requestApproval`(已验)。但 codex 申请「额外权限」(`item/permissions/requestApproval`)的回包形状还没正确建模(回了 `{decision}`、真 schema 要 `{permissions}`)——一个潜伏 bug,只在 codex worker 申请额外权限时才撞,已记 tech-debt。常规命令 / 改文件审批不受影响。
