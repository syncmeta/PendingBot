# PendingBot — Fact Sheet

> 面向公开场合（GitHub README / 个人网站 / 简历）的事实清单。
> 每条数字都标注了复现命令，可当场验证。口径原则：**只写能公开的**——
> 不含生产数据、成本收入、未修复的安全项。
>
> 数字核准于 2026-08-21，基准 `main`。

## 一句话

PendingBot 是一个 **AI 聊天应用**：你在里面加的"好友"是 AI，可以拉进群、和真人混在同一个会话里。

它想解决的问题是——**通用 AI 助手不记得你**。每次开新对话都从零开始，你得反复交代自己是谁、在做什么。PendingBot 把 AI 放进一个有持续关系的社交结构里：每个机器人对每个人有独立的长期记忆，会定期回头复盘自己说过的话，人格不是写死的设定而是从这些记忆里长出来的。

**当前状态：个人项目，未公开发布，无外部用户。**

## 技术栈

Swift 5 / SwiftUI（iOS 17+ · iPadOS · macOS 14+，单一代码库三端）· TypeScript / Hono on Cloudflare Workers（Durable Objects · R2 · KV · Queues · Containers · AI Gateway）· Supabase Postgres（全库 RLS）· React 19 + Refine 管理台 · Bun monorepo

## 关键数字

| 数字 | 怎么验证 |
|---|---|
| **97,000 行生产代码**（Swift 46.5k + TypeScript 50.2k，不含测试）·461 个源文件 | `git ls-files \| grep '\.swift$' \| xargs wc -l`；TS 同理排除 `*.test.ts` |
| **一套 SwiftUI 代码库交付 3 个平台**（iOS 17+ / iPadOS / macOS 14+） | `apps/pendingbot/project.yml` 的 `deploymentTarget` 与 `supportedDestinations` |
| **单个 Cloudflare Worker 承载 186 个 HTTP 接口 + 10 个 Durable Object 有状态服务** | `grep -rhoE "\.(get\|post\|put\|patch\|delete)\('" apps/edge/src/routes` 计数；DO 见 `apps/edge/wrangler.jsonc` 的 `durable_objects.bindings` |
| **数据层 80 张表 / 212 条迁移 / 130 条 RLS 策略 / 168 个数据库函数**，全库行级安全强制开启 | `ls supabase/migrations/*.sql \| wc -l`；`grep -c "CREATE POLICY" supabase/migrations/*.sql`；表数见 `apps/edge/src/db/schema.ts` |
| **695 个自动化测试，81 个测试文件，全绿**——跑在 Workers 真实运行时里，不是 mock | `cd apps/edge && ./node_modules/.bin/vitest run`（`@cloudflare/vitest-pool-workers`）；类型检查 `bun --filter='@pendingbot/edge' run typecheck` |
| **4 家 LLM 供应商统一到 1 个 AI Gateway**（OpenRouter Chat Completions / OpenAI Responses / Anthropic Messages / Gemini generateContent），刻意不走网关翻译层以保留各家原生能力 | `apps/edge/src/llm/` 下各 provider 适配层 + `wrangler.jsonc` 的 AI Gateway 配置 |

补充可选项（视版面取舍）：
- **20 个模型可调用工具**，注册表存在数据库里，后台开关 60 秒内全局生效、无需部署（`apps/edge/src/lib/tools-registry.ts`）
- **零 VPS**：全部 serverless，无自管服务器
- **pre-commit 强制门禁**：改数据库迁移必须同时提交 TypeScript 类型，边缘代码必带类型检查（`lefthook.yml`）

## 边界（重要，请照抄，不要模糊化）

**① 真正跑通、在生产环境用过的**
- 一对一文字聊天（iPhone / macOS）
- 双通路 LLM 调用（OpenRouter + Anthropic 原生）
- 长期记忆的读写（外部记忆服务 Honcho）
- 三种登录方式 · 设备授权 · 会话列表的边缘投影 · 自动生成会话标题
- 管理台（Cloudflare Access 作为唯一身份源，无应用内登录）· Universal Link · Prompt 远程分发

**② 代码完整、有测试覆盖，但未做过端到端真机验证**
群聊中的 AI 回复 · 语音通话（一对一与群，WebRTC）· 图片与文件附件 · 推送通知 · 主动复盘 · 机器人与群聊的邀请流程 · 加好友 · 模型盲盒 · 代码沙箱 · 应用内购买 · 群账号共享钱包

**③ 开箱不可用，需要额外配置或尚未接通**
- **主动上网探索**（机器人自己上网、写成文章）：依赖托管的 Exa MCP 服务，**需自备密钥**，未配置时该功能不可用。（注意区分：聊天中的实时联网走各家模型自带的服务端工具，不需要这个密钥。）
- **富感知**（让机器人持续感知时间、地点、对方状态等上下文）：设计已定稿，**代码尚未开始**。
- **代码沙箱与群语音**依赖容器服务，本地开发需要 Docker 运行。

**④ 已知的工程缺口（诚实披露）**
- 三端客户端**没有测试 target**，自动化测试目前全部集中在边缘侧。
- 仓库不包含 Xcode 工程文件，用 XcodeGen 从 `project.yml` 生成——**新 clone 必须先跑一次 `xcodegen`** 才能打开工程。

## 相关项目

**PendingCrew**（[独立仓库](https://github.com/syncmeta/PendingCrew)）—— 为支撑单人高并行开发而自研的多 Agent 编排系统：以 git worktree 隔离并行会话，以群聊为共享白板协调多个编码 Agent。2026-08-17 从本仓库拆出，现为独立产品。
