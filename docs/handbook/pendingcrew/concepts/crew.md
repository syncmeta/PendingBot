# Crew(任务群组)

> PendingCrew 最基础的组织单位。Crew = **一组群聊 + coding agent 的权限边界**。相关:[Captain(机长)](captain.md) · [Crew DAG 与责任比例](dag-and-responsibility.md) · [运行位置与 machine](runtime-location-and-machine.md) · [白板](whiteboard.md)。

**逻辑**

- **Crew 是一个任务群组**,表现成一条即时通信形式的群聊。成员可以是:人类、captain、正在跑的 coding session(claude / codex 子进程)、被拉进来作成员的 bot 或他人账号。大家在同一条聊天流(白板)里说话。
- **Crew 同时是 PendingCrew 里的权限边界**:**没有 crew,就起不了 coding agent**。要让一个 claude / codex 真正在某台机器上跑起来,它必须挂在某个 crew 之下。crew 给它界定了四件事:
  - **工作目录** —— 它默认在哪个 cwd 干活;
  - **所属机器(machine)** —— 它跑在哪台机器上(本机 / 将来的远端);
  - **责任主体** —— 谁为它的花销负责(`responsible_subject_id`,可能是个人 user 或群 group);
  - **发声渠道** —— 它能往哪儿说话(这个 crew 的白板)。
- **"裸起一个 agent、不属于任何 crew"不是一条合法路径** —— PendingCrew 不提供"全局起一个 agent"的入口。
- 每个 crew 还带:一个 captain 身份、一个标签式名字、以及与其它 crew 的父子边(DAG)。

**为什么**

- **把"能不能起 agent"钉死在"先有 crew"上**,是因为 coding agent 能读写文件、跑命令、控制桌面,是高权能主体。crew 这道门保证每个 agent 一出生就有明确的责任主体(谁付钱)、工作目录、和发声渠道,不存在游离于组织之外、无人负责的 agent。
- 这与 PendingCrew 的 **local-first** 立场一致:crew 是本地这台机器上把一组协作收拢起来的容器,而不是一个云端调度对象。

**用在哪·长什么样**

- **侧栏**:每个 crew 是一行;crew 视觉上**嵌在它所属的 machine 组下**(侧栏按机器分组,每台机器一可折叠组,本机组置顶且带「+」新建)。新建出来先显示一个随机地名,captain 摸清这个 crew 在做什么后改成短标签。
- **crew 群聊(白板)**:打开一个 crew 就是进它的群聊。captain、各 worker session、人类的发言都在这条流里,发送者显示成可读的名字(如「机长」「Claude Code · abc123」「人类」)而不是裸 uuid。
- **新建 crew 表单**:人类选 captain 用哪种 coding agent(claude / codex,当前默认 codex)、选工作目录(默认 `~/CrewGround/<地名>`)、机器超过一台时选机器。标题留空就先用随机地名,之后交给 captain 改。captain 身份由系统自动生成(见「注意」)。

**示例** — 你在 PendingCrew 新建一个 crew,captain 跑 codex,工作目录指到某个仓库。crew 出生时叫「张家口」(随机地名)。你在群里说「帮我把登录这块的鉴权重构一下」。captain(一个本地 codex session)被拉起、自报到群里,把 crew 改名成「鉴权重构」,侧栏那一行立刻跟着变。随后一个 worker session 接走具体编码任务——它能跑起来,正是因为它挂在这个 crew 之下,继承了 crew 的工作目录、机器、责任主体和发声白板。

**边界**

- **没有 crew 就没有 agent** —— 不提供全局起 agent 的入口。
- **一个 crew 一个 captain**,不多不少(见 [captain](captain.md))。captain 不是网关:worker session 之间、worker 与人类之间都能在白板上直接说话。
- 本篇只讲 crew 作为「组织单位 + 权限边界」。crew 之间的**父子 DAG 与责任分摊**见 [dag-and-responsibility](dag-and-responsibility.md);crew "跑在哪台机器上"见 [runtime-location-and-machine](runtime-location-and-machine.md);白板这条群聊通信本身见 [whiteboard](whiteboard.md) 与 feature `session-crew-comms`。

**注意 — 已死的旧方案 / 易错点(别按它实现)**

> ⚠️ 本概念是全手册过时风险最高的几篇之一。2026-06 之前的老 spec(`2026-05-28-…-product-design-v2.md` §6)把整套 crew 编排描述成 **edge bot 当 captain** 的体系——**这套大部分已退役**。详见 `docs/stale-model-audit-2026-06-15.md`(R1)与 `docs/progress.md` 2026-06-16「审计处置」。

- ❌ **edge 唤醒 "edge-bot captain" 跑群回合** —— 老 spec 让 edge `bot-reply` 在群回合里把某个 bot 当 captain 唤醒去跑。已**实删**(2026-06-16 审计处置,净 -1341 行):`start_crew` 等 edge 编排工具、captain persona 注入、crew-comms 唤醒、crew-proposal / decide 端点全退役。**凡在 edge `bot-reply` 里看到 captain 编排的代码 / 注释,都是已废残留或已删,别当现状。**
- ⚠️ **`crews.captain_bot_id` 字段 + `create_crew_with_captain` RPC + `POST /v1/crews` 端点是有意保留的活路径**,不是残留 —— 它们是**客户端建 crew 的活路径**。建 crew 时系统生成一个 captain bot 作为这个 crew 的 **captain 身份载体**(客户端据此显示机长卡、接 composer)。所以"captain bot"现在的含义是"crew 的 captain 身份标识",**不再是"一个会被 edge 唤醒去回复的 bot"**。要彻底让 crew 不带 captain bot 身份,是更大的客户端联动改造,记在 tech-debt 待定。
- ⚠️ **建 crew 时 captain 来源现在只有 2 种**:活的 `create_crew_with_captain` RPC 只接受 `reuse_bot` 和 `system_generated`,且**客户端实际只用 `system_generated`**(本地新建表单把 captain 恒定为系统生成,人类只选用哪种 agent)。老 `decisions.md` D4 说"4 种来源"已部分过时(见 captain 篇与 dag-and-responsibility 篇)。

**现状** — 🟨 **代码已落,本地逻辑通,真机 GUI E2E 有尾巴。**

- ✅ **edge bot-当-captain 编排面已全退役** —— 审计处置 6 commit 验证全绿(edge typecheck 0 + 623 vitest),已合 main、已部署 prod。这是已验证的删除。
- ✅ **侧栏按 machine 分组 + 新建 crew 表单** —— 本机 GUI 像素验过(2026-06-16,#369 / #342),侧栏组头 + 组内 crew + 本机「+」、新建表单逐项与 spec 吻合(未真建 crew 以免污染用户真 crew)。
- ✅ **captain 报到链路** —— 真 PendingCrew.app 起 captain → 报到消息出现在白板,GUI E2E 已过(2026-06-17,见 captain 篇)。
- 🟨 **真机尾巴**:"建 crew → captain 改名 → 派 worker session"的完整编排端到端真机 QA 仍是已知尾巴(并入 Mac GUI QA #290 / #342)。本地组件验过、整链真机走一遍待补。
