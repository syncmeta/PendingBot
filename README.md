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
  <img alt="Swift" src="https://img.shields.io/badge/lang-Swift-F05138?logo=swift&logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-iOS%20%C2%B7%20iPadOS%20%C2%B7%20macOS-lightgrey" />
  <img alt="Scope" src="https://img.shields.io/badge/repo-client%20only-lightgrey" />
</p>

<p align="center">
  <a href="README.md">中文</a> · <a href="README_EN.md">English</a>
</p>

知道自己错了的 AI。主动上网冲浪还要处处想着你。形态跟微信差不多，想象微信上有很多 AI 好友。

<p align="center">
  <img src="docs/screenshots/main.png" width="820" alt="主界面：左边会话列表，右边正在跟一个机器人聊天" />
</p>

> 还没正式上线。部分功能不可用。
>
> **这个仓库只有客户端**，后端不开源、不在这里 —— 你能编出这个 app，但它没有可连的后端。

## 快速开始

**想直接用**

- **macOS** —— 从 [Releases](../../releases) 下 `.dmg`
- **iPhone / iPad** —— TestFlight：<https://testflight.apple.com/join/K6Ju9qqP>

⚠️ 这两个包连的是**作者自己的后端**。你自己编出来的那份不连它 —— 见下面「配置」。

**想自己编一个**

```bash
cd apps/pendingbot
xcodegen                                          # 只在改过 project.yml 后需要
xcodebuild -project PendingBot.xcodeproj -scheme PendingBot \
  -destination 'generic/platform=iOS Simulator' build
```

不需要 Node / Bun / Docker —— 那些是后端的工具链，不在这个仓库里。
完整步骤见 [`docs/building.md`](docs/building.md)。

## 文档

<https://docs.pendingname.com>

## 主要功能

- 不断回顾、查证你和 AI 之间的对话，不仅是它自己反省，还要批评你，发现你自身认知的错误和局限，让大家都持续进化、变得更好。
- 深挖互联网，主动探索，到处苦苦寻觅对你有价值的、让你眼前一亮的信息。
- 主动地实现上述功能，不是你喊了才动，问一句答一句。

<table>
<tr>
<td width="50%"><img src="docs/screenshots/contacts.png" alt="通讯录：三个私有机器人，各自挂着不同的模型" /></td>
<td width="50%"><img src="docs/screenshots/letter.png" alt="来信：机器人主动写来的一封信" /></td>
</tr>
<tr>
<td><b>通讯录</b><br>你的联系人里有一堆机器人，<b>每只挂的模型可以不一样</b>。</td>
<td><b>来信</b><br>机器人主动写信而不是发消息——它想说的话未必适合塞进聊天框。<br><sub>⚠️ 界面演示。这条线在作者的线上库里<b>一封都没真正产出过</b>，见下面的「状态」。</sub></td>
</tr>
</table>

## 两大目标

- **及时复盘、校正彼此** — 免得聊着聊着就被AI带偏、被骗了、不清醒了。当局者迷，旁观者清。
- **探索未知 做信息的 VC** — 缓解一下我们局限的视野和信息茧房

不是助手，不是又一个什么 Agent 什么虾——助手类应用大把人做，我才不重复造轮子。

也不是标准的 AI 陪伴——它不是个听话的宝宝。它是给你带来新视角、新发现的朋友。

## 架构

### 整套系统

产品是四个部分、一条主链路。**这个仓库只有最左边那一格。**

```
        本仓库                        ✗ 以下全部不在这个仓库里，也不开源
 ┌──────────────────┐       ┌────────────────────┐      ┌──────────────────┐
 │  SwiftUI 客户端   │  写 → │  Cloudflare Worker  │  →   │  Supabase         │
 │  iOS/iPadOS/macOS│       │  Hono · 186 个接口   │      │  Postgres         │
 │                  │  ← 读 │  10 个 Durable Object│  ←   │  80 张表 · 全表 RLS│
 │  GRDB 本地缓存    │       │  2 个容器            │      │  215 个迁移        │
 └──────────────────┘       └────────────────────┘      └──────────────────┘
          ▲                            │
          └──── 实时 WebSocket ─────────┤
                                       ▼
                              ┌────────────────────┐
                              │  AI Gateway         │
                              │  4 家供应商 → 1 个出口│
                              └────────────────────┘
```

