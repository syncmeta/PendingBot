# PendingBot 自建指南

这份指南描述的是当前仓库真实可走通的路径，不把“进程能监听端口”写成“整套产品可用”。核对日期为 **2026-08-20**，基于一个干净 worktree 实跑。

## 先看结论

- 依赖安装、Edge typecheck、Edge 全量测试、裸 `wrangler dev`、Swift Simulator 构建都通过。
- 裸 `wrangler dev` 只证明 Worker 和 admin 静态资源能启动。默认本地环境没有生产环境的 KV/R2/Queue/Durable Object/rate-limit bindings；大部分业务路由也需要本地 Supabase。
- Supabase 全部迁移和两份 seed 已在**禁止外网的 Docker 网络**里完整应用成功。
- 这份公开仓库**不带任何真实的后端坐标**：Worker/Supabase/Turnstile/遥测 key 全是占位值，realtime webhook 的目标地址改为从 Supabase Vault 读取（不配 = 不发）。所以 clone 下来直接跑不会误连任何人的线上服务；代价是**功能性运行前必须先填自己的坐标**，见第 3 节。
- **LLM 功能有额外硬门槛：Langfuse 是 prompt 正文唯一事实源，仓库没有 prompt 副本。** 新部署的 KV 为空、Langfuse 也没有对应 prompt 时，LLM 路径会直接 throw；`LANGFUSE_ENABLED=false` 只关闭 tracing，不能绕过 prompt 加载。

## 1. 前置工具

本次通过验证的工具版本如下；它们是验证快照，不是声明的最低版本：

| 工具 | 本次版本 | 用途 |
|---|---:|---|
| Bun | 1.3.11 | monorepo 依赖、TypeScript 构建/测试 |
| Wrangler | 4.97.0 | 本地 Worker |
| Supabase CLI | 2.107.0 | 本地数据库、迁移、seed |
| Docker Desktop/OrbStack engine | 29.4.0 | 本地 Supabase |
| Xcode | 26.5 | iOS Simulator 构建 |
| XcodeGen | 2.45.4 | 只在 `project.yml` 改过后重建 Xcode project |

安装 Bun、Docker、Supabase CLI、完整 Xcode；仅构建 Edge 时不需要 Apple 或云厂商账号。

## 2. clone、安装和静态检查

```sh
git clone <your-fork-url> PendingBot
cd PendingBot
bun install
bun --filter='@pendingbot/edge' run typecheck
cd apps/edge
./node_modules/.bin/vitest run
cd ../..
```

本次实跑结果：`bun install` 安装 796 个 package；typecheck exit 0；Vitest 为 **81 个文件、695 个测试全部通过**。仓库当前实际数量是 695，不是旧说明里的 681。

## 3. 先填两处后端坐标

这两处在公开仓库里都是占位/未配置状态——**不填也不会连到任何人的线上服务**，但也就跑不通对应的功能。填之前不要指望点开 App 就能用。

### 3.1 Supabase realtime webhook 的目标地址

[`supabase/migrations/20260516073714_realtime_webhooks.sql`](../supabase/migrations/20260516073714_realtime_webhooks.sql) 里的 `pendingbot.notify_realtime()` 会在下面这些表发生 INSERT/UPDATE/DELETE 时，用 `pg_net` 把行变更 POST 给 Edge：

- `pendingbot.messages`
- `pendingbot.bot_lookbacks`
- `pendingbot.group_continue_requests`
- `pendingbot.conversation_participants`
- `pendingbot.user_unread_counts`
- `pendingbot.scroll_runs`
- `pendingbot.crew_announcements` / `pendingbot.crew_sessions`

**目标地址不写在迁移里**，和旁边那个共享密钥一样从 Supabase Vault 读：

```sql
select vault.create_secret(
  'http://host.docker.internal:8787/v1/realtime-internal/notify',
  'realtime_webhook_url');
select vault.create_secret('<随机字符串>', 'realtime_webhook_secret');
```

**不配 `realtime_webhook_url` 时这个触发器什么都不做**——这正是刚 `supabase db reset` 之后的状态，也是对的状态：一个写死的默认值会让每一个 clone 的本地库都去打某个真实主机。代价是客户端收不到消息/未读数的实时推送，其余功能不受影响。

