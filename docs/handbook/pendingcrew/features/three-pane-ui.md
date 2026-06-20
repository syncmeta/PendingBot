# 三栏布局

> PendingCrew 桌面端的主壳:**左索引 · 中群聊 · 右单聊**。一眼看清「我有哪些 crew、这个 crew 在聊什么、某个 session 此刻在干什么」三层信息。本篇讲这三栏各自的职责与它们怎么联动。相关:[Crew](../concepts/crew.md) · [运行位置与 Machine](../concepts/runtime-location-and-machine.md) · [Session↔群聊通信](session-crew-comms.md) · [Runner 后端](runner-backends.md)。

## 逻辑

PendingCrew 的 Mac 壳是经典三栏(`NavigationSplitView` 形态),三栏对应三个递进的视角:

| 栏 | 是什么 | 看到什么 |
|---|---|---|
| **左 · 索引** | crew / 机器的导航树 | 账号下所有机器,每台机器一组,crew 嵌在所属机器组下 |
| **中 · crew 群聊** | 选中 crew 的白板 | captain / 各 worker session / 人类在同一条流里的对话 |
| **右 · 单 session 窗口** | 选中 session 的实时窗口 | 这个 coding agent 此刻的输出(claude 终端 / codex 结构化 transcript) |

**三栏是「从外到内」的三层缩放**:左栏选一个 crew → 中栏装这个 crew 的群聊 → 在群聊里点某条 session 消息(或右栏切换条)→ 右栏装那个 session 的窗口。

- **左栏按机器分组,不是平铺的 crew 树。** 每台机器(本机 / peer / fly)一个可折叠组,crew 住在它所属机器组下;本机组置顶且带「+ 新建 crew」入口,其它机器组(暂时)只能遥控查看。这条由 machine 概念决定,详见 [运行位置与 Machine](../concepts/runtime-location-and-machine.md)。
- **中栏是 crew 群聊(白板)。** 一条即时通信形式的流,captain、worker session、人类的发言都在里面,发送者显示可读的名字而不是裸 uuid。它既给人看,也是给 agent 看的协作上下文,见 [Session↔群聊通信](session-crew-comms.md)。
- **右栏是「跟某一个 session 单聊」。** 一个 crew 可以有多个 session 并存(上限 6),右栏顶部有个 session 切换条(胶囊 + 状态点 + 未读位),切到哪个就装哪个的窗口。窗口形态按 runner 分两种:claude 是内嵌终端、codex 是结构化 transcript,见 [Runner 后端](runner-backends.md)。

## 为什么

- **三栏对应「crew 是组织、群聊是协作、session 是干活」三件正交的事。** 把它们摊在同屏的三栏里,用户一眼能从「全局有哪些活」下钻到「这个 session 跑到哪了」,不用来回切页。这是给开发者的工作台,密度优先于极简。
- **左栏按机器分组而非平铺,是为了让遥控天然在册。** 早期侧栏是「Crew 平铺树 + 一段死占位的 Machines」两段并列;改成按机器分组后,「我账号下有哪些机器、各自在不在线、这个 crew 在哪台上跑」全落在同一个抽象上(见 machine 概念的「为什么」)。
- **右栏做成「单 session 单聊」而非「一个大终端面板」,是因为 session 之间要能独立切换、各自记未读。** 多 session 并存时,把每个 session 的窗口当成一条独立的对话线,切换条带未读角标,人能在它们之间跳而不丢上下文。这也呼应人在回路:待决策 / 待审批就地在 session 窗口的 composer 答(见 [人在回路](../concepts/human-in-the-loop.md))。

## 用在哪 · 长什么样

