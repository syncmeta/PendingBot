<p align="center">
  <img src="docs/app-icon.png" width="128" alt="大绿豆 应用图标" />
</p>
<h1 align="center">PendingBot · 大绿豆</h1>

<p align="center">
  Honest with each other. Curious together. Proactive, candid, a VC for ideas.
  <br />
  <em>不躲，不藏，不绕，不夸。稳稳接住你，还要打开你</em>
</p>
<p align="center">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-blue" /></a>
  <img alt="Runtime" src="https://img.shields.io/badge/runtime-Cloudflare%20Workers-f38020?logo=cloudflare&logoColor=white" />
  <img alt="TypeScript" src="https://img.shields.io/badge/lang-TypeScript-3178c6?logo=typescript&logoColor=white" />
  <img alt="Swift" src="https://img.shields.io/badge/lang-Swift-F05138?logo=swift&logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-iOS%20%C2%B7%20iPadOS%20%C2%B7%20macOS-lightgrey" />
</p>


<p align="center">
  <a href="README.md">中文</a> · <a href="README_EN.md">English</a>
</p>

我尽我所能做一些有意思、有人味的 AI 机器人们，以类似微信的形态呈现。

<p align="center">
  <img src="docs/screenshots/main.png" width="820" alt="主界面：左边会话列表，右边正在跟一个机器人聊天" />
</p>

> 还没正式上线。部分功能不可用。

## 快速开始

