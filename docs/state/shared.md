> 现状 handbook · shared 区。镜像 [期望 handbook](../handbook/README.md) 结构,每 session 强制刷。一条 = 一个概念/功能的实际状态。对齐 = 拿它和期望同路径并排看。

## charter
status: done
现状: 当前生效的产品信条 + 红线 + 商业立场,随重大转向更新;无落地 gap(它是约束本身,不是功能)。
证据: 变更史见 evolution/pivots
task: —

## product-taste
status: partial
现状: 风格标尺已立,落地参差——多数 UI/文案仍在"删废话"路上,新功能照尺走、老界面边碰边收。
证据: —
task: —

## concepts/subject
status: partial
现状: Subject 双类 schema + `responsible_subject_id` 上链 bots/conversations 已落 + db push prod;下游消费(计费/可见/批准统一走该字段)链路已铺,但计费 pre-launch 端到端未验、客户端未全面消费。
证据: T1.1(#161-163,代码+已 db push);progress 主线表 T1.1
task: #161

## concepts/group-accounts
status: partial
现状: 群账号创建/加踢/充值/退份额/解散整套服务端已落(edge `/v1/group-subjects/*` + `grp_*` RPC);iOS/Mac 客户端尚未消费,无真实群账号数据 + 计费未开,端到端未验。
证据: progress T1.2(#167,edge 有、客户端没消费)
task: #167

## concepts/group-permissions
status: partial
现状: 三级固定角色矩阵服务端整套已落、权限由 `grp_*` RPC 强制;iOS/Mac 客户端尚未消费,仍走旧 client 规则;计费相关端点 pre-launch 未验。
证据: progress T1.2(#167)
task: #167

## concepts/device-grant
status: partial, pending-qa
现状: 服务端三条登录路径端点已落 + 部署(device-login challenge / mint / family-credential,签发 + 级联撤销 + scope 夹逼);客户端 P1+P2 已落代码。真机尾巴多且必做(共享 keychain 跨 app 真读 / OAuth 全链路 / 扫码端到端,需真签名 app + Xcode GUI),且 `devicePublicKey` 仍占位、未与物理设备密码学绑定。
证据: progress T1.3 + 2026-06-17 登录搬迁行;`devicePublicKey` placeholder(已记 tech-debt)
task: —

## concepts/data-visibility-rls
status: done
现状: 模型已落地并验证——头像 metadata 泄露已关、两条受限路径头像字节已服务、隐私号查找带限流、subject 维度可见性随 schema 上链;作为横切底线在加好友/群成员/bot 邀请等已验功能里持续生效。
证据: D3 验证(见 avatar-visibility);隐私号查找限流
task: —

## concepts/avatar-visibility
status: done
现状: 已落地(D3,2026-06-01):关 metadata 泄露(迁移 `20260601080625` 删全局头像 RLS 分支)+ 两条场景服务头像字节(`/v1/uploads/:id` 头像例外)均已 push live。小遗留:`users.avatar_path` 查找未建索引(pre-launch 可接受)。
证据: 迁移 `20260601080625`、`upload.ts`,已 push live
task: —

## concepts/conversation-types
status: partial
现状: 会话类型 schema(含 crew/temporary_group/subagent)已落 + db push;1:1/群/子会话(委托)是当前已验证主路径(done);crew/临时群编排底座代码已落但端到端依赖 PendingCrew 登录 + runner,整体 pre-launch 未全验。
证据: schema 已 db push;crew 现状以 pendingcrew 册为准
task: —

## concepts/models
status: partial
现状: 预设系统代码全落 + 已部署 prod,端点侧真验通过(`GET /v1/model-presets` 返真旗舰);统一计费(AI Gateway)+ 目录缓存为 done。尾巴:iOS 登录态模拟器/真机走查未做;改预设数据不自动失效 KV(需手动 bust,2026-06-19 踩到);"最热门"是评测质量榜非真实使用量榜;速度快候选 cap/质量下限是拍的。
证据: `GET /v1/model-presets` 返真旗舰、已部署 prod;2026-06-19 KV bust 踩坑
task: —

## concepts/bot-tools-and-scopes
status: done
现状: 注册表 + scope 过滤 + `model_description` 热改已落地并部署(board 工具管理页 P3 上线,只读+改不建不删);MCP 服务器 CRUD 页 P4 也已上线;读路径走 60s isolate 缓存 + KV 读穿。
证据: board 工具页 P3 + MCP CRUD 页 P4 上线
task: —

## concepts/config-as-cms
status: partial
现状: board CMS 七页(P0–P4)全部完成并部署,功能开关/工具/MCP/预设各页线上可用,KV 下发与审计 before/after 在跑。尾巴:七+两页浏览器端到端点验未逐一做(Access 后 SPA headless 进不去);直改源表不 bust KV 的缺陷待根治(现靠手动 bust + cron 兜底)。
证据: P0–P4 已部署;KV bust 缺陷已记 tech-debt
task: —

## concepts/prompts
status: partial
现状: prompt-loader + Langfuse + KV webhook 分发已落地(main),fail-loud 无兜底副本,session 世界观注入活路径在跑。尾巴:个别历史内联 prompt 迁后"getPrompt 真去 Langfuse 拉到"的端到端真验要等真消息/通话触发;重新 seed 是运营动作。
证据: 已合 main;16 prompt 已 seed Langfuse production
task: —

## concepts/read-path
status: partial
现状: 全链路代码已落地并合 main(两投影 DO + webhook 写穿 + 冷回填 + fail-closed 授权门;客户端三端 Repository 收口 + edge-first/DB fallback cutover)。核心尾巴:iOS/Mac 真机 + 真边缘端点 runtime 正确性还是纸面,需部署 + 真机冒烟;授权门↔RLS 对齐无测试守护(🔴 结构隐患);delta 游标实际多走全量(since=0)。配置→KV 部分为 done。
证据: 已合 main;授权门↔RLS 对齐隐患记 tech-debt(🔴)
task: —

## concepts/billing-subject
status: partial
现状: 责任主体解析(门禁/扣费共用单口子)代码已落、逻辑自洽,但整套计费 pre-launch 未开、端到端未真验;统一计费(AI Gateway)+ BYOK 计费退役 + vendor 成本→PNC 折算不加 markup 为 done;`BILLING_ENABLED` 默认 OFF。
证据: progress §4b(Polar P0–P2 表);stale-model-audit(provider 路由对齐);`pnc.ts`
task: —

## concepts/wallet-pnc
status: partial
现状: Polar 引擎 + PNC 单位 + 客户端封装为 done(真 sandbox spike 验过收/扣/退/读/幂等)。其余 partial:WalletDO(缓存+outbox+对账)代码+单测落地但端到端未真验;充值入账幂等已落但 `ensureCustomer` 409 分支待实测;Apple IAP JWS 验签手写 + 14 单测绿但无真实 sandbox 交易;4 档阈值硬停在但 low/throttle 未完整落地;`BILLING_ENABLED` 默认 OFF。
证据: Polar sandbox spike 验过(刷新~10–12s);progress §4b;Apple JWS 真机回归记 tech-debt
task: —

## concepts/group-pledge
status: partial
现状: 实缴池+份额衰减、认缴(pledge)模型、部分取出 `/withdraw`、门禁聚合、链式退款冲群/群池漂移报警/`/leave` 一步退群——全部代码+单测落地("尾巴"也做完),但整套计费引擎 pre-launch 端到端未真验,`BILLING_ENABLED` 默认 OFF,无一项为 done。
证据: progress §4b(群成本分摊 #208 / 认缴模型 #213 / 群分摊尾巴 #210)
task: #208

## concepts/group-share-index
status: partial
现状: `share_index` 记账公式(注资不变 / 消费等比缩 / 取出只缩自身 `contributed`)已从线上 SQL 函数(`apply_group_contribution` / `apply_group_pool_spend` / `apply_partial_withdraw`)与 `share-index.ts` 原样核实、算例手算校验过,是 group-pledge 实缴池那部分代码已落地的记账逻辑——文档跟着代码走,状态随 group-pledge 一起 partial(同一套 pre-launch 未真验、`BILLING_ENABLED` 默认 OFF)。
证据: 与 concepts/group-pledge 共用(progress §4b)
task: #208

## stack/anthropic/claude-code
status: partial
现状: 终端托管/字节注入/审批 hook 接线代码全落、本机闭环验过(SwiftTerm + permission-mode auto + world-model/whiteboard/approval hook);真机 QA(登录态起 app 验)是尾巴。
证据: flag 本机实测过
task: —

## stack/apple
status: partial
现状: PendingBot 三端共享地基 + 全 feature slice 跨平台 + iPad/Mac 多列壳已合 main,Mac 首屏/iPhone 实装本机验过(Mac 有 composer 缺失/相机缺失/二维码占位等降级尾巴);PendingCrew 双端 build 通、本地模式 GUI 验过、Claude Code + Codex 两 runner 已实现并真机验过(跨端遥控/fly 云机/hub 推送有尾巴);sign-in 服务端端点已落+部署、客户端代码已落,真机链路(keychain 跨 app/OAuth/扫码)待验。ASC TestFlight 上传链路已验。
证据: 三端共享 UI 合 main;Claude Code/Codex runner 真机验;ASC 归档→上传→处理已验
task: —

## stack/cloudflare
status: partial
现状: 2026-08-19 只读盘点复核。**在用(有线上实据)**: edge Worker(生产 `pendingbot-edge`,最新部署 2026-08-18 07:36,`GET /v1/health` 实测 `environment: production`;api + bot.pendingname.com 两条 custom_domain,AASA 实测返回真 appIDs)、Access(`/v1/board/*` 无凭证实测 403,`/board/` 200)、KV(PROMPTS_KV 21 键 / MEMORY 有 cfg·bal·memo·botnote·user·bot 真数据)、Queues(`pendingbot-audit` 1 生产者 1 消费者 + dlq 都在)、AI Gateway(audit_log 2026-08-19 有 `provider_slug: anthropic` 成功记录)。**没跑起来**: R2 —— `pendingbot-uploads-prod` **object_count = 0**、`attachments` 表 0 行(此前本条写的「r2 生产在用(done)」不成立,已纠);Containers 两个 image 都 ready 但 `bot_code_exec_requests` 0 行、`voice_active_calls` 0 行,真实调用未发生;Turnstile 客户端 site key 已配(`HostedConfig.swift:74`),**secret 是否贴进 Supabase Auth 后台无法只读验证,没贴=验证码形同虚设**(代码注释自陈)。**缺口**: `CF_AIG_TOKEN` 从未部署 → 主路径每次调用成本记不下来(tech-debt 🟡);线上残留 14 条代码零引用的 secret,其中一条的**名字本身是 Daytona token**(tech-debt 🔴)。
证据: wrangler deployments/secret list/kv key list/r2 bucket info/queues list/containers list 实查 + `/v1/health`·AASA·`/v1/board/*` 实测(2026-08-19)
task: —
## stack/supabase
status: done
现状: EU 单库在产。2026-08-19 实据: `/auth/v1/settings` 返回 apple/google/email 三种登录均为 true;库里 87 messages / 20 bots / 16 conversations;**DB webhook → edge 实时 fan-in 活着** —— `net._http_response` 6 次全 200、最新 2026-08-19 02:10:49,vault 里有 `realtime_webhook_secret`(2026-06-04),8 张表挂 `realtime_notify` 触发器。老 legacy anon/service_role key 仍在后台启用待 disable(worker 侧已不读,但两条 legacy secret 还留在线上)。**已知缺口**: `conversations` / `user_unread_counts` 两条投影喂养触发器缺失(见 tech-debt 2026-08-19 🔴,另有 session 在治)。
证据: `/auth/v1/settings` + `net._http_response` + `pg_trigger` + `vault.secrets` 实查(2026-08-19);2026-06-04 迁 EU + 2026-06-10 API key 部署(#250)
task: #250
## stack/openrouter
status: done
现状: 作为 AI Gateway 上的一条 provider 通路在产使用,并且是模型目录的唯一来源(`llm/catalog.ts:20` / `routes/models.ts:466` 直连 `openrouter.ai/api/v1/models`)。2026-08-19 实据: `audit_log` 有 `provider_slug: openrouter` 的成功记录且**带真实 cost**(2026-08-18 04:41 `google/gemma-4-31b-it` 起标题 $0.000012;2026-06-10 `openrouter/auto` $0.028880)。注意: OpenRouter 自报成本,所以 `CF_AIG_TOKEN` 缺失那个洞**不影响它**,只吃掉原生透传(anthropic/openai/gemini)的成本 —— 别据此误判「成本记录一切正常」。
证据: `audit_log` 实查(2026-08-19);2026-06-15/16 模型预设+目录实测纠偏
task: —
## stack/polar
status: partial
现状: 引擎/钱包封装 + Polar/RevenueCat 入账 webhook + 群池自研代码+单测齐。2026-08-19 只读盘点新增实据: **计费在线上其实是开着的** —— `wrangler.jsonc` 写 `BILLING_ENABLED:"false"`,但线上 KV `cfg:feature-flags` = `{"langfuse":true,"billing":true}`,override 胜出(本条此前「计费总开关默认关」的说法不成立,已纠)。`pnc_ledger` 4 行: 1 笔真实 `polar_checkout` topup(2026-07-11)+ signup 赠送 + 2 笔 admin grant → **Polar webhook 收单这一半通过了**;但那笔 polar_checkout 的 `polar_synced = false` —— **疑似漏账**(分不清是推 Polar 失败、还是推成功而标记那句 UPDATE 失败,判别要去 Polar 侧对余额),且因幂等键任何重试都走不到 grantCredits;`polar_synced` 这个字段**全仓库只写不读**(tech-debt 2026-08-19 🔴)。POLAR_ACCESS_TOKEN / POLAR_WEBHOOK_SECRET / POLAR_PNC_METER_ID / POLAR_SERVER 四条 secret 均已部署。**Polar 侧真实余额只能人工在后台核**。
证据: 线上 KV `cfg:feature-flags` + `pnc_ledger` + secret list 实查(2026-08-19);Polar sandbox 直连实测;progress §4b
task: —
## stack/revenuecat
status: partial
现状: edge 侧 webhook(`/v1/billing/revenuecat/webhook` + `REVENUECAT_WEBHOOK_AUTH` 已部署)+ 客户端身份 SDK 代码就位。**本条旧说法「账号未开通、key 占位空串」已不成立** —— iOS 公钥已经配上(`HostedConfig.swift:132` `appl_OHplTtFSfcqsgKJvjZajkelEOJo`),但 `Telemetry.swift:25` 的注释仍写着「key 空、账号未开通」,是**代码注释漂移**。真实缺口在别处: `pnc_ledger` **0 条 iap_ios 入账**,真机内购闭环从未跑过;RevenueCat 后台是否配了 IAP 产品需人工确认。
证据: `HostedConfig.swift:132` + `pnc_ledger` + secret list 实查(2026-08-19)
task: —
## stack/anthropic+openai (coding-agent runners)
status: partial, pending-qa
现状: Codex 协议字段已对真 schema 校准、两个真 bug 已根治并 GUI E2E 验、单测全绿;活体像素渲染 + 完整真机 QA 是尾巴。(claude-code runner 状态见 stack/anthropic/claude-code 条。)
证据: 机长 post_to_crew 被拒 + session 卡死两 bug 已根治并真 PendingCrew.app 验
task: —

## stack/langfuse
status: partial
现状: 拆成**两半**看,状态不同(注意 prompt 取用**不受** `LANGFUSE_ENABLED` 影响,那个 flag 只管 trace)。**① prompt 分发 = 通的**: `PROMPT_NAMES` 18 条 × zh + `session-world-model/en` 共 19 条**全部**在线上 `PROMPTS_KV` 里(实查),含 `lookback-instruction` —— 回看链路不缺 prompt。**② trace 上报 = 配齐但未核**: `LANGFUSE_ENABLED` 在 wrangler.jsonc 与线上 KV override 里都是 true、`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY` 已部署,但面板里有没有 trace 只能人工看。**③ 缺口**: `LANGFUSE_WEBHOOK_SECRET` **从未部署** → `/prompt-webhook` 恒返 501,改 prompt 不会推进 KV、而 KV 层没有 TTL,可能长期不生效(tech-debt 2026-08-19 🟡);KV 里另有 2 个已从 `PROMPT_NAMES` 删除的孤儿键。
证据: `wrangler kv key list`(PROMPTS_KV 21 键)+ secret list + `cfg:feature-flags` 实查(2026-08-19)
task: —
## stack/posthog
status: partial
现状: edge 服务端事件 helper + iOS/Mac SDK 代码就位。配置侧 2026-08-19 复核**齐全**: `POSTHOG_ENABLED=true`(wrangler vars)、`POSTHOG_KEY` 已部署、`POSTHOG_HOST=https://eu.i.posthog.com`;iOS 侧 `HostedConfig.swift:105` 有 `phc_…` 项目 key、同一 EU host。**未验的是「面板里到底有没有事件」** —— 只读手段够不到(MCP 需 OAuth,不开浏览器),列入待人工确认。另待做: 全套事件规范 + iOS 交互事件补齐 + 漏斗/留存搭建。
证据: wrangler vars + secret list + `HostedConfig.swift:105` 实查(2026-08-19)
task: —
## stack/sentry
status: partial
现状: worker `withSentry` 包裹(`index.ts:249`)+ 三处吞错点 captureException;`SENTRY_ENABLED=true`(注意 Sentry **只认 env、不受 KV override**,见 `feature-flags.ts` 文件头)、`SENTRY_DSN` 已部署;iOS 侧 DSN 在 `HostedConfig.swift:124`(Apple 项目,与 worker 的 JS 项目不同)。**未验的是「错误真实到达面板」** —— 只读手段够不到,列入待人工确认。
证据: `index.ts:249` + wrangler vars + secret list + `HostedConfig.swift:124` 实查(2026-08-19)
task: —
## stack/grafana
status: partial
现状: 5 张 provisioning 看板 + gcx 版资源文件都在仓库(`infra/grafana/{dashboards,gcx,provisioning}`);`bi_ro` 只读角色**线上确实存在**(`pg_roles` 实查,可登录)。2026-08-19 新增实据: 本机 `~/.config/gcx/config.yaml` 里有 `stack-id: 1678832` → **Grafana Cloud 账号已开通**(本条旧说法「待用户开账号」已过时)。仍未验: gcx CLI 本机未安装,看板是否真导入 / datasource 是否真连上 Supabase,只能人工在面板确认。
证据: `pg_roles` 实查 + `~/.config/gcx/config.yaml` stack-id + `infra/grafana` 文件树(2026-08-19)
task: —
## stack/apple/sign-in (Google)
status: partial
现状: PendingBot iOS/Mac 侧**客户端配齐并已核**: `Info.plist:42` `GIDClientID = 842392349572-…apps.googleusercontent.com` + 反转 URL scheme 都在,`GoogleSignIn.swift` 走 SDK in-process 换 session。服务端侧 `/auth/v1/settings` 实测 **google + apple + email 三种都是 true**。剩余缺口不变: Mac 型 OAuth client 的真实登录回合待验;**PendingCrew 的 Google client id 仍未配**(那是另一个 bundle id)。
证据: `Info.plist:42` + `/auth/v1/settings` 实查(2026-08-19)
task: —
## stack/fly
status: planned
现状: 机器清单里 `kind=fly` 字段结构 + 新建流程的机器选择 UI 已占位;云 API 集成、box 开通/关停、按秒计费、冷启动唤醒 UX 全未实现。
证据: v1.1 规划,表结构+UI 占位仅,实现见 tech-debt
task: —

## evolution/roadmap-and-status
status: partial
现状: 地基 + 本地闭环基本就位(Phase 0–3 多数代码已落、多数已验),通信/跨端代码齐但活验有尾巴(实时推命令/两设备 E2E QA 仍公开),端到端 QA(T5.3)从未真机完整跑通——是 v1.0 release-ready 真实门槛、progress 里唯一标 ❌ 的 roadmap task。pre-launch 单环境。
证据: progress §2 v1.0 主线表 / §3/§4;T5.3 未做(progress ❌)
task: —

## evolution/pivots
status: partial
现状: 九条重大转向均已拍板、方向确定;运行时残留大多已清(provider/计费引擎/双轨/captain/arena→盲盒/EU 区/board→Access 已落代码并大体收口),dashboard 去 VPS(8)代码就绪但待用户开账号端到端验,产品使命校准(9)是叙事层掉头、残留在文案/README/老 spec。部分注释/命名/旧 spec 引用待捎带清理。
证据: 2026-06-16 审计 R1 实删 captain 编排面(净 -1341 行);stale-model-audit 顶部「处置进度」
task: —
