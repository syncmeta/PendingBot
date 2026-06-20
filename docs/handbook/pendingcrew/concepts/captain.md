# Captain(机长)

> 每个 [crew](crew.md) **有且仅有一个**的代理人格,把人类的模糊意图变成可执行的 session、把杂音过滤成只需人类拍板的几件事。相关:[crew](crew.md) · [人在回路](human-in-the-loop.md) · [Crew DAG 与责任比例](dag-and-responsibility.md)。

**逻辑**

- **Captain 不是一个特殊的技术实体**,而是**一个被打上机长标记的本地 session** —— 和普通 worker session 跑在同一台本机、走同一套接口,只是:
  - ① 启动时多带一个机长标记(本地 helper 的 `--captain` / `isCaptain`),解锁两个机长专用工具;
  - ② 注入了机长 persona(prompt)。
- 除此之外,**captain 在技术接口上不特殊**。它跑的就是一个 coding agent(claude / codex),天然具备读代码、理解上下文的全部能力。
- Captain 的职责(产品意义上):
  - **先搞清人类想要什么** —— 含糊的需求先在群里聊清楚、必要时拆成几块,别急着开工。
  - **给 crew 起名** —— crew 刚建出来时名字是个随机地名(占位);captain 摸清这个 crew 在做什么后,用机长工具 `rename_crew` 把它改成一个**短标签**(一个概括,不是一句描述,例「鉴权重构」「深色模式」)。一两次就够,别反复改;人类自己已起了有意义的名字就别动。
  - **同步关键节点** —— 重要进展 / 决定 / 卡点在群里发一条让大家知道,不必事事汇报。
  - **接 worker session 的待决策(triage)** —— worker 用 `ask` 提问时,系统把待决策先推给 captain。captain 是**第一响应人**:在它判断范围内能拍板的(方向选择、技术取舍、澄清),直接用机长工具 `answer_decision` 答,发起的 session 立刻拿到答复继续;拍不了的(花钱、删数据、对外发布、人类明确关心过的、拿不准的),转述 + 给倾向,@ 人类来拍。

**为什么**

- **Captain 是"人格"而非"调度器"** —— 把模糊意图变可执行、把噪音收成几件待拍板的事,这件事本身需要判断力,适合交给一个 LLM 人格去做,而不是一套硬编码的编排状态机。让 captain 就是一个普通 session(只换了 persona + 多两个工具),就不必为"机长"单独造一套机制。
- **审批归 coding agent 的 harness,不归 captain** —— 这是一条**刻意的边界**。captain 负责的是**业务决策**的第一道分诊(方向对不对、要不要做),它能 `answer_decision`;但**权限审批**(computer-use 这类敏感的桌面 / shell / 文件操作)走的是各 coding agent 自己的 PreToolUse 审批门,**直接送人类**,captain 既看不到也管不着。业务判断可以委托给一个 AI 人格,但"是否授权一次危险操作"必须是人类的事。

**用在哪·长什么样**

- **机长卡 / composer**:客户端拿到 crew 的 captain 身份(`captainBotId`)后,显示 captain card、把聊天输入框接到 captain 上。
- **白板里**:captain 的发言和各 worker、人类一样在群聊流里,显示成「机长」。
- **新建 crew 时**:人类选 captain 用哪种 coding agent(claude / codex);captain 的"身份"由系统自动生成。

**示例** — crew 出生时叫「张家口」。人类在群里说「帮我把登录这块的鉴权重构一下,现在太乱」。captain(一个本地 codex session)先追问几句把范围聊清楚,然后调 `rename_crew("鉴权重构")`,侧栏那一行立刻变。范围清楚后一个 worker session 接走编码任务,跑到一半用 `ask` 问「鉴权中间件放路由层还是全局?」——这条待决策先推给 captain,captain 判断这是它能拍的技术取舍,用 `answer_decision` 答「放路由层,按现有写法」,worker 立刻继续。再往后 worker 要执行一次会改很多文件的命令,这触发**权限审批**,**不**经 captain,直接弹给人类。

**边界**

