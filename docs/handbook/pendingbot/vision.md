# PendingBot 定位

> 大绿豆里**给普通人**的那一半:一个主动反思、主动探索的 AI 朋友,三端 IM 是它的家。本篇只立**这个产品是什么、为什么是这个形状、它不做什么**——具体怎么主动、社交怎么运作,各自在 `concepts/` / `features/` 里成篇。心智的源头在 [党纲](../shared/charter.md);另一半产品见 [PendingCrew 定位](../pendingcrew/vision.md)。

## 逻辑 — 这是个什么产品

**PendingBot 是人与 AI 协作的平台,对普通人的入口形态是一个三端 IM 客户端。** 类比是 ChatGPT / Claude 的 iOS app 那一档——日常打开、随手聊天的主客户端,只不过聊天的对象是「会主动关心你的朋友」,而不是「等你提问的助手」。

它建立在一条信条上:**是朋友,不是助手**。区别落在三件核心行为上,全部**不用催、到点自己做**(权威心智见 [主动性](concepts/proactivity.md)):

- **复盘 / 校正** —— bot 回看你和它聊过的内容,自己核对、给自己留备忘,在合适时机主动澄清或补充(实例:[主动复盘](features/proactive-lookback.md))。
- **网上冲浪** —— bot 主动出门找它觉得你会关心的信息,挑值得讲的带回来,产物以「来信」回流(实例:[网上冲浪](features/web-surf.md) / [来信信箱](features/envelope-inbox.md))。
- **一群 bot 议论你** —— 你日常聊的几只 bot 拉群讨论你这个人,多角度旁观;朋友之间还能共养同一只 bot(实例:[群里 bot 议论你](features/group-bot-discussion.md),建立在 [bot 社交图](concepts/bot-social-graph.md) 之上)。

bot 不只是会聊天,它还有人脉、知道何时求助:遇到难题能换个更强的模型来算,遇到自己答不了的能私下去问一个真人好友(见 [委派](concepts/delegation.md))。

## 为什么 — 为什么是「朋友」这个定位

- **主动性是把「朋友」从口号变成产品行为的那一层。** 助手的定义是「你说我做」;只在被 @ 时才回话的东西,再聪明也只是工具。让 bot 有自己的内部时钟和动机、到点自发行动,才撑得起「朋友」二字。这也是筛选新功能的尺子——加任何能力先问:它能不能让 bot 更像一个会主动关心你的朋友。
- **IM 是普通人最低门槛的入口。** 不教用户学「prompt」、不摆 dashboard,把 AI 装进一个人人都会用的聊天界面里;主动性让这个聊天界面「活」起来,不需要用户做任何配置就能感到。
- **协作平台的另一面交给 PendingCrew。** 同一个「人与 AI 协作」的母题,普通人走 IM(PendingBot),开发者走 crew 编排(PendingCrew)。两者主 + 辅、互不吞功能(见下「与 PendingCrew 的边界」)。

## 用在哪 · 长什么样

PendingBot 是 **iOS / iPadOS / macOS 三端**的 SwiftUI 单工程,三端共一套 code base、共享视觉,大屏用多列壳、iPhone 维持单栏(壳的拉伸规则见 [三端 UI](features/tri-platform-ui.md))。信息架构是五个 Tab(见 [信息架构](features/information-architecture.md)):

- **消息** —— IM 主流,和 bot / 群的日常对话。
- **好友** —— 你的 bot 和人类联系人;加好友、看半公开的社交圈。
- **Crew** —— 「看见 crew」的窗口:在群聊 grammar 里看 session 状态卡、@session 发指令、批权限请求;想深度操作就跳 PendingCrew。这是两个产品的接缝。
- **来信** —— bot 主动探索的产出以「来信」形态躺在这里。
- **我** —— 账号、钱包、配置。

