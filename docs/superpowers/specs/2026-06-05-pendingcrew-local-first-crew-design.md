# Spec — PendingCrew local-first crew（captain = session，本地自洽，edge 可选）

**2026-06-05 重构**。**这份是 crew 级架构的事实源**，取代早先 `2026-06-05-pendingcrew-session-crew-comms-design.md` 里"session 接 edge crew-comms"的框架。那份里**session 级机制**（启动带指令 §1 / 状态 §5 / 额度 §7 / 长跑韧性 §8 / per-session 配置 §11 / 第三方 UI §12）+ `2026-06-05-codex-app-server-reference.md` **仍然有效**（它们本就是本地 session 的事，不变）；本 doc 只重构 **crew 级**（captain / 白板 / comms / prompts / 权限），从 edge-first 改成 local-first。

---

## 0. 部署模型（钉死）—— local-first，cloud-optional（形如 Claude Code / Codex）

- **PendingCrew（Mac app，可独立开源、自包含）= 本地环境**。**crew + captain + session 全在本地跑**（BYOK：用户自己的 claude/codex 订阅 + 自己的机器），**不依赖 PendingBot**。
- **PendingBot 云端 = 可选三层叠加**（只在 `.logged` 模式启用）：
  1. **Fly 云端执行** —— session 跑 Fly 机器而非本地 Mac；
  2. **移动端 remote control** —— 从 PendingBot iOS 遥控 Mac/Fly 上的 crew（= 早先 T4.5 跨端）；
  3. **PendingBot 角色/账号直接参与** —— PendingBot 的 bot/人类账号作为成员进 crew + subjects/钱包计费。
- 类比：Claude Code/Codex = 本地 CLI + 可选云环境 + 移动遥控。**PendingCrew 同形。**

**两模式（代码已有骨架）**：`AppModel.mode` ∈ `.byok`(本地) / `.logged`(edge 叠加)。`.byok` 走 `LocalCrewStore`、session 不建 serverLink。**但本地半边目前是 stub**（下面 §现状）。

### 现状缺口（`你看看` 的结论）
- `LocalCrewStore` 存本地 crew，但 **captain 只是占位符**（"用户起的名字 + 自生成 botId 纯字符串；后续 Phase 才接真本机 captain template + 模型调用"）。
- **crew-comms（白板 / post_to_crew / dispatchGroupTurn / captain 唤醒）是 edge-only** —— BYOK 本地模式下中栏群聊走 `loggedAPIClient`，**本地没有白板总线 → 本地 crew 群聊跑不起来**。
- edge captain（`captain_bot_id` + bot-reply + persona 注入 + 编排工具）**只服务 `.logged` 模式**，不服务本地。
- **整套 crew-comms + captain 是围绕 edge-bot + PendingBot subject/钱包建的**。`.byok` 当时只搭了 store 骨架。

→ 本 spec 的活儿 = **把本地半边从 stub 做成自洽核心**，edge 退成叠加层。

---

## 1. captain = 本地 session（不是 edge bot）

**在所有模式下，captain 就是一个 claude/codex 实例**（跟 work session 同一个 `RunnerBackend`），区别只在 **persona + 工具**：
- **persona** = 机长世界观（本地 bundled prompt，§5）。
- **工具**（captain 专属，经 MCP 注入）：`start_session(brief, runner?, config?)` / `terminate_session(id, reason)` / `recruit_temp_bot` / `create_child_crew` / 以及普通成员的 `post_to_crew` / `ask_human` / 深查类。
- **被唤醒**：本地 crew 白板来新消息（人发话 / session 上报 / 需审批）→ **本地 dispatch**（dispatchGroupTurn 的本地版）给 captain-session 一个回合。无 edge。
- **生命周期**：captain-session 是 crew 的常驻成员（crew 开着就在），跟 work session 一样进 `CrewSessionRunner` 管理（但它常驻、不退）。

**好处**：local / cloud(Fly) / edge 三态**统一**成"captain 是个 session" —— prompt 统一本地、工具统一、`RunnerBackend` 统一。edge 的 `.logged` 模式可选择**仍用 edge-bot captain**（保留现有）或**也换成 session-captain**（统一，推荐后续）。

**待定/探针**：captain-session 用哪个默认 runner+model+effort（机长偏判断 → 高 effort）；常驻 session 的额度占用（captain 一直开着会吃订阅额度，要不要按需唤醒后 idle 降频）。

---

## 2. 本地 crew-comms（白板总线 + 唤醒 + ask_human，全本地）

`.byok` 模式 crew 的核心，**纯本地、无 edge/supabase**：

- **本地白板 = 本地 store**（`LocalCrewStore` 扩出一个 message bus；JSON 或 SQLite）。crew 的消息（人 / captain / 各 session / 临时 bot）按时间序追加。
- **post_to_crew** = 本地 MCP 工具 → 写本地白板。**read 白板** = 每轮经 hook/additionalContext 从本地 store 注入 session 上下文（§原 spec §3 的机制，数据源换成本地）。
- **读未读 + 空闲注入**（原 §3）= 本地：白板对每 session 有本地读游标；空闲+未读 → 注入"看一下白板"。
- **ask_human** = 本地 MCP 工具 → **本地 captain-session triage**（auto-resolve 明显的 / 升级到本地人类）→ 阻塞 long-poll → 人在 PendingCrew UI 答 → 返回。无 edge。
- **中栏群聊 UI** = 直接读本地白板 store（不走 `loggedAPIClient`）。

