# 跨端遥控

> session 实际跑在某一台机器上,但你想从手边任意一台设备看它、给它下指令、批它的审批——哪怕你人不在那台机器跟前。本篇讲跨端遥控:同账号的 PendingBot(iPhone / iPad / Mac)或 iPad PendingCrew 怎么遥控跑在另一台机器上的 session,所有遥控经 edge 中转,离线有缓存兜底,算力计费归 crew 的责任主体。相关:[运行位置与 Machine](../concepts/runtime-location-and-machine.md) · [本地为家](../concepts/local-first.md) · [三栏布局](three-pane-ui.md) · [Session↔群聊通信](session-crew-comms.md) · [人在回路](../concepts/human-in-the-loop.md)。

## 逻辑

**一个 session 在一台机器上执行,但可以被同账号的任意设备远程旁观 + 控制。** 账号同步是前提:同一个登录账号在哪台设备上,都能对这个账号下的 session 做三件事——

1. **旁观** —— 看它的状态 / 进度 / 关键事件(它跑到哪了)。
2. **下指令** —— 把命令 / 一句 `@session …` 塞进它的队列。
3. **批审批** —— 它因高危操作暂停、弹出待审批时,远程批准 / 拒绝(见 [人在回路](../concepts/human-in-the-loop.md))。

**角色只有两种:runner(那台真正执行的机器,有且仅一台)和 viewer(任意多台旁观 / 控制的设备)。** runner 是被 device-grant 授权的执行宿主(永远是台机器、不是登录的人);viewer 是登录的人在各设备上的客户端。最新连上的 runner 顶掉旧的(重连即夺位),viewer 是叠加的。

**所有遥控经 edge 中转,不点对点。** viewer 和 runner 谁都不直连对方,各自连到 edge 上一个**按 session 绑定的中转点**——它持有这个 session 的所有 viewer 连接 + 唯一 runner 连接,把 runner 的状态扇出给所有 viewer、把 viewer 的指令路由给 runner。一个 session 一个中转点,扇出不需要额外的 pub-sub。

**离线有缓存兜底。** WebSocket 是快路径,但**持久信箱才是权威源**。每条指令同时落两处:实时推给 runner,且写进持久信箱。runner 离线时,指令进一个有界的离线队列(且仍在信箱里);runner 重连时把队列冲刷给它,加上它自己启动时会拉信箱补漏——所以「runner 不在线时下的指令不会丢」。

**算力计费归 crew 的责任主体。** 遥控本身不改计费归属:session 在哪台机器上跑、那台机器是谁的,算力账就记在**这个 crew 的责任主体**钱包上。自己的电脑(本机 / peer)跑是免费的;云机器(fly)按时长扣责任主体钱包(见 [运行位置与 Machine](../concepts/runtime-location-and-machine.md))。viewer 是谁不影响计费。

## 为什么

- **「session 在一台机器跑、但任意设备能控」是 PendingCrew 工作流的刚需。** 你在 Mac 上起了个跑很久的 session,然后出门——手机上得能看它跑到哪、它卡住要审批时能远程放行,而不是回到那台 Mac 跟前才行。账号同步让「我的设备们」成为一个整体,遥控是这个整体的自然能力。
- **runner 和 viewer 严格分两种角色,是安全边界。** 只有被 device-grant(带执行权限)授权的机器能当 runner;登录的人永远只能当 viewer——一个被攻破的 viewer 客户端没法谎称自己是 runner 拿到执行权限(边界在 edge 侧校验,不信客户端自报)。
- **经 edge 中转(而不是点对点),是为了「一台 runner、多台 viewer」的扇出不需要打洞。** 设备之间直连要处理 NAT / 在线发现 / 鉴权一大堆;让大家都连到 edge 上一个按 session 绑定的中转点,扇出 / 路由 / 鉴权全在一处,客户端只管连。
- **「持久信箱才是权威、WS 只是快路径」,是为了遥控在网络抖 / runner 离线时仍不丢指令。** 只靠 WS,runner 一断线指令就没了;让每条指令既走实时、又落持久信箱,runner 无论当时在不在线,最终都能从信箱看到。这是「快」和「不丢」兼得。
- **关键洞察:遥控一台 peer 电脑和遥控一台云 fly 机器,是同一条链路。** 两者都是「一台有进程能力的远程机器,本机只是控制面」,复用同一套中转 / 指令转发 / 状态同步 / 审批通道——把 peer 遥控做通,fly 的遥控层就已经铺好,fly 只多「按时长计费 + 云 box 生命周期」。这是 machine 抽象的核心红利(见 [运行位置与 Machine](../concepts/runtime-location-and-machine.md))。

## 用在哪 · 长什么样