- **客户端**（`apps/pendingbot`）—— 一套 SwiftUI 源码编三端。**这是本仓库的全部内容**，
  详见下一节。
- **Edge** —— 一个 Cloudflare Worker，Hono 路由。有状态的部分交给 Durable Object：
  实时广播、会话与用户的读投影、群聊路由、语音房、钱包、跨设备遥控。
  代码沙箱与群语音媒体各跑在一个容器里。
- **数据库** —— Supabase Postgres，全表开 RLS；行变更经 webhook 推回边缘做实时扇出。
- **模型出口** —— 一个 AI Gateway 把四家供应商收成一个出口。刻意**不走网关的兼容翻译层**，
  因为那会削掉 Anthropic 的扩展思考和 Gemini 的搜索接地。

**上面那些数字是作者部署上的实测规模**（读数时刻 2026-08-25），写在这儿是为了让你知道
客户端在跟一个什么形状的东西说话 —— 不是让你照着搭一个。

**一条消息的往返**，把四格串起来看：

```
你按发送
  → 客户端乐观插一条本地气泡（GRDB）
  → POST /v1/messages（Worker），HTTP 连接不断开，改用 SSE 往回吐
  → Worker 装配提示词 → AI Gateway → 供应商
  → token 逐个回流，客户端边收边渲染
  → Worker 把最终消息写进 Postgres
  → 数据库 webhook → 边缘广播 → 你其他设备上的客户端经 WebSocket 收到同一条
```

同一条消息，**发出去走 HTTP、长出来走 SSE、同步到别处走 WebSocket** —— 三条通道各司其职，
这是理解客户端网络层为什么长成后面那个样子的前提。

### 客户端

一个 target，两套壳，五层目录。**174 个 Swift 文件，约 4.7 万行。**

**一个 target 编三端。** `project.yml` 里只有一个 application target，
`supportedDestinations: [iOS, macOS]`。平台差异**不靠拆 target**，靠三样东西：

- `Sources/Mac/` 整个子树在 iOS 构建里被排除；
- iOS 专有的文件在文件顶部包一层 `#if os(iOS)`，好处是纯 Foundation / SwiftUI 的
  模型、存储、网络层**自然进入 Mac 构建**，不用为 Mac 再写一份；
- 只有 iOS 要的依赖（WebRTC）在 `project.yml` 里标 `platforms: [iOS]`。

**两套壳，同一批 feature。** 屏幕宽窄决定装配方式，而不是决定写两份界面：

```
compact（iPhone）        底部 TabView，每个 tab 自包含 push
wide（iPad 横屏 / Mac）  NavigationSplitView 三列：tab 侧栏 │ 列表 │ 详情
```

粘合两者的是一个协议 `FeatureSurface`：每个 feature 只需交出三样装配 ——
`listColumn` / `detailColumn` / `compactRoot`，壳自己去拼。
五个 tab（消息 / 好友 / 机组 / 来信 / 我）走同一条路径，macOS 的 `@main` 和
iPad 的宽屏布局**共用同一个壳**，没有平行实现。

**五层目录，各管一段：**

| 目录 | 管什么 |
|---|---|
| `Sources/Features/` | 按功能分的界面与视图模型（80 个文件，最大的一块） |
| `Sources/Networking/` | 网络、实时、鉴权、缓存仓库、后端坐标（36 个文件） |
| `Sources/Storage/` | 本地库、钥匙串、账号状态、未读、模型目录 |
| `Sources/Models/` | 跨层共享的值类型 |
| `Sources/Components/` | 可复用 UI 原子（头像、气泡排版、Markdown/公式渲染、二维码、主题） |

**读写不走同一条路，这是客户端最该先知道的一件事。**

- **写** —— 全部经 `APIClient` 打到 Worker（`POST /v1/messages`、上传、群管理……）。
  客户端**没有**对应的 GET 侧。
- **读** —— 三级阶梯，一级不成再下一级：

  ```
  L1  GRDB 本地缓存      立刻上屏，离线也有东西看
  L2  边缘读投影         GET /v1/conversations、/v1/messages/tail
  L3  Supabase 直读       上面任何一级出错、或结果可疑地空，就回落到这里
  ```

  L2 只带标量列，头像和名字这类嵌套字段由 L1 就地补 —— 因为把它们冗余进投影，
  机器人一改名就得全量扇出。补不到就留空，下次刷新再补。