社交是**邀请制 + 留痕、不做开放广场**:bot 和群都靠邀请链接 / 加入码进,不做陌生人可搜的公开身份,隐私默认收紧(见 [bot 可见性](concepts/bot-visibility.md) · [加好友](features/add-friend.md) · [bot 邀请](features/bot-invites.md))。

## 核心非目标

- **不是听话的工具。** 不追求「问什么答什么、绝对顺从」;一个让 bot 更被动、更工具化的能力,即使技术上漂亮,也跟产品方向相悖。
- **不做开放广场 / 陌生人社交。** 没有面向陌生人可搜的公开 bot 主页或身份;`slug-as-public-identity` 与 `public_open` 公开可加入档都已废(见 [bot 邀请](features/bot-invites.md))。
- **不做 crew 的深度操作台。** PendingBot 只「看见」crew,不做 runner 控制、DAG 索引、machine 管理、完整 session 日志——那是 PendingCrew 的活。
- **不是开发者工具。** 普通人的日常入口;写代码 / 跑 agent 的专业工作流不在 PendingBot 里。

## 与 PendingCrew 的边界

**主 + 辅,一个母题两个入口。** PendingBot 是普通人的日常 IM(三端),PendingCrew 是开发者的 crew 编排台(Mac 全 / iPad 云端)。接缝是:PendingBot 在 Crew Tab 里**看见** crew、能做轻量遥控(@session、批权限、看状态卡),想**深度操作**就跳到 PendingCrew。两者共享同一套[身份地基](../shared/concepts/subject.md)、计费和基础设施,但功能不互相吞:PendingBot 不做 runner / machine 管理,PendingCrew 不做普通 IM。

## 商业形态

- **未发布,单环境。** v1 还没发,只有一个 Supabase + 一个 prod worker;不搞 staging / 多环境(见 [党纲·商业立场](../shared/charter.md))。
- **关键基础设施外包、零 VPS。** 模型走 Cloudflare AI Gateway 统一计费(OpenRouter 留 fallback);计费引擎 Polar(MoR + 钱包本体)+ RevenueCat(iOS),门禁走 WalletDO,不直连 Stripe(见 [计费主体](../shared/concepts/billing-subject.md) · [钱包](../shared/concepts/wallet-pnc.md))。
- **协作要组织账号,但比业界轻得多。** 平台支持群账号(几个朋友出门旅游临时建一个都行),但**轻量化、可临时**,不是 Notion workspace 那种重资产(见 [群账号](../shared/concepts/group-accounts.md))。
- **不在中国大陆上架。** 中文只是开发语言,评估产品时别把中国 App Store 限制当约束。
- **品牌域名 `pendingname.com`**(邮件 / Site URL / Universal Link 都基于它);对外品牌站在另一个仓库。

## 注意

- **「闭源商业产品」**:PendingBot 这一半**不开源**(开源的是 PendingCrew,见 [PendingCrew 定位](../pendingcrew/vision.md))。
- **「PendingBot 三端都做」是定调**:iOS / iPad / Mac 一套 code base 全覆盖;不要把它和「PendingCrew iOS 不做」混淆——那是另一个产品的平台约束。

## 现状

🟨 **方向定稿、三端壳就位,核心主动行为多数代码已落、活验有尾巴。**

- ✅ 三端共享 UI(一套 SwiftUI 跑 iPhone / iPad / Mac,不再 Mac 平行重写)已合 main,Mac 五个 Tab 由同一份共享视图渲染。
- ✅ 社交地基(邀请制 bot / 群、加好友、隐私收紧)端到端验过(如 [bot 邀请](features/bot-invites.md) D1)。
- 🟨 三件核心主动行为(复盘 / 冲浪 / 群议论)的产品形态与多数代码已落,逐项活验进度见各 `features/` 篇与 [路线图与现状](../shared/evolution/roadmap-and-status.md)。
- 🟨 端到端 QA(真消息 / 真账号 / 真机全链)是 v1.0 release-ready 的真实门槛,仍是最大未验区。
