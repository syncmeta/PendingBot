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
现状: edge(生产 Worker,api/bot.pendingname.com)、access(Access 门+双层校验)、kv(配置缓存+prompt 下发)、r2(附件上传/取字节+去重+配额)均已落地+生产在用(done);admin board CMS 代码合 main、edge 侧端到端验过但 SPA 未部署生产(partial);ai-gateway 生产路径在用但真实扣费待开关(partial);durable-objects 多数已落(GroupRouter/RealtimeHub/投影 DO 验过),WalletDO/语音 DO 代码+单测齐但计费默认关、群语音 QA 待验(partial);voice-container 整套代码合 main、多人多 bot 实景 QA 待验(partial)。
证据: edge 已部署生产;Access 无凭证→403 已验;admin SPA 未部署生产;计费总开关默认关
task: —

## stack/supabase
status: done
现状: EU 单库在产、Auth+RLS+Storage 在用、新 API key 体系已部署验证;老 legacy key 仍在后台启用待 disable。
证据: 2026-06-04 迁 EU + 2026-06-10 API key 部署已验证(#250)
task: #250

## stack/openrouter
status: done
现状: 模型目录读取 + 边缘缓存 + 预设解析(旗舰/最快/盲盒)代码在生产路径在用;视觉能力/上下文窗口判断读它。
证据: 2026-06-15/16 模型预设+目录实测纠偏已完成
task: —

## stack/polar
status: partial
现状: 引擎/钱包封装 + Polar/RevenueCat 入账 webhook + 群池自研代码+单测齐,P0/P1 资金流已在 Polar sandbox 直连实测通过;生产端到端(真 product_id+配 webhook+翻开开关+真支付)未验,计费总开关默认关。
证据: Polar sandbox 直连实测;progress §4b
task: —

## stack/revenuecat
status: partial
现状: edge 侧 RevenueCat 入账 webhook + 客户端身份 SDK(Telemetry.swift 三端)代码就位;RevenueCat 账号未开通、key 占位空串、IAP 产品未配,真机充值闭环完全未验。
证据: key 占位空串,真机充值闭环未验
task: —

## stack/anthropic+openai (coding-agent runners)
status: partial, pending-qa
现状: Codex 协议字段已对真 schema 校准、两个真 bug 已根治并 GUI E2E 验、单测全绿;活体像素渲染 + 完整真机 QA 是尾巴。(claude-code runner 状态见 stack/anthropic/claude-code 条。)
证据: 机长 post_to_crew 被拒 + session 卡死两 bug 已根治并真 PendingCrew.app 验
task: —

## stack/langfuse
status: partial
现状: Prompt loader 换源 KV 分发+fail-loud、HMAC webhook→KV、trace/score helper 代码+单测齐;16 个 prompt 已 seed 进 Langfuse production。待配 `LANGFUSE_WEBHOOK_SECRET`、翻 `LANGFUSE_ENABLED=true` 开 trace 上报、真实 trace 到面板核验。
证据: 16 prompt seed production;待配 secret/开关
task: —

## stack/posthog
status: partial
现状: edge 服务端事件 helper + iOS/Mac PostHog 身份 SDK 代码就位;Sentry+PostHog 生产已启用(EU host)。待定全套事件规范 + iOS 交互事件补齐 + 真机事件投递闭环 + 漏斗/留存搭建。
证据: 生产已启用(EU host);真机投递闭环未做
task: —

## stack/sentry
status: partial
现状: worker `withSentry` 包裹 + 三处吞错点 captureException 代码齐;Sentry 生产已启用(DSN 已设);客户端 SDK 代码就位但只验了编译+启动不崩,错误真实到达面板的真机闭环未做。
证据: 生产 DSN 已设;真机投递闭环未做
task: —

## stack/grafana
status: partial
现状: 5 张 provisioning 看板(营收/钱包/群池/成本/转化,SQL 全基于真实列) + `bi_ro` 只读角色迁移已建+apply;开 Grafana Cloud 账号、设 `bi_ro` 密码、连 datasource 待用户,看板端到端出图未验。
证据: 看板就绪;端到端出图未验(待用户开账号)
task: —

## stack/apple/sign-in (Google)
status: partial
现状: iOS Google Sign-In→Supabase 换 session 客户端代码已落、iOS OAuth client id 已配;Mac 端 macOS 型 OAuth client 配置与真实 Google 登录回合待做,PendingCrew Google client id 未配。
证据: iOS client id 已配;Mac/PendingCrew client id 未配
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