- **实时** —— 两层 WebSocket，都连边缘的广播 DO，**不是** Supabase Realtime 频道：
  用户级一条常驻（未读数、来信），会话级按需开关（消息、群投票、成员变更）。

**本地存储是加密的。** GRDB 链的是 SQLCipher 构建，数据库用一把随机 256 位密钥
`PRAGMA key`，密钥存在钥匙串里、不同步 iCloud。附件图片的 URL 缓存也换成了带文件保护
属性的实现。退出登录时整库擦掉。

**客户端自带一道闸。** `SupabaseAnonWriteGuard`：supabase-swift 在拿不到会话时会
**把写请求以匿名身份照发出去**，服务端回一句「permission denied」，线索就断在那儿了 ——
这个形状被误诊成后端 bug 两次。这道闸在字节离开设备之前就让请求失败，并且报出真正的原因。
它是机制，不是约定。

**接口形状去哪儿找**：`Sources/Networking/` 里的类型和注释是对着 Worker 路由写的，
里面还留着 `apps/edge/src/routes/…` 这类引用。那些文件不在这里，但注释仍然是
「这个接口收什么、回什么」最准确的一份记录。

**后端坐标只有一处**：`HostedConfig.swift`。那里的 `isConfigured` 是「哪条线通」的
唯一真值 —— 见下面「配置」。

## 状态：能用到什么程度

> 盘点日期 **2026-08-19**，依据是线上只读查询 + 代码核对，不是文档里的旧结论。

**先说前提，而且这一节的前提变了**：下面每一条能力，**都取决于一个你没有的后端**。
这个仓库只有客户端；Worker、数据库、模型出口都不在这里，也不开源。所以这一节
读起来更像**产品盘点**而不是**你能跑起来什么** —— 它记的是「作者那套东西真跑到
哪一步了」。据实写下来，是因为一个只放客户端的仓库更容易让人高估它。

客户端这一侧唯一的真值是
`apps/pendingbot/Sources/Networking/HostedConfig.swift` 里的
`isConfigured` / `isEmailSignInConfigured`：它们拿仓库里的坐标常量跟
`Placeholder` 的字面量比对，未填时返回 `false`。README 不另写一份能力清单，
因为两份一定会漂。

| 判据 | 比对的常量 | 决定 |
|---|---|---|
| `isConfigured` | `workerURL`、`supabaseURL`、`supabasePublishableKey` | 整条托管线：登录、聊天、联系人 |
| `isEmailSignInConfigured` | 上面三个 + `turnstileSiteKey`、`turnstileHost` | 只多管邮箱验证码那条路 |

在此之上，功能分三档：

### ① 真跑通过（作者的部署上有线上数据佐证）

生产 Worker 健康 · **iPhone 上的 1v1 文字聊天** · LLM 双通路（OpenRouter + Anthropic 原生透传都有成功记录）·
自动改会话标题 · 会话列表的边缘读投影 · 三种登录（Apple / Google / 邮箱验证码）·
后台控制台 + Cloudflare Access 门 · Universal Link AASA · Prompt 分发 · 记忆读写 ·
设备授权 / 家族 SSO · 一笔真实充值 · macOS 端（作者自用级，是活的一端不是占位）

**这一档的规模要说清楚**：线上一共 **142 条消息，全部**落在 1v1 的 `user_bot` 会话里。
"真跑通过"= 作者自己用过，不是"经过了实际使用的检验"。

### ② 后端侧代码在，但要额外凭据 / 外部服务才动得了

**这一档整档都在后端，也就是整档都不在这个仓库里。** 留着是因为它解释了
「为什么装上 app 也不会自己活过来」：

- **LLM 对话**（硬门槛）—— prompt 正文的唯一事实源是 Langfuse，**任何仓库里都没有副本**。
  缓存是空的、Langfuse 里又没有对应 prompt 时，对话链路直接 500。
  `LANGFUSE_ENABLED=false` 只关 tracing，绕不过 prompt 加载。
- **实时推送** —— 需要在 Supabase Vault 里配 `realtime_webhook_url` + `realtime_webhook_secret`，
  并把同一个 secret 配进 Worker。不配就是不推，其余功能照常。
