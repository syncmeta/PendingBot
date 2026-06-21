# Codex(app-server runner)

> 系统全景里 **Codex 作为一个被 PendingCrew 拉起的 runner** 在系统里扮演什么角色。形态与取舍的产品故事在 [Runner 后端](../../pendingcrew/features/runner-backends.md)、协议字段在 stage docs;本篇只到「它是什么、在系统里什么位置」。相关:[Session 与世界观](../../pendingcrew/concepts/session-and-world-model.md) · [人在回路](../../pendingcrew/concepts/human-in-the-loop.md) · [子进程安全](../../pendingcrew/concepts/subprocess-safety.md) · 同类 runner:[Claude Code](../anthropic/claude-code.md)。

**逻辑** — Codex 是 OpenAI 官方的 coding agent CLI(`codex`)。和 claude 一样,PendingCrew 拉起的是**用户机器上已装好的那个 `codex` 本身**;但 codex 不接终端,而是以 **`codex app-server`** 形态跑——一个本地子进程,走 **stdio 上的换行分隔 JSON-RPC** 协议。PendingCrew 是它的一个**原生结构化客户端**(形态像 codex desktop,只为帮人理解、非对标):拿到分门别类的结构化事件(消息 / 推理 / 命令执行 + 退出码 / 文件 diff / 工具调用),渲染成结构化 transcript。在系统里它和 claude session 同样是 **crew 的一只"干活的手"**(worker 或机长),角色编排完全 agent-无关;只有右栏那个窗口视图按 runner 分叉:claude → 终端,codex → transcript。

**为什么 — 为什么 codex 是 app-server 而不是终端**
- **codex 有一个结构化协议、且终端形态喂不饱产品。** `codex app-server` 是官方的本地协议后端,能拿到结构化事件流 + 订阅计费的 token 用量 tick;把这些渲染成 transcript 比一个裸终端可读得多。所以 codex 做成结构化客户端,不再是又一个终端。
- **订阅计费认凭证、不认入口。** 关键确认:app-server / exec / TUI 三个入口的计费**完全一致**,吃哪个额度池由**凭证**决定——`~/.codex/auth.json` 里 `auth_mode:"chatgpt"` 就走 ChatGPT 订阅。所以"换成 app-server"不影响订阅计费(本机真起一轮 turn 验过,token tick 落在订阅计数上)。
- **不管凭证,复用本地登录。** PendingCrew 不做登录流:连上先 `account/read`,返回已认证账号就开跑(本机 0.137.0 实证 = **自动继承 `~/.codex/auth.json`**,无需自建登录)。判据同 claude:在那个目录下手动跑 `codex` 能用,session 就能用。两点对齐:**工作目录** = session 的 cwd、**登录** = 本地已有登录。

**env 守卫 —— 别让订阅悄悄翻按量** — 构建 codex 子进程的环境时,**刻意剥掉 `OPENAI_API_KEY`**:导出一个 API-key 环境变量会把订阅认证翻成按量付费(pay-as-you-go),哪怕 `auth.json` 仍是 `chatgpt`。(`auth.json` 文件里带 `OPENAI_API_KEY` 字段没事;**导出成进程 env 才是雷**。)PendingCrew 的子进程 env 白名单本来就不含它,这里只是把"不带它"当成一条守住的红线。

**审批走 server-request,不下到子审批** — 危险动作(命令执行 / 改文件)的人工审批接进系统的[待审批 UI](../../pendingcrew/concepts/human-in-the-loop.md):app-server 在边界处发一条**服务端→客户端的 JSON-RPC 请求**(阻塞 agent、等我们回),挂进同一套审批 store、人答了再 `respond` 回去放行/拒绝。策略固定:`approvalPolicy:"on-request"` + `sandbox:"workspace-write"` + **`approvalsReviewer:"user"`**——`user` 把审批**路由出来给人**,不交给 codex 内部的子审批 agent。和 claude 唯一的差别只是"回包走 stdio"而非"hook 退出码"。crew 自家工具(`post_to_crew` / `read_whiteboard` / `ask`)是可信通道,**自动放行、不进审批门**——对齐 claude `permGates="computer-use"` 把 crew 排除出 gate 的做法。

**世界观与白板怎么接** — codex 没有 claude 的 `--append-system-prompt-file` / PostToolUse hook,改走协议:世界观(启动 system prompt)经 `thread/start.developerInstructions` 传字符串;每轮白板未读经 `turn/start` 的 `additionalContext` 注入(标 `kind:"untrusted"` = 数据非指令);crew 工具走 codex 原生的 MCP 通道挂同一个 helper。同一份内容、不同通道,与 claude 对称(见 [Session 与世界观](../../pendingcrew/concepts/session-and-world-model.md))。

