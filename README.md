# PendingBot · 大绿豆

> 内部仓库说明。私有商业产品,未发布。对外品牌站 `pendingname.com` 在另一个仓库。

一个主动反思、主动探索的 AI 朋友:不断回顾你和它的对话,既自省也指出你的盲区;还会自己上网冲浪,带回让你眼前一亮的信息。不是助手,也不是听话的陪伴——是会反驳你、给你新视角的朋友。

核心三件事,都不需要催,到点自己做:
- **复盘 / 校正彼此** — 每聊 N 轮回看对话,自己哪说糊涂了、你哪有盲区,回来讲。
- **网上冲浪** — 自己出门找对你有价值的信息,挑值得讲的带回来(`/surf` 也能手动触发)。
- **一群 Bot 议论你** — 你日常聊的几只 Bot 拉群讨论你,多角度旁观;朋友间还能共养同一只 Bot。

## 仓库结构

bun workspaces 单仓。

```
apps/
├── edge/             Cloudflare Worker + Hono + Supabase + R2 —— 后端主体
├── pendingbot/       SwiftUI 原生 app(iOS / iPad / macOS,xcodegen 体系)
├── pendingcrew/      Mac 端 crew / captain 编排 app
├── admin/            Refine SPA 后台控制台(dashboard 栈,部署 CF Pages)
└── voice-container/  群语音媒体容器(CF Container + Bun)
packages/
└── identity/         Supabase JWT + 鉴权 middleware
supabase/             migrations / config
infra/                Grafana 看板 + dashboards(观测栈)
scripts/              schema-regen 校验 / supabase advisor gate 等工具
docs/                 progress / deploy / decisions / tech-debt 等账本
```

## 跑起来

- **Edge(后端)**:`bun install` 后 `cd apps/edge && wrangler dev` 本地迭代;部署 `bun --filter='@pendingbot/edge' run deploy`。
- **App(iOS / iPad / Mac)**:`cd apps/pendingbot && xcodegen` 生成工程后用 Xcode 打开 `PendingBot.xcodeproj`,选 Signing Team 构建。
- **Admin 后台**:`cd apps/admin && bun run dev`。

平台与计费现状:模型走 Cloudflare AI Gateway Unified Billing(OpenRouter 留 fallback);计费引擎 Polar(钱包本体 / MoR)+ RevenueCat(iOS),门禁走 WalletDO。

## 工作约定 / 文档

- 分支模型、worktree、合并、迁移、部署的完整约定见仓库根 [`CLAUDE.md`](CLAUDE.md)。
- 当前真实进度与阻塞:[`docs/progress.md`](docs/progress.md)。
- 部署 runbook:[`docs/deploy.md`](docs/deploy.md)。
- 结构风险 / 技术债:[`docs/tech-debt.md`](docs/tech-debt.md)。
- 关键决策记录:[`docs/decisions.md`](docs/decisions.md)。

## 第三方

- Agent Skills 预设 vendored 自 [anthropic/skills](https://github.com/anthropics/skills)(Apache-2.0),见 [apps/edge/prompts/skills/anthropic/NOTICE.md](apps/edge/prompts/skills/anthropic/NOTICE.md)。
- 运行时 / 库:Cloudflare Workers · Hono · Supabase · Bun · Zod 等,各遵其原协议。