- **macOS** ——  [Releases](../../releases)
- **iPhone / iPad** —— [TestFlight](https://testflight.apple.com/join/K6Ju9qqP)

## 我精心撰写的文档

<https://docs.pendingname.com/pendingbot>



<table>
<tr>
<td width="50%"><img src="docs/screenshots/contacts.png" alt="通讯录：三个私有机器人，各自挂着不同的模型" /></td>
<td width="50%"><img src="docs/screenshots/letter.png" alt="来信：机器人主动写来的一封信" /></td>
</tr>
<tr>
<td><b>通讯录</b><br>这里比较直观：机器人好友、人类好友，组成社交网络</td>
<td><b>来信</b><br>即时通信软件里写信、收信，别有一番风味<br><sub>和 Email 功能上相同 但味道不同</sub></td>
</tr>
</table>

## 目标

这个App不用来解决什么特定用途。算是一种人文创作，主要就是研究怎样让这些机器人更有人味，以及如何让人能直观地、不依靠文档就能交互。就像三岁小孩知道怎么用iPhone那样。

从功能上来说，我希望里面的机器人：

- **及时复盘、校正彼此** — 免得聊着聊着就被AI带偏、被骗了、不清醒了。当局者迷，旁观者清。
- **探索未知 做信息的 VC** — 缓解一下我们局限的视野和信息茧房

不是助手，不是又一个什么 Agent 什么虾——助手类应用大把人做，我才不重复造轮子。

也不是标准的 AI 陪伴——它不是个听话的宝宝。它是给你带来新视角、新发现的朋友。

## 架构

### 整套系统

产品是四格、一条主链路。**这个仓库只有最左边那一格。**

```
        本仓库                      ✗ 以下都不在这个仓库里，也不开源
 ┌──────────────────┐      ┌─────────────────────┐      ┌──────────────────┐
 │  SwiftUI 客户端   │  写 →│  Cloudflare Worker   │  →   │  Supabase         │
 │  iOS/iPadOS/macOS │      │  Hono · 186 个接口    │      │  Postgres         │
 │                   │  ← 读│  10 个 Durable Object │  ←   │  80 张表 · 全表 RLS│
 │  GRDB 本地缓存     │      │  2 个容器             │      │  215 个迁移        │
 └──────────────────┘      └─────────────────────┘      └──────────────────┘
          ▲                           │
          └───── 实时 WebSocket ───────┤
                                      ▼
                            ┌─────────────────────┐
                            │  AI Gateway          │
                            │  4 家供应商 → 1 个出口 │
                            └─────────────────────┘
```

- **客户端**（`apps/pendingbot`）—— 一套 SwiftUI 源码编三端。**这是本仓库的全部内容。**
- **Edge** —— 一个 Cloudflare Worker，Hono 路由。有状态的部分交给 Durable Object：实时广播、
  读投影、群聊路由、语音房、钱包、跨设备遥控。代码沙箱和群语音媒体各跑在一个容器里。
- **数据库** —— Supabase Postgres，全表开 RLS。行变更经 webhook 推回边缘做实时扇出。
- **模型出口** —— 一个 AI Gateway 把四家供应商收成一个出口。刻意**不走网关的兼容翻译层**，
  那层会削掉 Anthropic 的扩展思考和 Gemini 的搜索接地。

上面那些数字是我自己部署上的实测规模，写在这儿是为了让你知道**客户端在跟一个什么形状的东西说话**，
不是让你照着搭一个。

**一条消息的往返**，把四格串起来：

```
你按发送
  → 客户端先乐观插一条本地气泡（GRDB）
  → POST /v1/messages 到 Worker；HTTP 连接不断开，改用 SSE 往回吐
  → Worker 装配提示词 → AI Gateway → 供应商
  → token 逐个回流，客户端边收边渲染
  → Worker 把最终消息写进 Postgres
  → 数据库 webhook → 边缘广播 → 你其他设备经 WebSocket 收到同一条
```

同一条消息，**发出去走 HTTP、长出来走 SSE、同步到别处走 WebSocket**。三条通道各司其职 ——
这是理解客户端网络层为什么长成下面那样的前提。

### 客户端

**一个 target 编三端**，178 个 Swift 文件、约 4.76 万行。

`project.yml` 里只有一个 application target，`supportedDestinations: [iOS, macOS]`。
平台差异**不靠拆 target**，靠三样东西：

- `Sources/Mac/` 整个子树在 iOS 构建里被排除 —— 现在它只剩**一个文件**（Mac 的登录页），
  其余界面两端共用；
- iOS 专有的文件在顶部包一层 `#if os(iOS)`，于是纯 Foundation / SwiftUI 的模型、存储、
  网络层**自然进入 Mac 构建**，不用为 Mac 再写一份；
- 只有 iOS 要的依赖（WebRTC）在 `project.yml` 里标 `platforms: [iOS]`。

**两套壳，同一批 feature。** 屏幕宽窄决定装配方式，而不是决定写两份界面：

```
compact（iPhone）        底部 TabView，每个 tab 自包含 push
wide（iPad 横屏 / Mac）   NavigationSplitView 三列：tab 侧栏 │ 列表 │ 详情
```

粘合两者的是一个协议 `FeatureSurface`：每个 feature 交出三样装配 ——
`listColumn` / `detailColumn` / `compactRoot`，壳自己去拼。五个 tab（消息 / 好友 / 机组 /
来信 / 我）走同一条路径，macOS 的 `@main` 和 iPad 的宽屏布局**共用同一个壳**，没有平行实现。

**读和写不走同一条路 —— 这是客户端最该先知道的一件事。**

- **写** —— 全部经 `APIClient` 打到 Worker（发消息、上传、群管理……）。客户端**没有**对应的 GET 侧。
- **读** —— 三级阶梯，一级不成再下一级：

  ```
  L1  GRDB 本地缓存    立刻上屏，离线也有东西看
  L2  边缘读投影       GET /v1/conversations、/v1/messages/tail
  L3  Supabase 直读     上面任何一级出错、或结果可疑地空，就回落到这里
  ```

  L2 只带标量列，头像和名字这类嵌套字段由 L1 就地补 —— 把它们冗余进投影的话，
  机器人一改名就得全量扇出。补不到就留空，下次刷新再补。

- **实时** —— 两层 WebSocket，连的是边缘的广播 Durable Object，**不是** Supabase Realtime 频道：
  用户级一条常驻（未读、来信），会话级按需开关（消息、群投票、成员变更）。

**本地存储是加密的。** GRDB 链的是 SQLCipher 构建，数据库用一把随机 256 位密钥 `PRAGMA key`，
密钥存钥匙串、不同步 iCloud；附件图片缓存带文件保护属性。退出登录时整库擦掉。

**客户端自带一道闸。** `SupabaseAnonWriteGuard`：supabase-swift 在拿不到会话时会
**把写请求以匿名身份照发出去**，服务端回一句「permission denied」，线索就断在那儿 ——
这个形状被误诊成后端 bug 两次。这道闸让请求在字节离开设备之前就失败，并报出真正的原因。
它是机制，不是约定。

**接口形状去哪儿找**：`Sources/Networking/` 里的类型和注释是对着 Worker 路由写的，
里面还留着 `apps/edge/src/routes/…` 这类引用。那些文件不在这里，但注释仍是
「这个接口收什么、回什么」最准确的一份记录。

**后端坐标只有一处**：`HostedConfig.swift`。里面的 `isConfigured` 是「哪条线通」的唯一真值。

### 仓库结构

```
apps/pendingbot/          客户端，本仓库的主体
  project.yml             XcodeGen 定义（唯一的 target 在这儿）
  Sources/
    Features/       80    按功能分的界面与视图模型，最大的一块
    Networking/     36    网络、实时、鉴权、缓存仓库、后端坐标
    Components/     35    可复用 UI 原子：头像、气泡排版、Markdown/公式、二维码、主题
    Storage/         9    本地库、钥匙串、账号状态、未读、模型目录
    Models/          9    跨层共享的值类型
    Mac/             1    Mac 专有界面（登录页），iOS 构建里整个排除
    Stores/          1    跨 feature 的共享状态
  Tests/                  单元测试
  Resources/              Info.plist、资源目录

docs/                     截图、图标、面向读者的文档
scripts/                  仓库自检脚本（链接检查等）
.github/workflows/        CI：客户端构建、文档链接
```

**不在这个仓库里的**：Cloudflare Worker、Supabase 迁移与 RLS、管理后台、部署脚本。
客户端里的后端坐标全是占位值 —— **照这个仓库编出来的 app 能跑，但连不上任何后端**，
点登录会当场告诉你没配，而不是静默失败。

## 许可

[MIT](LICENSE)

第三方：
- Agent Skills 预设 vendored 自 [anthropics/skills](https://github.com/anthropics/skills)（Apache-2.0），
  见 [`apps/edge/prompts/skills/anthropic/NOTICE.md`](apps/edge/prompts/skills/anthropic/NOTICE.md)
  和同目录下的 `LICENSE.txt`。
- 运行时 / 库：Cloudflare Workers · Hono · Supabase · Bun · Zod 等，各遵其原协议。
