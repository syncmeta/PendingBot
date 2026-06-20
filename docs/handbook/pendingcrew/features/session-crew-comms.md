# Session ↔ 群聊通信

> crew 群聊不只是给人看的聊天框,它是 session 之间、session 与人之间协作的**通信总线**。本篇讲这条总线的通信机制:统一的 @ 模型、整块白板每轮注入、session 用 `post_to_crew` 发关键节点、对某条消息回复时自动 @ 原发送者、以及全程推送、无轮询。相关:[白板](../concepts/whiteboard.md) · [Session 与世界观](../concepts/session-and-world-model.md) · [三栏布局](three-pane-ui.md) · [跨端遥控](cross-device-control.md)。

## 逻辑

群聊里参与的有四类:人类、captain、各 worker session、被拉进来的成员。通信机制由四条规则组成:

**1. 统一的 @,双向对称。** 「人 → session」和「session → 任意人」用同一套 mention 模型。一条消息可以:
- **不 @**(广播)= 留在白板上,所有 session 都看得到(当上下文)。
- **@ 某个 session / @captain** = 定向投递给那个对象(它会被「明确要你看」地唤醒)。
- **@broadcast** = 显式全员。

session 自己也能 @:它调 `post_to_crew(...)` 时带 `mentions`,就能定向 @ 某个人 / 某个 session。人发消息有 composer 的 @ picker,session 发消息有工具参数——两端是同一个 mention 概念。

**2. 整块白板每轮注入。** 每个 session 启动 / 每轮 fresh prompt 前,系统把**整块白板**(按时间序、带发送者名)自动注入它的上下文。所以 session 不用主动拉、不用轮询;「群里说一句」= 写在白板上,下一轮被唤醒的 session 自然看到。每个 session 有读游标,空闲 + 有未读才提示「看一下」;@ 别人的部分会被过滤、不进这个 session 视野。(白板这条通信本身的定位见 [白板](../concepts/whiteboard.md)。)

**3. session 用 `post_to_crew` 发关键节点。** session 的工作细节(命令输出 / 工具日志)留在右栏自己的窗口,**不进群**;往群里发的只该是关键节点(「开始了 / 完成了」「卡住需要 X」「重要发现」「交接给某 session」)。发就是调 `post_to_crew`。

**4. reply 自动 @ 原发送者。** 对群里某条消息「回复」时,系统自动把那条消息的发送者解析成一个 mention 加进去——你回复 worker A 的消息,A 自动被 @、自动被唤醒,且这条回复在 UI 上串成一条引用线。

**全程推送、无轮询。** 谁在白板上发了新东西,直接推给在听的各方(session runner / UI),不靠定时器刷。两种实现一条语义:本地 crew 走进程内事件总线,登录态 crew 走既有的实时扇出通道。

## 为什么

- **@ 做成双向对称,是因为协作本来就是双向的。** 早期群聊是「广播 + 轮询 + @ 被直接丢弃」——人在群里 @ 一个 session 没有任何效果,session 之间也没法点对点喊。把 @ 升成双向对称的一等机制后,人能精确把任务派给某个 session、session 能把发现交接给另一个 session 或转述给人,协作才真的「能对话」而不只是各发各的。
- **整块白板注入(而非只投 @self),是因为白板是上下文不是消息队列。** 一个 session 要做对事,得知道别人(哪怕没 @ 它)在白板上说了什么。把整块白板当背景知识注入,群里的共识 / 卡点自动成为每个 session 的已知,不需要谁手动转述。这是「白板」区别于「点对点投递」的根本(详见 [白板](../concepts/whiteboard.md) 的「为什么」)。
- **`post_to_crew` 只发关键节点,是为了白板不被噪音淹没。** 如果 session 把每步操作都往群里倒,白板秒变滚动 stdout、谁都读不过来。细节留右栏、群里发关键节点,白板作为「共享上下文」的价值才保得住——这是世界观 prompt 反复强调的信息架构。
- **reply 自动 @ 原发送者,是把「回复」这个最自然的动作直接接到唤醒上。** 人不用先想「我要 @ 谁」,点回复 = 自动 @ 那条的作者 + 自动唤醒它,符合 IM 直觉。
- **全程推送、无轮询,是体验 + 正确性双重要求。** 轮询既有 3 秒延迟感、又浪费;推送让「发一句立刻出现 / 立刻唤醒对方」。本地同进程更是直接方法调用(@ 目标 session 在同进程 → 直接注入,不经网络)。

## 用在哪 · 长什么样