同一个随机值还要作为 `REALTIME_WEBHOOK_SECRET` 配进 Worker，两边必须一致，否则 Worker 会拒收。

宿主机地址：Docker Desktop 上数据库容器通常用 `http://host.docker.internal:8787` 访问宿主；Linux 需要自己提供 host-gateway/DNS。

### 3.2 Swift 客户端的后端坐标

[`HostedConfig.swift`](../apps/pendingbot/Sources/Networking/HostedConfig.swift) 的 `.remote` 分支在这份公开仓库里**全是占位值**（`https://api.example.com`、`https://YOUR-PROJECT.supabase.co` 等），遥测三件套（PostHog / Sentry / RevenueCat）为空串 = 关闭。

配套的 `isConfigured` / `isEmailSignInConfigured` 两个判据就是拿这些常量跟 `HostedConfig.Placeholder` 里的字面量比对。所以未填坐标时：**app 照常启动，只在你真的去点登录入口时**告诉你这份仓库没带这个坐标、去哪儿填——不是启动时弹警告，也不是静默失败。

两条路：

- **只想在本地跑通**：把默认环境改成 `.dev`（`localhost:8787` + `localhost:54321`）——

  ```swift
  static var environment: Environment = .dev
  ```

  `.dev` 的坐标是 `supabase start` / `wrangler dev` 的标准值，判据视其为「已配置」。

- **要发布自己的 App**：填 `Environment.remote` 分支下的 Worker URL、Supabase URL 与 publishable key、Turnstile site key/host，以及需要的遥测 key；再换掉 Universal Links / AASA 域名和 entitlements。**不要改 `Placeholder` 里的字面量**——那是判据的参照物，改了判据就永远为真，app 会退回静默失败。

Google 登录另有一处：`apps/pendingbot/Info.plist` 和 `apps/pendingbot/Resources/Info.plist` 里的 `GIDClientID` 与反转 URL scheme 也是占位（`YOUR_GOOGLE_CLIENT_ID`）。填之前点 Google 登录会抛 `missingClientID`，不会静默。

本仓库当前没有 xcconfig / 环境变量注入来选择 HostedConfig，切换靠改这一行默认值；这是已知的自建缺口（原 tech-debt 有记）。

## 4. 初始化本地 Supabase

先完成 3.1 的 URL 替换或禁用方案，再运行：

```sh
supabase start
supabase db reset --local
```

`supabase db reset --local` 会按文件名顺序应用 `supabase/migrations/*.sql`，然后应用：

1. `supabase/seeds/01_preset_bots.sql`
2. `supabase/seeds/02_place_names.sql`

只使用 `--local`。不要在自建初始化中使用 `--linked`、`db push`，也不需要 `supabase login`。本地端口由 `supabase/config.toml` 固定：API 54321、Postgres 54322、Studio 54323、Inbucket 54324；数据库主版本 17。Auth 本地使用 email OTP 和 Cloudflare 的 always-pass Turnstile 测试 key。

本次验证把 Docker 网络设为 `--internal` 以物理阻断生产 webhook，随后 `supabase db reset --local --yes` 成功应用了全部迁移和两份 seed。这个隔离网络在当前 macOS Docker 引擎上会让 CLI 的宿主机 54322 健康检查失败，因此只作为迁移审计手段，不是推荐的日常开发拓扑。

取得本地 URL/public/server key 时运行：

```sh
supabase status
```

这些值只写入 gitignored 的 `apps/edge/.dev.vars`，不要提交，也不要把输出贴进 issue。

## 5. 配置并启动本地 Edge

先复制模板：

```sh
cp apps/edge/.dev.vars.example apps/edge/.dev.vars
```

至少填本地 `SUPABASE_URL`、`SUPABASE_PUBLISHABLE_KEY`、`SUPABASE_SECRET_KEY` 和 `ALLOWED_ORIGIN`，然后先构建 admin：

```sh
bun --filter='@pendingbot/admin' run build
cd apps/edge
./node_modules/.bin/wrangler dev --local
```

`apps/admin/dist` 是 Wrangler `ASSETS` binding 的目录。干净 clone 若跳过 admin build，`wrangler dev` 会直接报该目录不存在；本次实跑先复现了这个失败，再构建 admin 后成功启动。