- **左栏**:机器组头(图标 + 名 + 「本机」标 + 在线点 + 折叠箭头),组内是该机器下的 crew 行。本机组带「+」,空本机组提示「还没有 crew · 点 + 新建」,空的其它机器组提示「遥控查看(稍后)」。底部有「登录 PendingBot 账号」入口(登录是可选叠加,见 [本地为家](../concepts/local-first.md))。
- **中栏**:选中 crew 的群聊。非对称气泡、头像 + 名、胶囊 composer、时间分隔 pill——视觉与 PendingBot 的聊天对齐(含深色模式)。crew 专属信息以徽标叠在头像上:captain 橙星标、session 状态点(running / queued)、session 终端图标。顶部有成员 roster 条。
- **右栏**:session 切换条 + 选中 session 的窗口。claude → 终端视图;codex → transcript 视图(消息气泡 / 折叠推理 / 命令卡 / 文件改动 / 工具调用)。窗口下方是 composer(把输入注入这个 session)+ 就地的待决策 / 待审批答复卡片。
- **iPad 是退化形态**:iPad 不跑本地 session,所以右栏(session 窗口 / 终端 / runner)整块不存在;iPad 壳只有「登录 → crew 列表 → 群聊」两层,本质是远程查看 / 遥控端(见 [跨端遥控](cross-device-control.md))。

## 示例

你打开 Mac PendingCrew。左栏顶部是「🖥 我的 MacBook · 本机 · ●」组,下面挂着两个 crew:「鉴权重构」和「文档手册」。你点「鉴权重构」——中栏装上它的群聊,看到 captain 报到、一个 worker session 说「已开始拆分中间件」。你想看这个 worker 具体在跑什么,点它那条消息——右栏切到这个 session 的 codex transcript,看到它正在执行一条 `grep` 命令、下面跟着一段推理。它跑到一半要确认一个方向,在中栏群聊冒出一条「🔔 待决策」,你在右栏 composer 直接答,它继续跑。

## 边界

- **三栏是桌面(Mac)形态**。iPad 只有左 + 中两栏(无 session 窗口),iPhone 上 PendingCrew 不是主形态(遥控走 PendingBot)。
- **本篇讲三栏的职责与联动,不讲各栏内部的功能细节**:左栏的机器分组规则见 [运行位置与 Machine](../concepts/runtime-location-and-machine.md);中栏群聊的 @ / reply / 发送者身份见 [Session↔群聊通信](session-crew-comms.md);右栏两种 runner 窗口见 [Runner 后端](runner-backends.md);新建 crew / session 的表单见 [创建 crew 与 session](create-crew-and-session.md)。
- **右栏不是「服务端 session 查看器」**。早期 Mac 端一度做过「右栏只看服务端 session + 群钱包」,后被 revert;当前右栏是本地 session 的实时单聊窗口。

## 注意

- ⚠️ **中栏群聊视觉是「vendor 一份 PendingBot 的聊天视图」做出来的**,不是共享代码。两个 app 保持独立(PendingCrew 要独立开源),所以把 PendingBot 的跨平台聊天视图逐字拷进 PendingCrew + 写 adapter,以后「再对齐」= 重拷。这条是实现接缝,产品上只需知道「中栏长得跟 PendingBot 聊天一致、含深色模式」。
- ⚠️ **左栏的「其它机器组」当前在 Mac 上看不到内容**——本地为家、无 edge 镜像,跨机器查看要走遥控投影(尾巴,见 [跨端遥控](cross-device-control.md))。单机用户只有本机一组。

## 现状

🟨 **三栏结构 + 中栏群聊 + 右栏多 session 切换代码已落,本机 GUI 部分像素验过,完整真机 QA 是尾巴。**

- ✅ **左栏按机器分组**:本机 GUI 像素验过(2026-06-16,#369)——组头 + 组内 crew + 本机「+」、单机时正确隐藏机器选择。
- ✅ **中栏群聊对齐 PendingBot(含深色)**:vendor + adapter 落地,macOS GUI 装进去看过深 / 浅色群聊全要素对齐。
- 🟨 **右栏多 session 切换 + 两种 runner 窗口**:多 run 并存、切换条 + 未读角标、claude 终端 / codex transcript 两视图代码全落、双 build 绿;codex transcript 真机渲染随 Mac GUI QA(#342 / #290)。
- 🟨 **iPad 两栏壳**:authenticatedRoot 换成 split view(crew 列表 → 群聊)、删占位页、双 build 绿;iPad 真账号端到端(扫码登录 → 见 crew → 进群聊 → 发消息)是真机尾巴(模拟器无登录态进不到壳)。
