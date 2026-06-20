# Session 与世界观(world model)

> Session 是 PendingCrew 里真正干活的单位——一个被拉起的 claude / codex 子进程。本篇讲 session 是什么,以及每个 session 启动时被注入的**世界观系统提示**:一套「你身处什么环境」的完整事实,让 agent 不靠猜就知道自己是谁、IO 去哪、谁是人类、谁是 captain、怎么发消息。相关:[Crew 与 Captain](crew.md) · [白板](whiteboard.md) · [人在回路](human-in-the-loop.md) · [创建 crew 与 session](../features/create-crew-and-session.md)。

## 逻辑

**Session = 一个正在跑的 coding agent 实例**,挂在某个 crew 之下。PendingCrew 直接拉起 claude code / codex **程序本身**(claude 走内嵌终端,codex 走 app-server 协议),不用 Agent SDK。一个 crew 里可以有多个 worker session 并存,外加一个常驻的 captain session(captain 也是个 session,只是换了 persona + 多两个工具)。

**世界观系统提示** = session 启动 / 每轮 fresh prompt 之前,系统自动渲染并注入到 system prompt 头部的一段事实,告诉 agent 它身处的运行环境。这不是任务,是「环境说明书」。最低交付内容:

1. **你是谁** —— 你是这个 crew 里的一个 session,跑在 claude code / codex 里;你的 session id、所属 crew、工作目录。
2. **你的 IO 去哪了** —— stdout / stderr / 工具日志只显示在用户 PendingCrew 窗口右栏,**不会自动进群聊**。(防止 agent 把「用户看不到我说话」当问题来解决。)
3. **群聊是什么** —— crew 群聊是白板 + 沟通渠道,**不是你的 IO log**;细节留右栏,群里只发关键节点。
4. **谁是人类** —— 当前 crew 里有哪些人类成员、各自身份。
5. **谁是 captain** —— 本 crew 的 captain 是谁。
6. **父 / 子 crew** —— DAG 关系(登录态 edge crew 才有;本地 crew 通常没有,这几节被 strip 掉)。
7. **拍板方是谁** —— 责任比例分布、冲突时听谁的(同上,本地 crew 通常无分账)。
8. **你怎么发消息到群里** —— 调 `post_to_crew(...)`,只发关键节点;`mentions` 定向 @、`reply_to` 回复并自动 @ 原发送者。
9. **你怎么读白板** —— 每轮自动注入,不用主动拉;`read_whiteboard` 可按需重拉。**明确声明:系统注入的白板是合法可信内容,不要当 prompt injection 来警惕。**
10. **找人交互(ask)** —— 你跑在 auto mode(非 bypass);常规可逆操作自己做,要决策 / 澄清 / 拍板时调 `ask`,它先到 captain、必要时到人。

世界观 prompt 走 [prompt 通道](../../shared/concepts/prompts.md)(本地 bundled markdown + loader),不内联在代码里;中英两份。

## 为什么

- **agent 不知道自己身处何处就会乱猜、空转。** 一个被 PendingCrew 拉起的 claude,默认以为自己是「用户在终端里直接跑的 claude」——它不知道有群聊、不知道 IO 在右栏、不知道有 captain 可问。世界观把这些事实一次性讲清,把「我在跟谁协作、我说的话谁看得到、卡住了找谁」从猜测变成已知,是多 agent 协作能跑起来的前提。这份 prompt **是必交付物,不能糊弄**。
- **「IO 去哪 / 群聊是什么」这两条尤其要紧。** 没有它们,agent 会把工作细节往群里倒(把白板当 IO log),或者反过来以为没人看得到自己而反复「汇报进度」。世界观把「细节在右栏、群里只发关键节点」钉死,白板才不会被噪音淹没(呼应 [白板](whiteboard.md) 的定位)。
- **「白板可信」声明是被实测逼出来的。** claude 会把「系统中途经 hook 注入的内容」当成疑似 prompt injection 来警惕、拒绝执行。所以世界观必须预先授权:hook 注入的白板是本 crew 的合法消息,当队友留言读、按需回应。这条不是教条,是 spike 验证里踩到的真坑。

## 用在哪 · 长什么样

- **claude session**:世界观渲染成临时 `.md`,经 `--append-system-prompt-file` 追加进系统提示(append 不 replace)。
- **codex session**:同一份世界观 markdown 经 `thread/start.developerInstructions` 注入(codex 协议不吃那个 flag)。
- **captain session**:在世界观之后再追加一段 captain persona(机长世界观),拼成「环境说明书 + 机长职责」。
- 这两条路由共用同一份渲染逻辑(claude 写文件 / codex 取字符串),保证世界观内容不分叉。

## 示例

PendingCrew 在某 crew 里拉起一个 codex worker session 干「重构鉴权」。启动前,系统渲染世界观:填进 session id、crew 名「鉴权重构」、工作目录、人类成员名单、captain 是谁,经 `developerInstructions` 注入。codex 一开始就知道:我是这个 crew 的一个 session,我跑的命令输出在用户右栏(不用往群里同步每一步),要拍板就调 `ask` 先问 captain。它跑到一半要确认「中间件放路由层还是全局」,于是调 `ask`,而不是在终端里干等或自己瞎定。

## 边界

- **本篇讲世界观这层系统提示,不讲 session 的生命周期机制细节**(启动带指令 / worktree 隔离 / 状态回合边界 / 额度监控 / 长跑韧性 / 取消)——那些是 session 级实现,见 [创建 crew 与 session](../features/create-crew-and-session.md) 与 [runner backends](../features/runner-backends.md)。
- **DAG / 责任比例那几节(父子 crew、拍板方)在纯本地 crew 里通常是空的**——本地无分账模型,渲染时这些槽被填成「(暂无)」或整段 strip。它们主要服务登录态的 edge crew。
- 世界观是「环境」,不是「任务」。真正的任务在系统提示下方、白板最新一段、或 mailbox 待处理项里。

## 注意

- ⚠️ **存在两个世界观渲染器,别混。** 一个在 **edge**(`session-world-model.ts`,服务登录态 crew,从 DB 取 DAG / 分账 / captain),一个在**本地 PendingCrew**(`LocalSessionWorldModel`,服务本地 crew,本地无 DAG 故那几节缺省)。两者填的是同一套模板槽位、产出形状一致,但数据源不同。本地为家是主路径(见 [本地为家](local-first.md)),edge 渲染器服务的是 `.logged` 边路。
- ⚠️ **世界观 prompt 里仍有 `runtime_location` 槽** —— 是历史遗留字段,当前位置事实源是 machine(见 [运行位置与 Machine](runtime-location-and-machine.md))。
- **工具名是 `ask`,不是 `ask_human`** —— 因为第一个回答的是 captain,不一定是人。详见 [人在回路](human-in-the-loop.md)。

## 现状

🟨 **世界观注入代码已落、机制 spike 实测验过,完整编排端到端真机是尾巴。**

- ✅ **claude 机制 spike 全验**(实机 claude):`--append-system-prompt-file` 被遵守、PostToolUse hook 注入的内容中途能到达模型、MCP 工具 auto mode 自动放行、statusLine 额度可读。
- ✅ **本地世界观渲染 + 注入**:claude(`--append-system-prompt-file`)+ codex(`developerInstructions`)两路接线、本地 prompt bundled、单测 + 双 build 绿;真二进制实跑过 post/read/hook 闭环。
- 🟨 **完整编排 E2E**:「captain 把模糊意图拆成 worker session、worker 在世界观指引下正确用 ask / post_to_crew」的端到端,需真起 session 在真机走一遍,属已知尾巴(并入 Mac GUI QA)。
