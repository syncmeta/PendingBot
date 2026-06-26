# 白板(whiteboard)

> crew 的群聊到底是什么——它是**沟通渠道 + 上下文白板**,不是 IO 日志的倾倒地。本篇讲白板这条通信本身的定位、它怎么被注入 session、以及为什么要把它跟「工作细节」严格分开。相关:[Session 与世界观](session-and-world-model.md) · [Crew 与 Captain](crew.md) · [session-crew 通信](../features/session-crew-comms.md)。

## 逻辑

每个 crew 有一条群聊流,它同时是两件事:

- **沟通渠道** —— 人类、captain、各 worker session、被拉进来的成员,在同一条流里同步进展、交接、提问。
- **上下文白板** —— 一块大家可见、按时间排的共享笔记。「在群里说一句」≈「写在白板上」,别人(包括下一轮被唤醒的 session)自然看得到。

**白板不是 IO 日志。** session 跑命令的 stdout / stderr / 工具调用细节**只显示在右栏 session 窗口**,不进白板。往白板里发的只该是**关键节点**:「我开始了 / 完成了」「我卡住了,需要 X」「重要发现」「交接给某 session」。

**白板怎么进 session**:每次 session 启动 / 每轮 fresh prompt,系统把**整块白板**(按时间序)自动注入到该 session 的上下文(系统提示之后)。所以:
- session 不用主动拉白板(`read_whiteboard` 工具按需重拉,但日常用不上)。
- 「在群里随便说一句」= 留在白板上,下一轮 session 自然看到。
- 每条消息带发送者显示名(队友 session 的 label / 机长 / 人类名),不是裸 uuid。
- `@self` 的部分是「明确要你必看」;没 @ 的是广播 / 留言、也看得到;@ 别人的被过滤掉。

session 往白板发用 `post_to_crew(...)`,可带 `mentions` 定向 @、`reply_to` 回复并自动 @ 原发送者。

## 为什么

- **白板 = 上下文,所以注入「整块」而不只是 `@self`。** 多 agent 协作里,一个 session 要做对事,得知道别的 session / 人类在白板上说了什么——哪怕没 @ 它。把整块白板当上下文注入,意味着「群里的共识 / 决定 / 卡点」自动成为每个 session 的背景知识,不需要谁手动转述。这是白板被称作「白板」而非「消息队列」的原因:它是共享的工作记忆,不是点对点投递。
- **严格区分「白板 vs IO 日志」,白板才不会被噪音淹没。** 如果 session 把每一步操作都往群里发,白板瞬间变成滚动的 stdout、人类和别的 agent 根本读不过来,白板作为「共享上下文」的价值就废了。所以世界观 prompt 反复强调:细节留右栏,群里只发关键节点(呼应 [Session 与世界观](session-and-world-model.md) 第 2、3 条)。这是产品刻意的信息架构,不是性能优化。
- **白板要被声明为「可信」**,否则 agent 会把中途注入的内容当 prompt injection 拒绝——这条由实测逼出,见 [Session 与世界观](session-and-world-model.md)。

## 用在哪 · 长什么样

- **打开一个 crew 就是进它的白板群聊**:消息流 + composer,发送者显示成可读的名字。视觉上是 IM 群聊 grammar,不是 dashboard。
- **PendingBot 与 PendingCrew 共享同一份白板**:在 PendingBot Crew Tab 看到的 crew 群聊,和 PendingCrew 中栏看到的是同一份消息(登录态 edge crew);PendingCrew 中栏多一些编排控件(建 session / 建子 crew 按钮)。
- **本地 crew 的白板在本机**:纯本地 crew 的白板是本机的一份 store,中栏直接读它,不走 edge。

## 示例

一个 crew 在重构鉴权。worker A 发现「现有 `requireAuth` 中间件其实有两个版本,旧的没人用了」——这是个值得大家知道的发现,它 `post_to_crew` 发一条到白板。半小时后系统拉起 worker B 接手另一块,B 启动时整块白板被注入,B 一上来就知道「旧 `requireAuth` 是死的、别碰」,不用重新踩一遍。而 A 跑的那几十条 grep / 读文件 / 编辑细节,全在 A 的右栏,没污染白板。

## 边界

- **白板不收 IO 日志 / 自言自语 / 不停的进度 ping**——这些留右栏。
- **本篇讲白板这条通信本身的定位与注入**;`@` 路由规则、reply 引用渲染、推送 vs 轮询、发送者身份解析这些通信**机制**见 [session-crew 通信](../features/session-crew-comms.md)。
- 白板是「沟通 + 上下文」,不是「任务源」:真正的任务在系统提示、白板最新一段、或 mailbox 待处理项里(世界观说明书的最后一句)。

## 注意

- ⚠️ **白板的托管是「单后端 per crew」**:纯本地 crew 用本地白板、登录态 crew 用 edge 白板,**不做双向 sync**。要让 PendingBot 的 bot 进 crew 在白板上发言,得走一次性「毕业」(本地 → edge),不是持续镜像两份。详见 [本地为家](local-first.md)。
- ⚠️ **早期「广播 + 轮询 + @ 被丢弃」已重做**:白板通信已升级为「双向 @ + 看得见发送者 + 可对某条回复(自动 @ 原发送者)+ 全程推送无轮询」。引用旧的「群里 @ 没用 / 靠定时器刷」描述都已过时。
- **「整块白板注入」是定位,不是无脑全量**:对每个 session 有读游标,空闲 + 有未读才提示「看一下白板」;@ 别人的部分会被过滤,不进这个 session 的视野。