- **PendingBot 任意端当 viewer**:iPhone / iPad / Mac 的 PendingBot 进 crew,能看到这个 crew 的 session 列表 + 实时状态条;点进去看转写;待审批以卡片就地渲染在 crew 聊天里,批 / 拒按钮直接发决定;在 session composer 里打字就是给它下指令。
- **iPad PendingCrew 当 viewer**:iPad 不跑本地 session(右栏整块不存在),它本质就是个遥控端——登录后看到账号下的机器和 crew,旁观 / 遥控跑在 Mac(或 fly)上的 session。这也是 iPad 形态 = 退化三栏的原因(见 [三栏布局](three-pane-ui.md))。
- **PendingCrew Mac 当 runner**:本地跑 session 的那台 Mac,把自己的状态实时推上去、消费远程来的指令和审批决定。
- **下指令的两条路**:可以是结构化命令(取消 / 发一句 prompt / 设定 steering),也可以是群聊里的 `@session …`(见 [Session↔群聊通信](session-crew-comms.md))——后者复用同一个定向信箱。

## 示例

你在家用 Mac PendingCrew 起了个 session 重构鉴权,跑起来后出门。地铁上你掏出 iPhone 打开 PendingBot,进这个 crew——看到那个 session 状态是「running」,实时刷着进度。它跑到一半要确认「中间件放路由层还是全局」,弹出一张待审批卡片到你 iPhone 的 crew 聊天里。你点「批准:全局」——决定经 edge 中转回到家里那台 Mac,session 解阻塞继续跑。整个过程你没碰那台 Mac,算力账记在这个 crew 的责任主体上。

## 边界

- **本篇讲跨设备遥控的链路与角色**;具体的运行位置抽象(本机 / peer / fly 派生自机器清单)见 [运行位置与 Machine](../concepts/runtime-location-and-machine.md),crew 群聊的 @ / 推送机制见 [Session↔群聊通信](session-crew-comms.md)。
- **遥控只发生在同一账号的多台设备之间**——跨账号遥控不存在,别人既看不到也碰不到你的 session。
- **iPad / iPhone 不跑本地 session**——它们只能当 viewer 遥控别处的 runner;真正执行 session 的是 Mac(或 fly 云机器)。
- **本机优先、无 edge 镜像**:纯本地 crew 的内容默认不上 edge,所以「在另一台设备上看本机 crew 的全部内容」要靠遥控投影补,不是 edge 持续镜像(见 [本地为家](../concepts/local-first.md))。

## 注意

- ⚠️ **fly 云机器遥控是 v1.1,不是现在。** 当前能遥控的是 peer(同账号的另一台电脑);fly box 的开通 / 按时长计费 / 冷启动唤醒全未做。但链路是同一条——fly 只是 machine 清单里多一类、多一套云 API + 计费,不需要改中转 / 协议(见 [运行位置与 Machine](../concepts/runtime-location-and-machine.md))。
- ⚠️ **「最新 runner 夺位」假设旧 runner 已死。** 一台 Mac 网络抖一下重连可能把自己的旧连接顶掉;两台同账号 Mac 都想当同一 session 的 runner 会脑裂。v1 假设「一人一台 PendingCrew Mac」、忽略这些竞态;多宿主是未来的事。
- ⚠️ **下指令的实际唤醒注入**(viewer 下指令 → runner 真的把它塞进运行中 agent 的下一轮)依赖本地 ↔ edge 绑定,这条目前是尾巴(见现状),与 [Session↔群聊通信](session-crew-comms.md) 的远端唤醒同一道门。

## 现状

🟨 **遥控地基(中转 + 协议 + 鉴权 + 离线队列)已落,viewer 旁观链已端到端真机验,远端"下指令真注入"是尾巴。**

- ✅ **中转地基 P0 已落**:按 session 绑定的中转点(Durable Object)+ WS 协议 + 路由 + 离线队列 + 鉴权(viewer / runner 角色在 edge 侧校验)+ 单测覆盖。
- ✅ **runner 边跑边实时推 session 状态**:runner 起来后实时 publish 状态、viewer 实时 banner,**「WS 实时推状态替轮询」这条 = DONE**(3s 轮询保留为 runner 离线时的转写兜底,故意)。
- ✅ **viewer 旁观链已真机端到端验**:PendingCrew Mac 登录起 claude session →(状态机 queued→running→cancelled)+ session 事件落库,viewer 原样渲染、截图核对一致;**iOS PendingBot viewer 真机验通**(用户在 iOS 上看到远端 session 渲染)。遥控命令(取消 / 发 prompt / 设 steering)+ 待审批交互卡已接。
- 🟨 **远端"下指令真注入运行中 session"**:卡在本地 ↔ edge 绑定尾巴(同 [Session↔群聊通信](session-crew-comms.md) 的远端唤醒门),代码全落、待部署 + 真账号端到端(如 iOS 派任务 → Mac 自动起 session)。worker 部署被权限层拦,待用户手动部署。
- ⬜ **fly 云机器遥控**:仅 machine 表结构 + 选择 UI 占位;开通 / 按时长计费 / 冷启动全未做(v1.1)。
- ⬜ **终端字节级跨端隧道**(在远端 viewer 上看 claude 终端**原始字节输出**,而不只是状态 / 结构化事件):依赖把 SwiftTerm raw 字节接进中转,属另一条线 + 真机,未做。