- **计费 / 充值** —— Polar（钱包本体）+ RevenueCat（iOS）都要自己的账号和 webhook。
- **语音** —— Cloudflare RealtimeKit + OpenAI Realtime，两边的凭据都要自己开。
- **附件上传** —— R2 bucket 要自己建并绑上。
- **遥测** —— Sentry / PostHog / Langfuse 三个 key 空串即关闭，不填不会报错。

### ③ 写了，但从未接通 / 线上零数据

下面这些**在作者的线上库里是 0 行**：代码路径存在，但没有任何证据表明它端到端跑通过。
不要按"装了就能用"来预期。

群聊里的 bot 回复 · 语音（1v1 与群，生产从未接通过一次）· 附件上传 ·
**主动复盘**（`bot_lookbacks` 0 行——产品内核从未产出过一条）· bot / 群邀请 · 加好友 ·
推送通知 · 模型盲盒 · 技能订阅 · 代码沙箱 · 内购充值 · 群账号钱包

还有几条更明确的：

- **"网上冲浪"在生产必然失败** —— 唯一的搜索抓取通道是 Exa MCP，而它的 API key 从未部署，调用直接抛错。
  （区分：**聊天里现查网页**不走这条，走各家模型自带的服务端工具，那半可能是通的。）
- **短链 / 遥控索引** —— 线上有表，仓库零代码（随一次提交丢失事故一起没了）。
- **三端的自动化测试很薄** —— `apps/pendingbot/Tests/` 下有三组独立测试
  （共 58 条断言），覆盖三个只依赖 Foundation 的模块；工程里还没有
  `xcodebuild test` 目标，没有 UI 测试，也没有真正的网络层测试。本仓库的 CI
  跑的就是「编一遍 iOS Simulator + 这三组测试」。（那 695 个测试全在后端，
  那个仓库不公开。）

### 还没有的

- **PendingBot 本体的路线图**。原来那本讲的是已经拆走的另一个项目。

（上面那几张截图是作者本机跑起来截的，界面是真的；但里面的对话、机器人和「来信」都是本地数据，
不代表线上有过同样的产出——线上真实规模见上面这一节开头。）

## 跑起来

完整步骤在 [`docs/building.md`](docs/building.md)。要点：

- `cd apps/pendingbot`，需要时先 `xcodegen`（只在改过 `project.yml` 之后；
  `PendingBot.xcodeproj` 是提交在仓库里的，clone 下来直接能开）。
- 用 `xcodebuild` 编模拟器不需要签名；装到**你自己的真机**要在 Xcode 里换成
  **你自己的 Signing Team** —— 仓库里那个是作者的。
- 编出来的 app **没有可连的后端**。这不是配置漏了一步，是这个仓库的边界。

不需要 Bun / Node / Docker / Supabase CLI。那些是后端的工具链，不在这个仓库里。

## 配置

App 端的后端坐标全部集中在 `HostedConfig.swift`，改 `Environment.remote` 分支下那几个常量即可。
**别动 `Placeholder` 里的字面量**——那是上面那两个判据的参照物，改了判据就永远为真，
app 会退回静默失败。

判据为 `false` 时**不会在启动时弹任何东西** —— 只跑本地栈的人一辈子用不到云端
常量，对他喊一句他做不了任何事的警告是假警报。判据只在**入口真被按下去**时读一次：
点了 Apple / Google / 邮箱登录，才原地给你一句：

> 本仓库只带占位后端坐标，登录走不通。要接自己的 Cloudflare Worker + Supabase，见 README 的「配置」一节。

三个入口（Apple / Google / 邮箱验证码）共用这一句，不转圈也不静默失败。这是在一份
未填坐标的构建上真点过三个入口测出来的，不是设计意图。

`.dev` 那个分支指向 `localhost:8787` + `localhost:54321`，判据视其为已配置 ——
它是给「本地跑着一套后端」用的，而那套后端不在这个仓库里，所以对外部读者来说
它等价于「指向你自己那台机器」。目前还没有运行时开关，切换只能改默认值这一行。

Google 登录另有一处：两份 `Info.plist` 里的 `GIDClientID` 和反转 URL scheme 也是占位。

Universal Links / AASA 域名、Associated Domains entitlement 和代码里的分享链接域名
仍然是作者的。换成你自己的域名时这三处要一起改。

## 下载

**Release 里只有 macOS 版（`.dmg`）。iOS 版不在，也不可能在。**

