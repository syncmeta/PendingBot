# Chunk 2 —— 本地 captain-session + 多 session 单聊

**2026-06-10**。承接合 v2 定调(`2026-06-10-pendingcrew-pendingbot-integration-v2.md`):captain 唯一形态 = **本地 session**。本 spec 定义它怎么活起来,以及配套的多 session 单聊 / 未读 / 跳转模型(用户已定调:"和一个 session 单聊,点进去就是进入这个 session;captain 和 reporter 标未读;点卡片直接到发起的 session")。

## 模型

### 1. 多 session 运行时(单聊的地基)

- `CrewSessionRunner` 从"一个 `current`"改为**每 crew 多个并存 run**(`runs: [CrewSessionRun]` + `selectedRunId`)。每个 run 仍是一个内嵌 PTY 终端(AgentTerminalSession)。
- `CrewSessionRun` 加 `role`(`.captain` / `.worker`)与显示名。
- **右栏 = 当前选中 session 的单聊页**(现有形态不变:transcript + 内联待办卡片 + composer)。顶部加 **session 切换条**:captain 置顶 + workers 按启动序;每项带**未读角标**。点击 = 切换(终端视图换、composer 路由到选中 run)。
- 中栏群聊里的消息/🔔 通知**可点跳转**:白板条目带 `senderSessionId` → 点击把右栏切到那个 session(卡片"点击直接到这个 session")。

### 2. Captain session

- **本体**:一个普通的本地 claude session,差异只在配置:
  - persona:`crew-captain.zh.md`(已 bundle)追加进 `--append-system-prompt-file`(与世界观同通道);
  - crew-comms MCP 照常(post_to_crew / read_whiteboard);
  - **多一个 captain 专属 MCP 工具 `answer_decision`**(见 §3),由 `--mcp-serve --captain` 标志开启;
  - 不 gate 权限 hook 的 computer-use 之外的差异(captain 也跑 auto mode)。
- **生命周期(MVP)**:右栏 session 条上有固定的 captain 位,**手动启动**("启动 captain")。启动后常驻(PTY 活着)。自动启动/常驻策略留 crew 设置(后排,token 成本考量)。
- **唤醒 = app 注入**:PendingCrew app(已有 1.5s 轮询基建)观察 `LocalApprovalStore`:出现新的 **pending decision** 且 captain run 在跑 → 往 captain 的 PTY `run.send()` 注入一条用户回合:
  > 「有新的待决策 #\<id\>(来自 session \<sid\>):\<question\>。能拍板就用 `answer_decision` 答它;拍不了就在群聊白板发消息 @human 说明需要人类决策的理由与你的建议。」
  - captain 没在跑 → 不自动启动(MVP),未读角标 + 白板 🔔(v1 路径)兜底,人类自己处理或先启动 captain。
- **权限审批(permission)不走 captain** —— 维持 v2 ask-approval 定调:直达人类待审批(内联卡片)。captain 只管**决策(decision)**。

### 3. ask 的 captain-first triage(闭环)

- worker session 调 `ask` → raise decision + 白板 🔔(均已有)→ app 唤醒 captain(§2)。
- captain 两个出口:
  1. **能答**:调 `answer_decision(reqId, reply)` → `LocalApprovalStore.answer` → worker 的 long-poll 解开,拿到 captain 的答复续跑。
  2. **不能答**:`post_to_crew` 发 @human 消息(思考后的转述+建议)→ 人类在中栏看到 / 在 worker session 的内联卡片答(v1 路径全保留,captain 答不答都不阻塞人类直接答)。
- `answer_decision` 只在 captain 的 mcp-config 开启(`--captain` 标志),worker 拿不到 —— 防 worker 自问自答。

### 4. 未读模型(MVP 从简)

- per-session `lastViewedAt`(app 内存 + UserDefaults 持久)。
- 未读数 = 该 session **pending 的待决策/待审批数** + 该 session **lastViewed 之后发到白板的消息数**(`senderSessionId` 匹配)。
- 切到该 session 即清(更新 lastViewedAt)。角标显示在 session 切换条上。

### 5. Reporter(并入 captain,不另起实体)

用户原始意图"专门 session 汇报新审批"在 MVP 由两件已有/本 spec 件覆盖:权限审批的白板 🔔(v1 已有,直达人类)+ captain 对决策的 triage/@human 转述(§3)。**不单独做 reporter session**;若后续发现 captain 兼职不够,再拆。

## 不做(本 chunk 边界)

- captain 自动启动 / 空闲超时回收(留 crew 设置)。
- 推送到手机(那是接合 v2 的信箱/遥控块)。
- edge 信箱 / 远端成员(接合 v2 block 3)。
- codex captain(claude 先行,codex 跟 backend 一起)。

## 任务拆解(subagent 顺序执行,每 task build 自验 + 小单元 commit)

1. **T1 多 run 运行时**:`CrewSessionRunner.runs`/`selectedRunId`/`start` 追加不顶替/`stop(runId)`;`CrewSessionRun.role/displayName`。
2. **T2 右栏切换条**:session bar(captain 位 + workers + 未读角标占位)、选中切换终端与 composer、`SessionApprovalCardsView` 跟随选中 run。
3. **T3 captain 启动**:captain 位的「启动 captain」→ 组配置(persona 追加 + `--captain` mcp 标志)→ 以 `.captain` role 跑。
4. **T4 `answer_decision` MCP 工具**:`McpServer` 加工具(仅 `--captain` 时暴露)→ `approvals.answer`;swiftc driver + XCTest。
5. **T5 唤醒注入**:app 轮询 pending decisions → captain 在跑则 `run.send(唤醒文案)`;去重(每 reqId 只注入一次)。
6. **T6 未读 + 跳转**:lastViewed 存取、角标计数、中栏消息/🔔 点击切右栏 session。
7. **T7 captain persona 更新**:`crew-captain.zh.md` 加 triage 职责段(answer_decision / @human 转述规范)。
8. **T8 账本**:progress / roadmap 对账。

**验证策略**:T1/T2/T3/T5/T6 = macOS build + 必要处 swiftc driver(纯逻辑);T4 = driver 断言 + XCTest;活的 captain triage 端到端(真 claude 进程)= 真机尾巴,数据层与注入路径全部 headless 验。