**用在哪·长什么样** — codex session 的右栏 = 结构化 transcript,渲染参照 codex desktop(像它,不是对标它):每轮的消息气泡、可折叠推理、命令执行卡(命令 + 输出 + 退出码)、文件 diff、工具调用各有行样式;遇到没见过的新事件类型,落「未知」原样渲染、不崩(前向兼容,codex 升级不致命)。下方共用 composer + 就地的待决策 / 待审批答复卡片。

**边界**
- 本篇只讲"codex 作为 runner 在系统里的角色 + 它怎么接进世界观/审批",**不讲**协议字段名 / 帧格式 / 解码细节 / `ThreadItem` union 全表(实现,出处见文末)。
- **codex 不会退回终端**,claude 不会搬到 app-server——这个不对称是结论。
- **v1 不做逐字流式**:transcript 在每个 item「完成」时整条渲染(权威终态),没有 token-by-token 打字机效果("看不清它实时在干嘛"的另一半,defer)。
- v1 暂不做 `turn/steer` 中途插话 / `resume`·`fork` / 额度面板 / 跨读 peer rollout(均 defer,见 tech-debt)。

**注意 — 别写回的旧方向**
- ❌ **codex 用"占位交互式终端"** —— 早期 codex 和 claude 一样接 SwiftTerm 终端,那只是没补真后端时的占位形态。现已搬到 `codex app-server` 结构化客户端;任何"codex 是终端"的描述都过时。
- ❌ **"claude + codex 统一 PTY、app-server 已弃"** —— 账本一度记错(方向翻过两次)。现状:claude 终端 / codex app-server。
- ⚠️ **协议字段曾按文字 reference 凭印象写、被 codex 静默丢、单测断言虚构字段=假绿** —— 已用本机 `codex app-server generate-json-schema`(0.137.0)dump 真协议逐字段比对,修了 4 个 inbound 解码 bug。**codex 每次升级都要重新生成协议核字段**,别凭印象。
- ⚠️ **codex 把"是否允许调 MCP 工具"作为一条 elicitation 下发**(不是 `*/requestApproval`):旧代码把所有 elicitation 一律 decline → 所有 crew 工具被自动拒、机长报到发不出。已修(对 `mcp_tool_call` 审批回 accept;真输入型 elicitation 仍 decline 但回包让 turn 继续)。
- ⚠️ **非审批的 server-request 一律静默丢 → turn 永不 complete「转圈不结束」** —— codex 在 turn 里发 elicitation 等客户端回复,旧代码不答 → codex 永等。已根治(未建模的 server-request 一律回 JSON-RPC error 兜底,绝不静默丢)。
- ⚠️ **codex 申请「额外权限」(`item/permissions/requestApproval`)的回包形状没正确建模**(回了 `{decision}`、真 schema 要 `{permissions}`)—— 潜伏 bug,只在 codex worker 申请额外权限时撞,已记 tech-debt;常规命令/改文件审批不受影响。
- ⚠️ **`config.toml` 的 `model_reasoning_effort` 会覆盖 turn 级 effort** —— 所以 effort 经 spawn 时 `-c model_reasoning_effort=<e>` 设定(确定性路径);非法 effort 字符串会**静默回落**(无报错),客户端要自校验。

**现状** — 🟨 协议字段已对真 schema 校准、两个真 bug 已根治并 GUI E2E 验、单测全绿,活体像素渲染 + 完整真机 QA 是尾巴。

- ✅ **协议对真 schema 校准**(本机 codex-cli 0.137.0 已登录,2026-06-16):`generate-json-schema` dump 逐字段比对,抓修 4 个 inbound 解码 bug;探得认证自动继承 `~/.codex/auth.json`;真跑一轮 turn,消息/推理/agent 消息逐字段吻合 + 真计费 token tick。
- ✅ **机长 `post_to_crew` 被拒 + session 卡死两个真 bug 已根治并 GUI E2E 验**(2026-06-17):真 PendingCrew.app 起 codex 机长 → 右栏 transcript 显示 `crew.post_to_crew · completed` + 群聊白板出现机长报到(computer-use 驱动验、截图存档)。
- 🟨 **`CodexTranscriptView` 活体像素渲染**(在 app 里看一整轮 transcript 真实排版)并入 Mac GUI QA(#342 / #290)。
- 🟨 额外权限审批回包形状未建模(上「注意」)、v1 不做逐字流式,均记 tech-debt。

**出处指针**(向下,不在手册重抄):Runner 形态与取舍 → [`pendingcrew/features/runner-backends.md`](../../pendingcrew/features/runner-backends.md);协议实证(transport / thread·turn / 审批 / 计费 / effort / rollout)→ spec `docs/superpowers/specs/2026-06-05-codex-app-server-reference.md`(codex 0.137.0 实测,**每次升级重生成**);集成设计 → spec `2026-06-14-codex-app-server-backend-design.md`。