- **一个 crew 一个 captain**,不多不少;captain 不是"群主"也不是必经的指挥层 —— worker session 之间、worker 与人类之间都能在白板上直接说话,captain 是协调者不是网关。
- **captain 只做业务分诊,不做权限审批** —— 这条边界不要混淆:能 `answer_decision` ≠ 能批准危险操作。
- captain 的机长专用工具当前 = `answer_decision`(答待决策)+ `rename_crew`(给 crew 起标签名)两个;普通工具(`post_to_crew` / `read_whiteboard` / `ask`)是所有 session 都有的。

**注意 — 已死的旧方案 / 易错点(别按它实现)**

> ⚠️ 本概念是全手册过时风险最高的几篇之一。详见 `docs/stale-model-audit-2026-06-15.md`(R1)。

- ❌ **captain 是一个 edge bot、由 edge `bot-reply` 注入机长 persona、被白板消息唤醒去跑** —— 老 spec(§6.3)的说法。**现状:captain 唯一形态 = 本地 session**(跑在 PendingCrew 本机),edge **不再**唤醒任何 "edge-bot captain"。这个转向定调于 2026-06-10「接合 v2」(本地为家、edge 是邮差),2026-06-16 审计**实删**了 edge 侧整套残留。
- ❌ **captain 有 `start_session` / `create_child_crew` / `recruit_temp_bot` / `request_permission` 这一组 edge 编排工具** —— 这些 edge 工具**已全删**。captain 现在的工具走**本地 MCP**(`apps/pendingcrew/Sources/Mcp/McpServer.swift`):所有 session 都有 `post_to_crew` / `read_whiteboard` / `ask`,captain 额外解锁 `answer_decision` 和 `rename_crew`。
- ❌ **审批由 captain 处理或经 captain 转交** —— 现状:权限审批不归 captain,系统直接送人类。captain 自己的 prompt 就写明「权限审批不归你管」(`crew-captain.zh.md`)。
- ⚠️ **`decisions.md` D4「captain 4 种来源」已部分过时,谨慎引用。** D4(2026-06-01)写 captain 有 4 种来源(含 `spawned_by_captain` 等)。但当前活的建 crew RPC(`create_crew_with_captain`)只接受 **2 种** `captain_source`:`reuse_bot` 和 `system_generated`,且**客户端实际只用 `system_generated`**。`spawned_by_captain` / `create_child_crew` 那套只在 legacy 的 `/v1/crew`(单数)路由和旧迁移注释里还有引用,不是当前主路径。引 D4 前先核对到这一层。
- ⚠️ **captain prompt 与本地 MCP 工具集对不齐(已知尾巴)**:`crew-captain.zh.md` 仍把 `start_session(brief, runner?)` 写成机长工具,但本地 MCP server(`McpServer.swift`)**没有实装 `start_session`**(只实装了 `answer_decision` / `rename_crew` 两个机长工具)。prompt 描述领先于实现,以代码为准——"captain 拆出 worker session"的具体落地工具仍待补齐。

**现状** — 🟨 **代码已落,本地逻辑通,真机 GUI E2E 有尾巴。**

- ✅ **edge bot-当-captain 编排面已全退役** —— 已验证的删除(见上)。
- ✅ **captain 本地工具(`answer_decision` / `rename_crew`)+ worker 待决策 triage** —— 本地逻辑(MCP server dispatch、控制通道 round-trip)经单测跑通,PendingCrew macOS build 绿。
- ✅ **captain 报到链路** —— 2026-06-17 修了「codex session 的 crew 工具被自动拒」的卡死后,真 PendingCrew.app 起 codex 机长 → `post_to_crew` 报到 → 群聊白板出现机长报到消息,GUI E2E 已过(computer-use 驱动验、截图存档)。
- 🟨 **真机尾巴**:① captain 真机改名 E2E(真起 captain session 调 `rename_crew` → 看侧栏即时改名)并入 Mac GUI QA(#290 / #342),未单独跑;② "captain 把模糊意图拆成 worker session、worker `ask` → captain `answer_decision`"的完整编排 E2E 仍待真机走一遍,且依赖上面"`start_session` 工具未实装"的尾巴先收口。
