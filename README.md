<p align="center">
  <img src="docs/app-icon.png" alt="" width="120">
</p>

<h1 align="center">PendingBot · 大绿豆</h1>

> 以下内容暂时由 Claude 撰写。

<p align="center">
  一个会反驳你的 AI 朋友。<br>
  iOS / iPadOS / macOS 原生客户端 + Cloudflare Workers 后端 + Supabase。
</p>

---

> **这是一个人的实验项目，不是产品。**
>
> 没有上线运营，没有真实用户，没有支持承诺。作者一个人写了四个月，
> 现在把当前的代码原样公开——不是"开源发布"，只是把东西放出来。
> 下面的「状态」一节写清了哪些功能真的跑通过、哪些只是代码在那儿。
> 读之前先接受一件事：**你 clone 下来，开箱什么也做不了**，得先接上你自己的后端。
>
> 界面和文档都是中文的。
>
> *(A personal experiment, not a product. Chinese-language UI and docs.
> Nothing here is hosted for you — you have to run your own backend;
> see [`docs/self-hosting.md`](docs/self-hosting.md).)*

## 这是什么

一个想做成"朋友"而不是"助手"的 AI 聊天 app：会指出你的错、给你新视角、不谄媚。
围绕这个定位，设计上有三件不需要你催、它自己会做的事：

- **复盘 / 校正彼此** —— 每聊 N 轮回看对话，自己哪儿说糊涂了、你哪儿有盲区，回来讲。
- **网上冲浪** —— 自己出门找对你有价值的信息，挑值得讲的带回来。
- **一群 Bot 议论你** —— 你日常聊的几只 Bot 拉群讨论你，多角度旁观。

这三件里，**只有第一件写完了代码，而且线上一次都没真正产出过**。
第二件在生产环境必然失败（唯一的抓取通道从未部署凭据）。第三件写了但零线上数据。
详见下一节——这一节讲的是**想做成什么**，不是**现在能做什么**。

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

- **运行截图**。仓库里那张 `docs/screenshots/01-onboarding.png` 是设计稿，
  画的是还没实现的自建连接引导——不是当前 app 的样子，所以没往上面放。
- **PendingBot 本体的路线图**。原来那本讲的是已经拆走的另一个项目。

## 跑起来

完整步骤（含每一个外部服务要开什么、拿什么）在 [`docs/self-hosting.md`](docs/self-hosting.md)。
那份指南是在一个干净 checkout 上实跑核对过的，包括哪些步骤**没**跑通。

最短路径：

```bash
bun install                                      # bun 1.3.11+
bun --filter='@pendingbot/edge' run typecheck    # 应为 0 错
cd apps/edge && ./node_modules/.bin/vitest run   # 695 例
```

三个组件各自：

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
