# 人在回路(human-in-the-loop)

> agent 跑到一半需要人介入时怎么办——这是**交互**,不是审批。本篇讲 PendingCrew 的人在回路模型:agent 用 `ask` 请人介入,captain 第一响应、答不了再沿 crew DAG 溯源到真人;以及「直达真人 / 层层上溯」两种模式。相关:[Crew 与 Captain](crew.md) · [Session 与世界观](session-and-world-model.md) · [本机子进程安全](subprocess-safety.md)。

## 逻辑

session 跑的 coding agent 在 **auto mode(非 bypass)**下运行:常规、可逆的操作(读写文件、跑命令)自己做,**不做「一个个动作都要批」的细粒度门禁**。我们要的是**交互**——偶发的、agent 自己解决不了、真需要人介入的事:要个方向决策、澄清一个含糊需求、拍个板。

分两类、两条路:

| 类 | 是什么 | 路由 |
|---|---|---|
| **决策(decision)** | 要人判断:方向 / 选择 / 澄清 | session 调 `ask` → **captain 先 triage**(能答就答)→ 真需人类的 → 沿 DAG 溯源到真人、@ 之 |
| **权限审批(permission)** | 是否允许一次敏感 / 高危操作(如 computer-use) | **不经 captain**,各 coding agent 的原生审批门拦下 → **直达人类**待审批列表 |

**为什么分两条**:决策是「判断」,大部分 captain 能扛、可以逐级消化;权限是「授权高危能力」,责任在人、不该被 captain 层层稀释,所以绕过 captain 直达人类。

**`ask` 这条决策路的溯源**:
- 工具叫 `ask`,**不是 `ask_human`**——因为第一个被问的是 **captain**,不一定是人。
- session 调 `ask(question)` → **阻塞**等回复(阻塞走 MCP 工具调用本身,是 CLI 原生的「卡住」机制,不另造)。
- 请求先到本 crew 的 captain:简单 / 明显的,captain 自决直接答回(大多数到这里就解决);拿不准的,captain 沿 crew DAG 往上溯源(父 crew 成员关系天然是上溯通道),够到真人责任主体就 @ 之。
- 人 / captain 的回复沿链路回到 `ask` 调用、解阻塞,agent 拿到答复继续。

## 为什么

- **「交互」而非「审批」是刻意的定位。** 早期设计把「自动模式」等同于 `--dangerously-skip-permissions`、并自建一套「approve this edit / approve this command」逐动作门禁——这跟实际产品意图不符,**已废弃**。逐动作审批既拖慢 agent、又把「是否危险」的判断从 CLI 自己的分类器手里夺过来重造一遍,纯属重复劳动且更差。现状:高危分级交给 claude / codex 的 auto mode 自己管,PendingCrew 只在 agent **主动请求介入**时把人接进来。
- **captain 先答,是为了不让每个小决策都惊动人。** 「坐在终端前回答的人」在 crew 里换成 captain;captain 是个有判断力的 LLM 人格,能拍的技术取舍 / 方向选择就地拍了,真需要人类的才上抛。这跟 Claude Code 子 agent 向上请求的套路一致——把噪音逐级消化,只把几件真需人拍板的事送到人面前。
- **权限直达人类,是因为「是否授权一次危险操作」必须是人的事。** 业务判断可以委托给 AI 人格,但 computer-use 这类敏感能力的授权责任在人,不该被 captain 转述 / 稀释。

## 用在哪 · 长什么样

- **两种溯源模式(用户可选)**:
  - **直达真人** —— 跳过中间 captain,请求一路冒泡到最近的真人责任主体并 @ 之。「我要亲自把关每一步」。
  - **层层** —— 每级 captain 能答就答,答不了才往上。深 DAG / 放权给上级 captain 时用。
- **人类侧呈现**:`ask` 来的决策、以及权限审批,在 PendingCrew 里以**待决策 / 待审批列表** + 群聊白板里的一条「🔔 待处理」通知出现。session 页本来就是「跟这个 session 单聊」,人在右栏 composer 就地答(决策给回复框、权限给允许 / 拒绝),写回即解 agent 的阻塞、agent 续跑。
- **溯源落点(@ 到谁)**:手动建的 crew → @ 该 crew 的人类成员;子 crew → 交给父 crew 继续上溯;bot 在 1:1 / 群里建的 crew → 那个 bot 回原聊天 @ 责任主体(对面用户 / 群)。

## 示例

worker session 重构到一半,要确认「鉴权中间件放路由层还是全局」。它调 `ask("中间件放路由层还是全局?")`,阻塞等。这条决策先推给 captain——captain 判断这是它能拍的技术取舍,直接答「放路由层,按现有 `requireXxx` 写法」,worker 立刻拿到答复继续,人类全程没被打扰。

稍后 worker 要跑一次会改动很多文件的命令——这触发**权限审批**,不经 captain,直接弹给人类一张卡。人在群聊看到「🔔 待审批」,点开,允许,worker 继续。

## 边界

- **不做逐动作权限门禁**(「approve this edit / command」)——交给 CLI 的 auto / bypass 模式。
- **不引 Agent SDK / `canUseTool` 回调 / `--permission-prompt-tool`**——用 CLI 原生的阻塞 + PreToolUse hook,不重造审批策略。
- **PendingCrew 自己不接管审批逻辑**,只做三件事:① 通知(让人 / captain 知道有待处理的)、② 待审批 / 待决策列表 UI、③ 答复入口。
- 权限审批的「需人批工具清单」当前只 gate `computer-use`;其余放行让 auto mode 管(见 [本机子进程安全](subprocess-safety.md))。

## 注意 — 已废 / 已改的旧模型(别写回)

- ❌ **工具叫 `ask_human`** —— 已改名 **`ask`**(因为第一个回答的是 captain,不一定是人)。旧 edge 的 `ask-human-mcp.cjs`(raise → long-poll → 返回 replyText 的 Node 实现)**已删**。
- ❌ **「自动模式 = `--dangerously-skip-permissions` + 自建逐动作审批门」** —— 整套已废弃,改成「auto mode(非 bypass)+ 偶发交互」。任何把人在回路写成「每个动作都要 approve / deny」的说法都是过时叙述。
- ⚠️ **审批不归 captain,这条边界别混。** captain 能 `answer_decision`(答业务决策)≠ captain 能批准危险操作。权限审批直达人类,captain 既看不到也管不着——这与 [Captain](captain.md) 里讲的是同一条刻意边界。
- ⚠️ **「超时 / 无人响应」策略待定**:默认无限挂起(跟本地用 claude 等自己答一样);「超时后 captain 兜底自决 or fail-loud」是开放项,未定。

## 现状

🟨 **机制 spike 实测验过、本地代码全落,完整 triage 端到端真机是尾巴。**

- ✅ **`ask` + 权限 hook 两机制 spike 实证**:`ask` 阻塞走 MCP 工具调用、权限走 PreToolUse hook deny/ask,均在实机 claude 验过。
- ✅ **本地实装**:`ask` 工具 + 权限 PreToolUse hook + 待决策 / 待审批本地 store + 群聊「🔔」通知 + 右栏内联答复卡片,代码全落,swiftc driver / 单测验过、macOS build 绿;codex 侧也修通了「crew 工具被自动拒」后报到链路 GUI E2E 过。
- 🟨 **captain-first triage 完整 E2E**:「worker `ask` → captain `answer_decision` 解阻塞 → 答不了 @人类」的活体端到端,需真起 captain session 走一遍,属已知尾巴(并入 Mac GUI QA)。当前 `ask` 在 captain 缺位时退化成「直达人类」路径已可用。