另一个终端验证最小存活面：

```sh
curl -i http://127.0.0.1:8787/health
curl -i http://127.0.0.1:8787/board/
```

本次两者均返回 HTTP 200。`--local` 明确禁止 Wrangler 使用 remote bindings；不要为图省事改跑 `--remote`，也不要运行 deploy script。

### 裸本地环境的边界

`wrangler.jsonc` 的顶层（默认 dev）只有 `ASSETS` 和四个关闭状态的 feature flag，没有 production 下的 R2/KV/Queue/DO/rate-limit bindings。所以上述步骤证明的是：

- `/health` 可用；
- admin 静态 SPA 可提供；
- Worker 能解析和监听；
- **不证明**登录后收发消息、附件、群聊、realtime、队列计费或 code execution 可用。

完整本地功能需要给 dev 环境补等价的本地 bindings，或维护一份不含作者 resource ID/route/生产 vars 的自建 Wrangler 配置。当前仓库没有这份配置；不要使用 `--env production` 代替，因为该 env 内含作者的托管 URL 和资源标识。

## 6. Langfuse：LLM 的必配启动数据

这是文本聊天也绕不过去的条件。代码的解析顺序是：

1. Worker isolate 内存；
2. `PROMPTS_KV`；
3. Langfuse `production` label pull；
4. 三层都没有就 throw。