Apple 不允许在 App Store / TestFlight 之外分发 iOS 应用——没有"下载个包装上"这条路。
想在 iPhone 上跑，只有两条：用自己的开发者账号从 Xcode 装到自己的设备，
或者等作者哪天真的上架（目前没有时间表）。

macOS 版走的是签名 + 公证的直接分发，下载打开就能装。

## 仓库结构

```
apps/
└── pendingbot/                    SwiftUI 原生 app —— 这个仓库的全部内容
    ├── project.yml                XcodeGen 的工程定义：target、依赖、构建设置
    ├── PendingBot.xcodeproj/      由上面那份生成，也提交在仓库里，clone 下来直接能开
    ├── Sources/
    │   ├── PendingBotApp.swift    两个 @main（iOS 一个、macOS 一个）都在这
    │   ├── Features/              按功能分的界面
    │   │   ├── Root/              壳：三列宽屏壳、tab、FeatureSurface 协议
    │   │   ├── Message/           会话与聊天（最大的一块：流式、附件、群、撤回、工具轨迹）
    │   │   ├── Friends/           通讯录与机器人管理
    │   │   ├── Group/             群设置、入群、群二维码、群钱包
    │   │   ├── Envelope/          来信：机器人主动写的文章
    │   │   ├── Call/              语音通话（1v1 与群、CallKit、来电横幅）
    │   │   ├── Crew/              机组：远端编码会话的列表与详情
    │   │   ├── Skills/            技能与机器人能力
    │   │   ├── Me/                账号、设置、钱包、内购
    │   │   └── Onboarding/        欢迎页、登录、资料初始化
    │   ├── Networking/            HTTP 客户端、SSE、实时 WebSocket、鉴权、缓存仓库
    │   ├── Storage/               GRDB 本地库、钥匙串、账号状态、未读、模型目录
    │   ├── Models/                跨层共享的值类型
    │   ├── Components/            可复用 UI 原子：头像、Markdown/公式、二维码、主题
    │   └── Mac/                   macOS 专属视图（iOS 构建里整棵排除）
    ├── Resources/                 Info.plist、entitlements、资源目录、本地化、隐私清单
    └── Tests/                     四组独立单元测试（CI 跑其中三组，见下面的 CI 一行）
scripts/
└── release/
    └── stamp-build-info.sh        构建末尾把「这是从哪个 commit 出的」写进 Info.plist。
                                   由 project.yml 的 build phase 调用，是构建的一部分，
                                   不是发版脚本
docs/                              building.md + README 用到的图
.github/workflows/client-build.yml 唯一一道 CI：macOS runner 上编一遍 iOS Simulator，
                                   再跑那三组独立测试
```

`apps/` 底下只剩一个目录，但这层路径是**故意留着**的：它明说了这是一个 monorepo
里的一个 app，旁边还有别的，只是没开源。

**不在这里的**：Cloudflare Worker 后端、Supabase 迁移与 RLS、后台控制台、
群语音媒体容器、鉴权中间件、出包与公证脚本，以及全部内部账本（进度 / 技术债 /
决策记录）。这些不是「还没整理」，是**不开源**。

这份快照是怎么从私有仓里切出来的，见 [`SNAPSHOT-PROVENANCE.md`](SNAPSHOT-PROVENANCE.md)。

另外，**PendingCrew**（Mac 端的 agent 编排 app）是另一个独立仓库。
代码注释里偶尔会引用 `docs/superpowers/plans/…` 之类的内部设计文档 —— 那些没有
一起公开，读到断链的引用不必当成缺失。

## 参与

见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。简单说：这是个人实验，
issue 和 PR 都欢迎，但作者不保证响应速度，也不承诺路线。

安全问题请走 [`SECURITY.md`](SECURITY.md) 里的私下报告渠道，别开公开 issue。

## 许可

[MIT](LICENSE)。

第三方：客户端的 SPM 依赖（GRDB · GoogleSignIn · MarkdownUI · PostHog · RevenueCat ·
Sentry · SwiftMath · supabase-swift · WebRTC）各遵其原协议，具体版本与来源见
[`apps/pendingbot/project.yml`](apps/pendingbot/project.yml)。

---

<sub>产品定位、功能与目标由作者撰写。技术章节（架构、状态盘点、构建与配置）由 Claude 补写，
其中的数字与结论均来自实际运行的命令或线上只读查询，不是从旧文档转抄。</sub>
