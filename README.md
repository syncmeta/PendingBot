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
  <a href="https://bun.sh"><img alt="Bun" src="https://img.shields.io/badge/toolchain-Bun-fbf0df?logo=bun&logoColor=black" /></a>
  <img alt="TypeScript" src="https://img.shields.io/badge/lang-TypeScript-3178c6?logo=typescript&logoColor=white" />
  <img alt="Swift" src="https://img.shields.io/badge/lang-Swift-F05138?logo=swift&logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-iOS%20%C2%B7%20iPadOS%20%C2%B7%20macOS-lightgrey" />
</p>

<p align="center">
  <a href="README.md">中文</a> · <a href="README_EN.md">English</a>
</p>

知道自己错了的 AI。主动上网冲浪还要处处想着你。形态跟微信差不多。

<p align="center">
  <img src="docs/screenshots/main.png" width="820" alt="主界面：左边会话列表，右边正在跟一个机器人聊天" />
</p>

> **这是一个人的实验项目，不是产品。**
>
> 没有上线运营，没有真实用户，没有支持承诺。下面的「状态」一节写清了哪些功能
> 真的跑通过、哪些只是代码在那儿。读之前先接受一件事：**你 clone 下来，开箱什么也做不了**，
> 得先接上你自己的后端。
>
> 界面和文档都是中文的。
>
> *(A personal experiment, not a product. Chinese-language UI and docs.
> Nothing here is hosted for you — you have to run your own backend;
> see [`docs/self-hosting.md`](docs/self-hosting.md).)*

## 快速开始

**想直接用**

- **macOS** —— 从 [Releases](../../releases) 下 `.dmg`，签名并经 Apple 公证，双击就能装。
- **iPhone / iPad** —— 只能走 TestFlight：<https://testflight.apple.com/join/K6Ju9qqP>

⚠️ **装上之后，还需要接你自己的后端才能真正聊起来。** 这份仓库不带任何真实的后端坐标，
点登录会明确告诉你没配置，而不是静默失败。怎么接见 [`docs/self-hosting.md`](docs/self-hosting.md)。

**想自己跑一遍代码**

```bash
bun install                                      # bun 1.3.11+
bun --filter='@pendingbot/edge' run typecheck    # 应为 0 错
cd apps/edge && ./node_modules/.bin/vitest run   # 695 例
```

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

四个部分，一条主链路。

```
  iOS / iPadOS / macOS          Cloudflare Worker              Supabase
  ┌──────────────────┐          ┌──────────────────┐          ┌──────────────┐
  │  SwiftUI 客户端   │  HTTPS   │  Hono 路由        │  Postgres│  80 张表      │
  │                  │ ───────► │  186 个接口       │ ───────► │  130 条 RLS   │
  │  本地缓存 / 会话  │ ◄─────── │  10 个 DO         │ ◄─────── │  212 个迁移   │
  └──────────────────┘  Realtime└──────────────────┘          └──────────────┘
                                        │
                                        ▼
                                ┌──────────────────┐
                                │  AI Gateway       │
                                │  4 家供应商 → 1 个 │
                                │  出口，20 个工具   │
                                └──────────────────┘
```

- **客户端**（`apps/pendingbot`）—— 一套 SwiftUI 源码编三端，xcodegen 生成工程。
  后端坐标集中在 `HostedConfig.swift`，那里的 `isConfigured` 是「哪条线通」的唯一真值。
- **Edge**（`apps/edge`）—— Cloudflare Worker + Hono，业务主体。Durable Object 管有状态的东西
  （会话轮次、限流、实时投影）。695 个测试全在这一层。
- **数据库**（`supabase/`）—— Postgres + RLS。所有跨用户的读写都由 RLS 兜底，
  `SECURITY DEFINER` 函数有一道 CI 闸门盯着，防止权限飘回 PUBLIC。
- **后台**（`apps/admin`）—— Refine SPA，打包进 Worker 的静态资源，前面挡一道 Cloudflare Access。

**两个外部依赖值得单独说：**

- **Prompt 的唯一事实源是 Langfuse，仓库里没有副本。** 这是有意的——避免代码里一份、
  线上一份、迟早对不上。代价是自建时必须先在 Langfuse 里逐字建好那 18 条 prompt，
  否则对话链路直接 500。
- **4 家 LLM 供应商统一到一个 AI Gateway 出口**，模型可调用的工具有 20 个。
  换供应商不用改业务代码。

## 状态：能用到什么程度

> 盘点日期 **2026-08-19**，依据是线上只读查询 + 代码核对，不是文档里的旧结论。

**先说前提**：这份公开仓库不带任何真实的后端坐标。
`apps/pendingbot/Sources/Networking/HostedConfig.swift` 里的
`isConfigured` / `isEmailSignInConfigured` 是"哪条线通、哪条线不通"的**唯一真值**
——README 不另写一份能力清单，因为两份一定会漂。
未填坐标时它返回 `false`，你点登录会被明确告知，而不是静默失败。

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

### ② 代码在，但要额外凭据 / 外部服务才动得了

接上自己的后端之后，这些还需要各自的钥匙：