在 [Langfuse](https://langfuse.com/docs/prompt-management/get-started) Cloud 创建项目，或按其 [Docker Compose 自建文档](https://langfuse.com/self-hosting/deployment/docker-compose)部署。取得 project public/secret key 和 base URL，在 Langfuse 中创建以下 **18 个 text prompt**，名称必须逐字匹配 `<name>/zh`，并给可用版本加 `production` label：

```text
system/zh
voice/zh
group-voice/zh
identity-quest/zh
envelope/zh
envelope-injected/zh
envelope-write/zh
envelope-collaborator/zh
title/zh
group-router/zh
bot-social-graph/zh
session-world-model/zh
request-permission-tool-result/zh
lookback-instruction/zh
image-summary/zh
group-bot-intro/zh
output-mode-bubble/zh
output-mode-single/zh
```

英语 Crew 世界模型可再建 `session-world-model/en`；缺失时会回退到中文版本。仓库按政策不提供正文 seed，必须由自建者自行编写这些 prompt。仅填写 Langfuse keys 而没建 prompt，仍会失败。

`PROMPTS_KV` 是推荐的跨 isolate cache，但不是事实源；没有该 binding 时 loader 会直接 pull Langfuse。`LANGFUSE_WEBHOOK_SECRET` 只负责 prompt 更新即时推送，缺失时 webhook 返回 501，冷启动 pull-on-miss 仍可工作。`LANGFUSE_ENABLED` 仅控制 trace ingestion。

## 7. Swift 构建

不改 `project.yml` 时直接运行用户指定命令：

```sh
cd apps/pendingbot
xcodebuild \
  -project PendingBot.xcodeproj \
  -scheme PendingBot \
  -destination 'generic/platform=iOS Simulator' \
  build
```

若改过 `project.yml`，先执行：

```sh
xcodegen generate
```

本次未改 `project.yml`，指定 `xcodebuild` 在 Xcode 26.5 下 `BUILD SUCCEEDED`。这只验证编译；没有启动 Simulator，也没有做登录/消息/语音 GUI QA。

## 8. Edge 的完整变量和 binding 清单

根目录 [`.env.example`](../.env.example) 是变量逐项模板，`apps/edge/.dev.vars.example` 是 Worker 本地子集。以下清单来自 `apps/edge/src/types.ts`、非测试源码中 `env/c.env/this.env` 的实际读取，以及 `wrangler.jsonc`，不是凭部署记忆整理。

### 8.1 核心、LLM 与访问控制变量

| 名称 | 必需性 | 不配置时的行为 / 跳过方式 |
|---|---|---|
| `ENVIRONMENT` | 必需 | Wrangler 顶层已给 `dev`；不要在本地设为 production。 |
| `SUPABASE_URL` | 业务必需 | DB/Auth 路由不可用；基本 `/health` 仍可启动。 |
| `SUPABASE_PUBLISHABLE_KEY` | 业务必需 | 用户 JWT/RLS client 无法创建。 |
| `SUPABASE_SECRET_KEY` | 业务必需 | service-role DB 操作、后台任务不可用。 |
| `ALLOWED_ORIGIN` | 浏览器跨域时必需 | 独立 Vite/iOS webview 跨域请求被 CORS 拒绝；同源 board 可跳过。 |
| `CF_ACCOUNT_ID` | LLM 必需 | 无法构造 AI Gateway URL；也被 RealtimeKit/TURN 使用。 |
| `CF_AIG_GATEWAY` | LLM 必需 | 无法构造 AI Gateway URL。 |
| `CF_AIG_RUN_TOKEN` | LLM 必需 | Authenticated Gateway 请求没有 run 凭据。 |
| `CF_AIG_TOKEN` | 可选 | 不读取 AI Gateway Logs；部分 provider 成本无法落账/结算为 skipped。 |
| `GOOGLE_BYOK_ALIAS` | provider 条件必需 | 不发 alias header，依赖 gateway 的 default BYOK/unified billing。 |
| `LANGFUSE_PUBLIC_KEY` | 空 cache 时 LLM 必需 | 无法 pull prompt。 |
| `LANGFUSE_SECRET_KEY` | 空 cache 时 LLM 必需 | 无法 pull prompt。 |
| `LANGFUSE_BASE_URL` | 自建 Langfuse 必需 | 不设则使用 SDK cloud 默认地址。 |
| `LANGFUSE_WEBHOOK_SECRET` | 可选 | prompt webhook 501；依靠 pull-on-miss。 |
| `CF_ACCESS_TEAM_DOMAIN` | board 条件必需 | 与 AUD 任一缺失，`/v1/board/*` fail-closed。 |
| `CF_ACCESS_AUD` | board 条件必需 | 同上。 |
| `BOARD_ADMIN_EMAILS` | board 条件必需 | 空 allowlist 拒绝所有 board API 用户。 |

### 8.2 可选功能与 secrets

| 名称 | 必需性 | 不配置时的行为 / 跳过方式 |
|---|---|---|
| `BILLING_ENABLED` | 可选，默认 false | false 时不做 live gate/debit，可不配 Polar/RevenueCat。 |
| `SENTRY_ENABLED` + `SENTRY_DSN` | 可选 | 任一关闭/缺失时 Edge Sentry no-op。 |
| `POSTHOG_ENABLED` + `POSTHOG_KEY` | 可选 | 任一关闭/缺失时 Edge analytics no-op。 |
| `POSTHOG_HOST` | 可选 | 使用 SDK 默认 cloud host；EU/自建必须设置。 |
| `LANGFUSE_ENABLED` | 可选 tracing 开关 | false 仅禁 trace，不禁 prompt pull。 |
| `HONCHO_API_KEY` + `HONCHO_WORKSPACE_ID` | 可选但影响记忆 | 基本 HTTP 可启动；Honcho catch-up/dialectic 产生 warning、空记忆或工具错误。 |
| `EXA_API_KEY` | 可选 | seed 中的 Exa hosted MCP 没有 auth，web search/fetch 工具不可用。 |
| `TAVILY_API_KEY` | 可选/预留 | Env 已声明，当前默认聊天面没有 wiring，设置也不会启用 Tavily。 |
| `APNS_TEAM_ID`, `APNS_TOPIC`, `APNS_KEY_ID_DEV`, `APNS_KEY_ID_PROD`, `APNS_KEY_DEV`, `APNS_KEY_PROD` | 推送条件必需 | 不配可做非推送开发；APNs 注册/发送失败。六项应成组配置。 |
| `OPENAI_API_KEY` | 语音条件必需 | 1:1 Realtime 和群语音 bot leg 不可用；文本不受影响。 |
| `REALTIMEKIT_ACCOUNT_ID` | 群语音可选 | 缺失时回退 `CF_ACCOUNT_ID`。 |
| `REALTIMEKIT_APP_ID` + `REALTIMEKIT_API_TOKEN` | 群语音条件必需 | 无法建 meeting/participant token。 |
| `REALTIMEKIT_HUMAN_PRESET`, `REALTIMEKIT_BOT_PRESET` | 可选 | 使用代码中的 starter preset 名；dashboard 必须存在对应 preset。 |
| `TURN_KEY_ID` + `TURN_KEY_API_TOKEN` | 可选 | 强制 `webrtc_turn` 失败；auto transport 跳到 WebSocket fallback。 |
| `REALTIME_WEBHOOK_SECRET` | realtime 条件必需 | notify route 拒绝 webhook；必须与 Supabase Vault 一致。 |
| `POLAR_ACCESS_TOKEN`, `POLAR_PNC_METER_ID` | billing 条件必需 | billing route 返回未配置/501；保持 billing false 可跳过。 |
| `POLAR_SERVER` | 可选 | runtime client 默认 production；本地务必显式 `sandbox`。 |
| `POLAR_WEBHOOK_SECRET` | Polar webhook 条件必需 | 无法验证 Polar webhook 签名。 |
| `REVENUECAT_WEBHOOK_AUTH` | iOS 计费 webhook 条件必需 | RevenueCat webhook Authorization 校验失败。 |

数据库 `mcp_servers.secret_ref` 还允许动态读取任意 Worker secret 名；checked-in migration 当前只 seed `EXA_API_KEY`。以后加 connector 时，`secret_ref` 的名字也必须通过 Wrangler secret 提供。

### 8.3 Wrangler bindings 与资源

| Binding / 配置 | 类型 | 功能 | 必需性 |
|---|---|---|---|
| `ASSETS` | Worker static assets | `/board` SPA | `wrangler dev` 当前配置必需；先 build admin |
| `UPLOADS` | R2 bucket | 附件、头像、图片读写 | 附件功能必需 |
| `MEMORY` | KV | Honcho/config/MCP schema cache | 可选 cache；缺失时部分代码 direct-load/catch，但性能和记忆退化 |
| `PROMPTS_KV` | KV | Langfuse prompt 分发 cache | 可选 cache；Langfuse 仍必需 |
| `GROUP_ROUTER` | Durable Object | 群聊 debounce/小模型路由 | 群聊必需 |
| `Sandbox` | container-backed DO | `execute_code` | code execution 必需 |
| `REALTIME_HUB` | Durable Object | 会话/用户 WebSocket fan-out | app realtime 必需 |
| `REALTIME_METER` | Durable Object | 1:1 语音 sideband/metering | 1:1 语音计量必需 |
| `ROOM_VOICE` | Durable Object | 群语音控制/计费 | 群语音必需 |
| `ROOM_MEDIA` | container-backed DO | RealtimeKit/音频媒体进程 | 群语音必需 |
| `SESSION_PROXY_DO` | Durable Object | 跨设备 Crew session 控制 | 远程 session 必需 |
| `WALLET` | Durable Object | subject wallet 强一致 cache/outbox | live billing 必需 |
| `CONV_PROJECTION` | SQLite DO | conversation 消息尾/roster projection | Edge projection 路径必需 |
| `USER_PROJECTION` | SQLite DO | user 会话列表/未读 projection | Edge projection 路径必需 |
| `HANDLE_LOOKUP_RL` | Rate Limit | handle lookup/join 防枚举 | 对应 endpoint 必需；缺失会在 `.limit()` 处失败 |
| `AUDIT_QUEUE` | Queue producer | LLM audit/billing 异步落库 | production intended path 必需；缺失时 catch 后尝试 inline persist |

production config 还要求：

- Queue `pendingbot-audit` 的 consumer 和一个不消费的 DLQ；
- 3 个 cron：每日、每 5 分钟、每 30 分钟；
- 两个 Container image（Edge Sandbox 与 `apps/voice-container`）；
- Durable Object migration tags v1-v9；
- 自己的 custom domains/routes。不要复用仓库中的作者域名、resource ID 或 bucket/queue 名。

Cloudflare 本地开发默认模拟 KV/R2/Queues/DO/Containers；参考 [local bindings](https://developers.cloudflare.com/workers/local-development/bindings-per-env/) 和 [Wrangler configuration](https://developers.cloudflare.com/workers/wrangler/configuration/)。部署前应在自己的 account 中逐项创建/替换资源，再运行 `wrangler secret put`；本指南不执行部署。

## 9. 逐个外部服务要开什么、拿什么

| 服务 | 自建者需要创建/取得 | 不使用的后果 |
|---|---|---|
| Cloudflare Workers | Worker、自己的 route/domain；Account ID | 没有公开 Edge API；本地 `wrangler dev` 仍可做最小验证 |
| Cloudflare R2 | attachments bucket；binding 名 `UPLOADS` | 附件/头像/图片不可用 |
| Cloudflare KV | `MEMORY`、`PROMPTS_KV` 两个 namespace | cache 退化；Langfuse 仍是 prompt 真源 |
| Cloudflare Queues | audit queue、DLQ、producer/consumer | audit 改走 inline fallback；不适合作为 production 拓扑 |
| Cloudflare DO/Containers | 10 个 DO bindings、2 个 Container image、migration tags | 群聊/realtime/语音/code exec/session proxy/wallet/projection 分项不可用；Containers 参考[入门](https://developers.cloudflare.com/containers/get-started/) |
| Cloudflare AI Gateway | gateway slug、Authenticated Gateway run token；可选 Read API token；为 provider 配 unified billing/BYOK | 文本 LLM 路由不可用；无 Read token 时部分成本未知 |
| Cloudflare Access | Access application、team domain、AUD、允许的 admin email | board API fail-closed；不用 board 可跳过 |
| Cloudflare RealtimeKit/TURN | RealtimeKit app、Admin token、human/bot presets；可选 TURN key/token | 群语音不可用；无 TURN 时 1:1 auto 可回退 WS |
| Supabase | hosted project或本地 CLI；URL、publishable key、secret key；应用全部 migration/seed | Auth、RLS、数据、配置和大部分业务全部不可用 |
| Langfuse | cloud/self-host project、public/secret key、base URL、18 个 production prompts；可选 webhook secret | **LLM prompt 直接缺失并 throw** |
| Honcho | workspace ID、API key | 长期记忆/dialectic 退化；基础 HTTP 可启动 |
| Exa | API key；DB seed 已指向 hosted MCP | web search/fetch tools 不可用 |
| OpenAI | server API key | 语音不可用；文本 provider 仍走 AI Gateway |
| Apple Developer/APNs | team ID、bundle/topic、dev/prod APNs token keys | push 不可用；Simulator build 不受影响 |
| Polar | sandbox/live org、access token、PNC meter、webhook signing secret | billing/top-up 不可用；保持 billing false 可跳过 |
| RevenueCat | Apple public SDK key、webhook endpoint和共享 Authorization 值 | iOS IAP/回调不可用；空 client key 时 SDK 跳过 |
| PostHog | project API key、正确 cloud region/self-host ingest host；iOS 与 Edge可共用 project | analytics no-op |
| Sentry | Worker JavaScript project DSN、独立 Apple project DSN | error telemetry no-op |
| Grafana/Metabase/Appsmith | 可选 BI/运营栈；read-only `bi_ro` DB credential，各产品自身 secret/token | 不影响核心 app；只缺 dashboard/admin fallback |

## 10. 其他 app / infra 的环境读取

### Admin SPA

实际源码只读 `VITE_EDGE_API_URL`，且可选；缺失时使用 page 同源。它不读 Supabase URL/key。独立 Vite 开发时复制 `apps/admin/.env.example`；production 与 Edge 同包时不需要 `.env`。

### Group voice container

`apps/voice-container` 读取：

- `PORT`：可选，默认 8080；
- `CHROME_HEADLESS_SHELL_PATH`：可选，Dockerfile 已设 `/usr/bin/chromium-headless-shell`；
- `CHROMIUM_PATH`：可选 fallback。

进程本身不保存 RealtimeKit/OpenAI secret；Worker 通过 DO 控制通道传入会话级配置。

### Swift 客户端

Swift 不从 shell `.env` 读配置。`HostedConfig.swift` 编译进：Worker/Supabase endpoint、Supabase public key、Turnstile site key/host、PostHog public key/host、Sentry Apple DSN、RevenueCat public SDK key。空 telemetry/billing client key会跳过对应 SDK。

此外，share links、Universal Links/AASA 和 device-login 仍包含项目作者域名。换品牌/域名时要搜索并替换，同时更新 Apple Associated Domains entitlement 和 Cloudflare route。

### 观测看板

这份公开仓库不带作者的 Grafana 看板和 Metabase/Appsmith 编排（那是运营口径，跟跑起来无关）。观测侧要什么自己接：Edge 走 `SENTRY_DSN` / `POSTHOG_KEY` / Langfuse，Swift 侧的三个 key 见 `HostedConfig`。`.env.example` 里保留了变量名清单可作参考。

### One-off scripts

Polar spike/verify script读取 `POLAR_ACCESS_TOKEN`（required）、`POLAR_SERVER`（默认 sandbox）和 `SPIKE_METER_ID`（optional）。release script只检测已废弃的 `BUILD_NUMBER_FORMAT` 并报错，不应再设置。`HOME` 是系统环境，不属于项目配置。

## 11. 没有外部服务时明确不可用的功能

| 功能 | 缺少什么会不可用 |
|---|---|
| 文本聊天、标题、来信、lookback、识图摘要、群路由 | AI Gateway run config或对应 Langfuse production prompt |
| Auth/会话/消息/好友/群/配置 | Supabase |
| realtime 推送 | 正确的本地 webhook URL + Vault/Worker secret + `REALTIME_HUB` |
| 附件、头像、图片工具 | R2 `UPLOADS` |
| 群聊路由 | `GROUP_ROUTER` DO + Supabase + LLM prompt/gateway |
| code execution | Cloudflare Sandbox Container/DO |
| 1:1 语音 | OpenAI key + `REALTIME_METER`; TURN 可由 WS fallback 替代 |
| 群语音 | OpenAI + RealtimeKit + `ROOM_VOICE` + Cloudflare Container `ROOM_MEDIA` |
| 远程 Crew session | `SESSION_PROXY_DO` 和对应本地 runner（PendingCrew 已不在本仓库） |
| push | 完整 APNs token-auth 配置和真机 token |
| 计费/充值/IAP | Polar、RevenueCat、Wallet DO、Queue；或保持 billing off |
| 长期记忆/用户表征 | Honcho；KV 只是一层 cache |
| web search/fetch | Exa key和可达 hosted MCP |
| board API | Cloudflare Access + email allowlist；静态页面能开不等于 API 有权限 |
| telemetry | 对应 Sentry/PostHog/Langfuse keys和 enable flag；都可关闭 |

## 12. 本次验收记录

| 验收项 | 实跑结果 | 备注 |
|---|---|---|
| `bun install` | PASS | 796 packages |
| Edge typecheck | PASS | exit 0 |
| Edge Vitest | PASS | 81 files / **695 tests**，不是旧预期 681 |
| `wrangler dev` | PASS（最小启动） | 干净 clone 首次因缺 `apps/admin/dist` 失败；先 build admin 后监听 8787，`/health` 与 `/board/` 都 200 |
| Swift 指定 xcodebuild | PASS | Xcode 26.5，`BUILD SUCCEEDED`；未改 project.yml，未跑 xcodegen |
| Supabase migrations + seeds | PASS（隔离审计） | 无外网 Docker 网络内 `db reset --local` 全部成功 |
| 完整本地产品 E2E | **未通过/未宣称** | 被硬编码 webhook、Swift 默认 remote、dev bindings 缺失和外部 prompt/service bootstrap 阻塞 |
| GUI/真机/语音/计费 | 未跑 | 需要账号、真机或收费云资源，不属于这次无凭证本地验收 |

停掉本地服务：Worker 终端按 Ctrl-C；Supabase 使用 `supabase stop`。若只是一次性本地审计且明确不要保留本地数据库备份，可使用 `supabase stop --no-backup`。

## 参考文档

- [Cloudflare Workers local development](https://developers.cloudflare.com/workers/local-development/)
- [Cloudflare AI Gateway authentication](https://developers.cloudflare.com/ai-gateway/configuration/authentication/)
- [Supabase local CLI workflow](https://supabase.com/docs/guides/local-development/cli-workflows)
- [Supabase database migrations](https://supabase.com/docs/guides/local-development/database-migrations)
- [Langfuse prompt management](https://langfuse.com/docs/prompt-management/overview)
- [RevenueCat webhooks](https://www.revenuecat.com/docs/integrations/webhooks)
- [Polar webhooks](https://polar.sh/docs/integrate/webhooks/endpoints)