- **中栏群聊**(见 [三栏布局](three-pane-ui.md)):每条消息显示**发送者可读名**(队友 session 的 label / 机长 / 人类名),不是裸 `session:<uuid>`。被回复的消息在 UI 上串成引用线。
- **composer 的 @ picker**:打 `@` 弹出成员 autocomplete(session / captain / broadcast / human),选中 = 文本插 `@名字` + 暂存一个 mention,发送时一起带上。不 @ 时占位提示「不 @ = 广播给所有 session」。
- **回复手势**:长按 / 侧滑某条气泡 →「回复」→ composer 顶部显示被回复条 + 自动暂存 `@原发送者`,发送时带上对那条的引用。
- **session 侧**:`post_to_crew` 工具带 `mentions?` / `reply_to?` 两个参数;世界观 prompt 教 session 什么时候该 @ 谁、怎么 reply、白板每条带发送者名(见 [Session 与世界观](../concepts/session-and-world-model.md) 第 8、9 条)。

## 示例

worker A 跑到一半发现「旧 `requireAuth` 中间件是死代码」,调 `post_to_crew` 发一条到白板(不 @,广播)。人类看到了,想让另一个空闲的 worker B 去清,于是在群里**回复 A 那条消息**:「@A 确认下,然后让 B 删掉」——系统自动 @ 了 A(A 被唤醒,确认),人这条同时也 @ 了 B。B 当前空闲 + 被 @ → 直接被唤醒,启动时整块白板注入,它一上来就知道前因后果,开始删。全程没有谁在轮询,每条消息一发就推到各方。

## 边界

- **本篇讲群聊作为 session↔人 的通信机制**(@ / 整块注入 / post_to_crew / reply / 推送);白板这条通信**本身**的定位(沟通渠道 + 上下文白板、不是 IO 日志)见 [白板](../concepts/whiteboard.md),世界观里怎么教 session 用这些见 [Session 与世界观](../concepts/session-and-world-model.md)。
- **session 的工作细节不走群聊**——stdout / 工具日志只在右栏自己的窗口,群里只有关键节点。
- **白板托管是「单后端 per crew」**:本地 crew 用本地白板、登录态 crew 用 edge 白板,不做双向 sync(见 [本地为家](../concepts/local-first.md))。
- **本篇是 crew 内部的群聊通信**;同账号跨设备遥控(把这条通信投到另一台设备 / 远程下指令)是相邻主题,见 [跨端遥控](cross-device-control.md)。

## 注意 — 已改的旧方案(别写回)

- ❌ **「广播 + 轮询 + @ 被丢弃」** —— 群聊老形态:消息只能全员广播、客户端 3 秒轮询刷新、@ 没有任何路由效果。已整套重做成「双向 @ + 看得见发送者 + reply 自动 @ + 全程推送无轮询」。任何「群里 @ 没用 / 靠定时器刷 / 看不到谁发的」的描述都过时。
- ❌ **裸 `session:<uuid>` 当发送者** —— 现在白板每条都解析出发送者**显示名**(UI 气泡和给 agent 看的白板渲染都用名)。
- ⚠️ **edge bot-当-captain 那套「群消息唤醒 captain → captain 编排」的旧路径已退役**(stale-model 审计 R1)。当前 captain 是本地 session、不是 edge bot;群聊唤醒走的是本篇这套 mailbox + 推送机制,不是旧的 edge captain 编排。引用旧 spec 里 edge captain 编排的注释都已作废。

## 现状

🟨 **群聊通信重做代码全落(edge 全测试覆盖 + 双端 build/test 绿),本地 @ 单机真跑通,远端活体推送真机是尾巴。**

- ✅ **edge 全测试覆盖(600+ vitest)**:入站 @(人 @session/@captain → 定向投递)、出站 @ + reply(`post_to_crew` / 端点带 mentions/reply_to,reply 自动 @ 原发送者)、发送者身份(白板读模型 join 出显示名)、reply 引用透出——全测试覆盖 + typecheck 绿。
- ✅ **PendingCrew 双端 build/test 绿**:去轮询(本地进程内 publisher + 远端实时客户端,删掉群聊 3s / roster 3s / badge 2s 三处定时器)、runner 事件驱动唤醒(收事件 → 拉 inbox → 空闲则注入,纯决策逻辑单测覆盖)、composer @ picker + reply 手势、世界观 prompt 教 @/reply/发送者。**实时推送客户端跨平台化 → iPad 也接推送**。
- ✅ **本地模式 @ 直接注入唤醒 idle session(单机真跑通)**:同进程方法调用,@ 目标 session 在同进程直接 `send()` 注入。
- 🟨 **远端 runner 唤醒 + session→@ 的 edge 上行 + 活体 hub 推送真机 E2E**:卡在「本地 ↔ edge 绑定」尾巴(远端唤醒两道门全程门住、`CrewRelayAgent.push` 未透传 mentions/reply_to),保持 open + 记 tech-debt;更新后的 world-model prompt 重新 seed 到 Langfuse 也是尾巴。**本地模式不依赖这条绑定、逻辑通可真跑**(但只单测过、未真起 session 观测注入)。