- **LLM 对话**（硬门槛）—— prompt 正文的唯一事实源是 Langfuse，**仓库里没有副本**。
  新部署的缓存是空的、Langfuse 里又没有对应 prompt 时，对话链路直接 500。
  `LANGFUSE_ENABLED=false` 只关 tracing，绕不过 prompt 加载。要自建就得先在
  Langfuse 里逐字建好那 18 条 prompt——[`docs/self-hosting.md`](docs/self-hosting.md) 第 6 节列了名字。
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
- **三端零自动化测试** —— Swift 侧没有 CI 测试；695 个测试全在 Edge（`apps/edge`）。

### 还没有的

- **PendingBot 本体的路线图**。原来那本讲的是已经拆走的另一个项目。

（上面那几张截图是作者本机跑起来截的，界面是真的；但里面的对话、机器人和「来信」都是本地数据，
不代表线上有过同样的产出——线上真实规模见上面这一节开头。）

## 跑起来

完整步骤（含每一个外部服务要开什么、拿什么）在 [`docs/self-hosting.md`](docs/self-hosting.md)。
那份指南是在一个干净 checkout 上实跑核对过的，包括哪些步骤**没**跑通。

最短路径就是上面「快速开始」里那三条。三个组件各自：

- **Edge（后端）** —— `bun --filter='@pendingbot/admin' run build` 先出 admin 的静态资源，
  再 `cd apps/edge && wrangler dev --local`。裸跑只证明 Worker 起得来；业务路由要本地 Supabase。
- **数据库** —— `supabase start` + `supabase db reset --local`。全部迁移和两份 seed
  在断网的 Docker 网络里跑通过。
- **App** —— `cd apps/pendingbot && xcodegen`（仓库不带 committed 的 scheme，**新 clone 必须先跑这一步**），
  然后 Xcode 打开 `PendingBot.xcodeproj`，选自己的 Signing Team 构建。

## 配置

App 端的后端坐标全部集中在 `HostedConfig.swift`，改 `Environment.remote` 分支下那几个常量即可。
**别动 `Placeholder` 里的字面量**——那是上面那两个判据的参照物，改了判据就永远为真，
app 会退回静默失败。

只想在本地跑的，把 `HostedConfig.environment` 的默认值从 `.remote` 改成 `.dev`
（坐标是 localhost，判据视其为已配置）。目前还没有运行时开关。

Google 登录另有一处：两份 `Info.plist` 里的 `GIDClientID` 和反转 URL scheme 也是占位。

Edge 侧的变量、binding、secret 清单见 [`.env.example`](.env.example) 和
`apps/edge/wrangler.jsonc`——后者里所有形如 `YOUR_…` / `example.com` 的值都是占位。

## 下载

**Release 里只有 macOS 版（`.dmg`）。iOS 版不在，也不可能在。**

Apple 不允许在 App Store / TestFlight 之外分发 iOS 应用——没有"下载个包装上"这条路。
想在 iPhone 上跑，只有两条：用自己的开发者账号从 Xcode 装到自己的设备，
或者等作者哪天真的上架（目前没有时间表）。

macOS 版走的是签名 + 公证的直接分发，下载打开就能装。

## 仓库结构

bun workspaces 单仓。

```
apps/
├── edge/             Cloudflare Worker + Hono + Supabase + R2 —— 后端主体
├── pendingbot/       SwiftUI 原生 app（iOS / iPad / macOS，xcodegen 体系）
├── admin/            Refine SPA 后台控制台（打包进 edge worker 的静态资源）
└── voice-container/  群语音媒体容器（CF Container + Bun）
packages/
└── identity/         Supabase JWT + 鉴权 middleware
supabase/             migrations / seeds / config
scripts/              schema-regen 校验、Supabase advisor 闸、SECURITY DEFINER 闸、发版脚本
docs/                 只留自建指南；内部账本（进度 / 技术债 / 决策记录）不在这份公开仓库里
```

一起拆出去的还有 **PendingCrew**（Mac 端的 agent 编排 app），它现在是另一个仓库。
代码注释里偶尔会引用 `docs/superpowers/plans/…` 之类的内部设计文档——那些没有一起公开，
读到断链的引用不必当成缺失。

## 参与

见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。简单说：这是个人实验，
issue 和 PR 都欢迎，但作者不保证响应速度，也不承诺路线。

安全问题请走 [`SECURITY.md`](SECURITY.md) 里的私下报告渠道，别开公开 issue。

## 许可

[MIT](LICENSE)。

第三方：
- Agent Skills 预设 vendored 自 [anthropics/skills](https://github.com/anthropics/skills)（Apache-2.0），
  见 [`apps/edge/prompts/skills/anthropic/NOTICE.md`](apps/edge/prompts/skills/anthropic/NOTICE.md)
  和同目录下的 `LICENSE.txt`。
- 运行时 / 库：Cloudflare Workers · Hono · Supabase · Bun · Zod 等，各遵其原协议。

---

<sub>产品定位、功能与目标由作者撰写。技术章节（架构、状态盘点、自建与配置）由 Claude 补写，
其中的数字与结论均来自实际运行的命令或线上只读查询，不是从旧文档转抄。</sub>