**`.logged` 叠加**：登录时，本地白板**可选镜像到 edge messages**（让 PendingBot 移动端遥控看 + 社交 bot 参与）；但**本地是真源**，edge 是 sync 投影。session/captain 仍只跟本地白板交互，mirror 由 PendingCrew 后台做。

---

## 3. crew 成员模型（本地）

- 本地 crew 成员 = **session(work) + captain-session + 人类(本机用户)** +（可选）临时 bot。
- **不强制 PendingBot 账号** —— 本地模式没有 subject/bot/钱包。member 用本地 id（`local-*`）。
- `.logged` 叠加：PendingBot 的 bot/人类账号**可加入**当成员（社交参与）；subjects/钱包计费只在 `.logged` 生效。
- **身份标签**（原 §10）= `{kind: claude_code|codex|human|captain, name}`，本地花名册 + 白板 sender 都带。

---

## 4. prompts 全本地（开源自带）

**crew 侧所有"在本地进程里跑的 agent"的 prompt → bundled 在 PendingCrew**（`Resources/Prompts/*.md` + 本地 loader），跟开源项目走、不依赖 edge/Langfuse：
- **session 世界观**（work session 读）。
- **captain persona**（captain-session 读）。
- 工具用法说明走注入的 MCP server instructions（也本地）。
- **edge/Langfuse 的 prompt** 只服务 PendingBot **后端 bot**（`.logged` 模式的社交 bot / 现有 bot-reply）；与本地 crew prompt **分家**（可由同一本地源 seed 到 Langfuse，但真源在本地 repo）。
- **捞回**：rebase 丢掉的 `bypass→auto mode` 修复 → 落进本地世界观 prompt（顺手修对）。

---

## 5. 权限/审批（auto mode + captain-session triage，全本地）

复用原 spec §9 的口径，**全部本地化**：
- **Layer 1 护栏（原生，保留）**：claude `--permission-mode auto`（autoMode 分类器）/ codex `--sandbox workspace-write` + `approval_policy=on-request`（**不开 auto_review**）。本地实证：auto mode 订阅可用、codex app-server 走订阅、审批 `approvalsReviewer:user` 可路由（见 codex 参考 §2）。
- **Layer 2 审批 = 本地 captain-session**：work session 的 `ask_human` / codex 的 `requestApproval` 协议事件 / claude `PermissionDenied` → 路由到**本地 captain-session** triage → 自动批明显的 / 其余 → **本地人类**（PendingCrew UI 审批卡）。captain = 唯一审批人，**非单独复核 agent**。
- 与沙箱正交（原 §8 containment）。

---

## 6. 复用原 spec / codex 参考（session 级机制，不变）

下列照旧（它们本就是本地 session 的事）：
- **启动带指令**（原 §1，claude argv / codex app-server initial message）—— **Plan 01 已落**（claude）。
- **worktree 隔离**（原 §8/§11）—— **Plan 02 已落**。
- **状态**（原 §5：transcript 回合边界 + statusLine / codex notify+events）。
- **额度**（原 §7：claude statusLine `rate_limits` / codex `account/rateLimits`）。
- **长跑韧性**（原 §8：PreCompact / SessionStart 重注）。
- **per-session 配置**（原 §11：model/effort/isolation，`SessionConfig` 已建）。
- **第三方 UI**（原 §12，license 核过）。
- **codex app-server 协议**（`2026-06-05-codex-app-server-reference.md`，本机实证全套）。

---

## 7. edge 可选叠加层（`.logged` 模式）

本地核心之上，登录后**可选**开：
- **社交参与**：PendingBot bot/账号进 crew、subjects/钱包计费（现有 edge crew-comms 退成 sync 目标 + 社交层）。
- **Fly 云执行**：session 跑 Fly 机器（现有 §8.2 unified runtime location 的云端臂）。
- **移动遥控**：PendingBot iOS 经 SessionProxyDO 看&控（早先 T4.5；现有 edge SessionProxyDO 保留服务这条）。
- 本地白板 ↔ edge messages **双向 sync**（本地真源，edge 投影）。

**edge captain（现有 edge-bot）**：`.logged` 模式可暂留（已落 main）；长期建议也换 session-captain 统一。

---

## 实施顺序（local-first 优先；claude 先行同前）
1. **本地 crew-comms 核心**：本地白板 store（扩 `LocalCrewStore`）+ 中栏读本地白板 + post/read 本地工具。
2. **本地 captain-session**：captain 作为常驻 session（persona + 编排工具 MCP）+ 本地 dispatch 唤醒。
3. **本地 prompts**：世界观 + captain persona bundled（捞回 bypass 修复）。
4. **session ↔ 本地 crew 接线**：world-view append-prompt + 白板 hook + crew-comms MCP 工具（local）。需 claude 机制 spike（hook/statusLine/MCP）。
5. **审批本地化**：ask_human/approval → 本地 captain triage → 本地人。
6. **codex backend**（app-server，参考已就绪）。
7. **edge 叠加**（social / Fly / 遥控 sync）—— 最后，可选。

## 待探针 / 待定
- captain-session 常驻的额度占用策略（按需唤醒 vs 常开）。
- claude 机制 spike（UserPromptSubmit hook 对注入输入 / statusLine 旁路 / MCP 自动放行）—— 仍要真机。
- 本地白板 store 选型（JSON 够不够 / 上 SQLite）。
- 本地 ↔ edge sync 的冲突/真源策略（`.logged` 时）。
- 本地 captain-session 怎么"被唤醒"（文件 watch / 进程内事件 / 给它的终端注入）。

## 暂不做 / YAGNI
- `.logged` edge 叠加层留最后；先把 `.byok` 本地核心闭环。
- 多 crew 并行的完整管理。
