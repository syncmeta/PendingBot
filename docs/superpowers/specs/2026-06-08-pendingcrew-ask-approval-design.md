# Spec — `ask` / 人在回路 / 审批（重设计，替换旧 ask_human）

**2026-06-08**。取代 `2026-06-02-crew-interaction-human-in-loop.md` 的旧模型（edge `ask-human-mcp.cjs`：raise→long-poll→返回 replyText）。两机制已 spike 实证（`2026-06-08-claude-mechanism-spike-findings.md` Spike 5/6）。细化 local-first spec §5 权限/审批。

## 0. 总纲（钉死）

- **agent 的"卡住/等待"用 CC/Codex 原生那套**，不重造。`ask` 是 MCP 工具，阻塞走 MCP 工具调用本身（CC 原生 block）；权限走 PreToolUse hook（原生）。
- **PendingCrew 只做三件事**：① **通知**（让人/captain 知道有待处理的）；② **待审批 / 待决策列表 UI**；③ **答复入口**。**不接管审批逻辑**。
- **关掉 claude 内置"问问题/选择"，改用我们的 `ask`**（PTY 里选项/打字对人不友好；Spike 5：世界观指令就能把"问人"路由到 `ask`，`--disallowedTools` 备用硬关）。
- 工具叫 **`ask`** —— **不是 `ask_human`**。因为第一个被问的是 **captain**，不一定是人类。

## 1. 两类、两条路

| 类 | 是什么 | 路由 | 机制 |
|---|---|---|---|
| **待决策（decision）** | 要人判断：方向 / 选择 / 澄清 | session 调 `ask` → **captain 先 triage**（能答就答）→ 真需人类的 → 在**最上层 crew（人类所在那个）@人类**（群消息，思考后） | `ask` MCP 工具（Spike 5）+ org-chart 逐级 |
| **权限审批（permission）** | 是否允许 computer-use / 用某个 MCP 工具 等 | **不经 captain**，**PreToolUse hook 拦下 → 直达人类待审批列表** → 一个**专门 reporter session** 在群里汇报新请求 | PreToolUse hook deny/ask + 阻塞 long-poll（Spike 6）|

**为什么分两条**：决策是"判断"，大部分 captain 能扛、逐级消化；权限是"授权高危/外部能力"，责任在人、不该被 captain 层层稀释，所以直达人类。

## 2. 三层权限（细化 local-first §5）

1. **auto mode 护栏**（claude 原生分类器）—— 常规、可逆操作自动放行；不可逆 / 破坏 / 外泄自动拦。**不重定义高危清单**。
2. **captain triage** —— 决策类先到 captain-session，能答 / 能批就地解决（"明显的问题代为批准"）。
3. **人类** —— 决策升级（captain 答不了 → @人类）+ 权限审批（PreToolUse hook 直达待审批列表）。

## 3. 机制（Spike 实证，照搬）

- **`ask` 工具**：我们的 MCP server（re-exec self 的 `pendingcrew-mcp` 加一个 `ask` 工具）。世界观 §10 指令"问人/决策/澄清必须走 `ask`、不准纯文本"。`ask` 调用 → server 内部把问题登记进**待决策列表** + **阻塞 long-poll** captain/人类的答复文件 → 返回答复文本给 agent（agent 续）。阻塞 = MCP 工具调用本身（CC 原生）。
- **权限 hook**：re-exec self 加 `--mcp-permission-hook` 模式（PreToolUse）。读 stdin 的 `tool_name`/`tool_input` → **若是需人批的工具**（computer-use / 指定 MCP 工具，按清单）→ 写**待审批列表** + 阻塞 long-poll 人类 allow/deny → 返回 `{permissionDecision: allow|deny, reason}`；**否则放行**（让 auto mode 决定）。

## 4. PendingCrew 侧（UI + 数据）

- **待审批 / 待决策列表**：每 crew 一个本地 store（扩 `LocalWhiteboardStore` 或新 `LocalApprovalStore`）。条目 = `{id, kind: decision|permission, sessionId, summary, payload, status: pending|answered, reply?, createdAt}`。人类看**最上层 crew** 的列表（逐级上报汇此）。
- **答复入口**：列表项 + 中栏交互卡（已有 `CrewInteractionCard`）就地答 → 写答复文件（`<dir>/<crewId>.<reqId>.answer` / decision），helper 的 long-poll 读到 → 返回。
- **reporter session**（权限那条）：一个专门 session 把新权限请求作为群消息 @人类（先简单：写白板一条 `permission_request` 卡）。
- PendingCrew = **通知 + 列表 + 答复**，不碰审批逻辑。

## 5. 依赖 / 落地顺序

- **`ask` 的 captain-first 主路径 依赖 captain-session（chunk 2，未建）**。在那之前 `ask` **退化成直达人类**（captain 缺位 → 直接进待决策列表问人）。
- **答复 UI / reporter session = GUI 活，端到端要真机验**。

**顺序**：① `ask` 工具（McpServer 加；先接"直达人类"退化路径 = 阻塞 long-poll 本地答复文件）+ 待决策 store + 单测；② 权限 PreToolUse hook 模式（re-exec self `--mcp-permission-hook`，按工具清单拦 + 阻塞 long-poll）+ 待审批 store + 单测；③ `prepareLocalCommsConfig` 把 `ask` 工具 + 权限 hook 接进 per-session mcp-config/settings；④ 世界观 §10 改成 `ask`（替换旧 ask_human 文案）；⑤ **删 `ask-human-mcp.cjs`**（去 Node）；⑥ 答复 UI + reporter（GUI，真机验时停下找用户）；⑦ captain-first triage 接 chunk 2。

## 6. 作废 / 删除

- 旧 `apps/pendingcrew/Resources/ask-human-mcp.cjs`（edge block-poll 模型）→ **删**。
- 旧 plan `2026-06-02-crew-interaction-human-in-loop.md` 的 ask_human 模型 → 被本 spec 取代（edge `crew-interactions.ts` 路由暂留，`.logged` 模式以后要不要复用另说；本地 BYOK 不碰它）。

## 7. 待探针 / 待定

- 阻塞 long-poll 的超时 / 取消语义（人一直不答怎么办 → 超时返回"无人响应，自行判断"？）。
- 权限 hook 的"需人批工具清单"怎么配（computer-use 一定；某些 MCP 工具按名单；其余放行让 auto mode 管）。
- reporter session 是常驻还是按需。
- captain 接上后，决策类"先 captain 后人类"的 long-poll 怎么串（captain 也是个 session，要先唤醒它答）。
