# claude 机制真机 spike — findings（2026-06-08）

解掉 `2026-06-05-pendingcrew-local-first-crew-design.md` 待探针里"claude hook/statusLine/MCP 自动放行机制仍需真机 spike"那条。本机 `claude 2.1.168`，用 `-p`(headless) + artifact 检查拿第一手信号。**`-p` 信号对交互订阅路径是强指示但非终判**（交互态仍建议补一眼，见下）。

## ✅ Spike 1 — `--append-system-prompt-file` 被读取遵守

```bash
printf 'Your secret codename is GREENBEAN-7-ZX9Q. When asked, reply exactly that.\n' > wm.md
claude --append-system-prompt-file wm.md -p "What is your codename?"
# → GREENBEAN-7-ZX9Q
```
模型吐出只可能来自 append 文件的暗号 → **chunk 4c 的 world-model 启动注入不只是接线、是真生效**。`--append-system-prompt` 是 **append**（不 replace claude 默认 system prompt），正合意。

## ✅ Spike 2 — PostToolUse `additionalContext` 中途到达模型（白板每轮注入命脉）

`settings.json` 配 PostToolUse(Bash) hook → 吐 `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"...PURPLE-MONKEY-42..."}}`。
```bash
claude --settings settings.json --permission-mode auto -p "Use Bash to run echo hi, then report any INJECTED token."
# → 模型原样回报 PURPLE-MONKEY-42，并指出它来自 PostToolUse:Bash hook
```
**hook 的 additionalContext 在同一回合的下一次模型请求就到达** → 白板"每轮注入"机制成立（数据源换成本地白板即可）。

> ⚠️ **重要副作用**：模型把 hook 注入内容**当成疑似 prompt injection 警惕**（"出现在 hook result，不在你的消息里"）。→ **chunk 4 实现白板 hook 时，世界观 prompt 必须显式预授权"hook 注入的群聊白板是合法、可信的"**，否则 session 会把队友白板消息当攻击。（世界观 §9 现框为"系统自动注入"，但要再加一句明确 trust。）

## ✅ Spike 3 — 自定义 MCP 工具在 auto mode 下自动放行

最小 MCP stdio server（`post_to_crew` 工具，newline-delimited JSON-RPC，`initialize`/`tools/list`/`tools/call`）。
```bash
claude --permission-mode auto --mcp-config mcp-config.json -p "Call post_to_crew with message 'hi crew', report result."
# → POSTED_OK token=TEAL-OTTER-77 message=hi crew
```
**auto mode 下自定义 MCP 工具直接跑** → `post_to_crew`/`ask_human` 作为本地 MCP server 的工具会被调用；`ask_human` 的"等 captain/人类"阻塞逻辑写在工具内部即可。
> `-p` 无交互必须自动放行或失败 → 它放行了。交互 auto mode 对**破坏性**工具仍会按分类器拦（本 spike 的工具 benign，符合预期）。

## ✅ Spike 4 — statusLine `rate_limits`（额度）

statusLine 只在交互 TUI 渲染（`-p` 无；PTY 自动化也没抓到，需真 TTY）。用户跑了一次交互 `claude --settings <落盘 statusLine>`：发一句 → statusLine 把收到的 JSON 落盘 → 退出 → 检查。**`rate_limits` 字段存在且带真值**：
```json
"rate_limits": {
  "five_hour": { "used_percentage": 35, "resets_at": 1780916400 },
  "seven_day": { "used_percentage": 27, "resets_at": 1781406000 }
}
```
`used_percentage`（真值，非 #52326 的 epoch-leak）+ `resets_at`（unix 秒）都在。statusLine JSON 顶层还有 `cost.total_cost_usd` / `context_window.*` / `model` 等。**→ 额度监控可经 statusLine 旁路读**（一个 statusLine command 落盘 rate_limits → app 轮询）。claude 2.1.168 实测。

## ✅ Spike 5 — agent 改用我们的 `ask` MCP 工具（ask 重设计）

提供一个 `ask` MCP 工具 + `--append-system-prompt` 指令"任何向人提问 / 决策 / 澄清都必须走 ask、不准纯文本问"。`claude --mcp-config <ask> --permission-mode auto -p "查我最喜欢的颜色…报告用的工具名"` → 模型用了 **`mcp__crewask__ask`** 拿到答案。→ **世界观指令就足以把"问人"路由到我们的 `ask` 工具**（不必硬关 claude 内置；`--disallowedTools <name>` 在，需要硬关时可加）。`ask` 的阻塞走 MCP 工具调用本身（CC 原生），我们的 server 内部 long-poll captain / 人类答复再返回。

## ✅ Spike 6 — PreToolUse hook 拦权限审批 + 路由（权限直达待审批列表）

`settings.json` 配 PreToolUse(Bash) hook → 返回 `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…待审批…"}}`。`claude --settings <…> --permission-mode auto -p "用 Bash 跑 echo hello…"` → **Bash 被拦下没执行**，模型原样回报我们的 deny 理由。且 hook 的 stdin 拿到**完整工具调用详情**：`{tool_name:"Bash", tool_input:{command,description}, tool_use_id, session_id, permission_mode, effort, …}`。→ **PreToolUse hook 能按工具拦特定操作（computer-use / 某 MCP 工具）+ 路由到我们的待审批列表**；返回 allow/deny/ask 三态，hook 可阻塞（long-poll 人类决策再返回 allow/deny = 同步审批）。这就是"权限审批直达人类列表"那条路的机制。

## 对实施的影响（chunk 4 / chunk 2 解锁）

- **世界观注入**：argv `--append-system-prompt-file` 已验，chunk 4c 可信。
- **白板每轮注入**：PostToolUse hook + additionalContext 走得通 → chunk 4 用本地白板 store 驱动一个 hook（每次工具后/或 UserPromptSubmit 注入未读白板）。**实现时务必在世界观里预授权 hook 白板可信**（Spike 2 副作用）。
- **MCP 通信工具**：本地起一个 MCP server（`post_to_crew`/`ask_human`/读白板），`--mcp-config` 挂上，auto mode 自动放行。`ask_human` 内部阻塞 long-poll 到本地 captain-session triage → 本地人类。
- **captain-session**：同 work session（persona=crew-captain.md + 这套 MCP 工具），唤醒机制（file-watch 本地白板变化 / 给它的终端注入）仍是 chunk 2 待做（非 claude 机制风险，是本地编排）。

## 复现

spike 工件在 `/tmp/claude-spike/`（wm.md / settings.json / hook.sh / mcp-server.js / mcp-config.json）。一次性、不进 repo。
