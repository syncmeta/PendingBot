# PendingBot / PendingCrew 进度账本 (Progress Ledger)

**最近对账：2026-06-05**（对照实际代码 / 迁移 / git，不是看 task 标记）

> **2026-06-05 Mac 全面对齐 iOS（dynamic workflow，`feat/mac-login-align`，未合，#212）**
> - **背景**：用户「都做，开 dynamic workflow 做完」。用 Workflow 顺序流水线（共享工作树，每块端到端：原生重画 + 接线 + xcodegen + iOS/macOS 双端编译到绿 + commit），4 个 area agent 串行。**逻辑全复用跨平台层，纯 SwiftUI 原生重画**；iOS-only 选择器（PhotosUI/UIImagePicker）用 NSOpenPanel 替代。
> - **① 设置/我页**（commit `d091f8cf`）：`MacSettingsView`（锁屏通知预览 + 通话连接模式，Form `.grouped`，sheet）、`MacProfileEditView`（改名 + 头像 seed 轮换 + NSOpenPanel 自定义图 → /v1/upload）、`MacNameCorpus`（iOS NameCorpus 被 `#if os(iOS)` 圈住后读同一 names.txt 的镜像）；MacMeView 接入设置/资料/注销（`request_account_deletion` RPC + 两档 sentiment），头像换 ServerImage/BrandAvatar。
> - **② 加好友 + 机器人**（`4850f853`+`11055362`）：`MacBotManagement.swift`（MacAddFriendSheet 输入号码 lookup→/v1/friend-requests、MacCreateBotSheet 单模型/可见性/公开 slug 直写 bots+user_bot_contacts、MacManageBotSheet 改名/模型/可见性/slug/删除、MacModelPickerSheet 基于跨平台 ModelCatalog）；MacFriendsColumn 加「+」+ bot 行右键「管理…」；PendingBotApp Mac 入口注入 `ModelCatalog.shared`。
> - **③ 聊天补全**（`e1a3bfb4`）：MacChatView 加附件（NSOpenPanel→`ChatDataSource.upload`→待发预览→带 attachmentIds 发送；气泡内图走 ServerImage、文件走 chip）+ 群聊渲染（按 conversation_type 路由发送，user_user 直插 Supabase，群非自己气泡画发送者头像+名；新增跨平台 `ChatDataSource.loadGroupSenders`）。
> - **④ Crew 群聊** —— workflow 一度做了（`b9c20958`：MacCrewChatView/MacCreateCrewSheet/MacCrewDetailSheet + 右栏分段 + crew 数据层去 iOS 门禁），但**用户决定先别管 Crew**（产品方向/方案未定，等 Crew 那边定型再做），已 **`git revert`**（commit 见下）。Mac crew 右栏回到只有「服务端 session 查看」+ 群钱包；CrewAPI/CrewChatModels/PermissionRequestCard 恢复 `#if os(iOS)` 门禁。**Crew Mac 端 = 暂缓，不在本轮范围。**
> - **验证**：撤 Crew 后合并方（我）重跑 `xcodegen` + iOS Simulator + macOS **双端 BUILD SUCCEEDED**。Mac app 已启动到桌面。
> - **缺口（agents 已记 tech-debt 🟡，仅剩①②③）**：**全部只编译校验，没真机/真账号验**——写回合（资料保存/注销、建管 bot/发好友申请、附件上传、群消息收发）需 Xcode GUI 构建 + 真账号点验；视觉像素未截图核对。功能性缺口：Mac 建 bot 无 arena 多模型池、无机器人配置子面（识图/搜索/写信/技能/语音 toggle/分段气泡/时区/邀请管理/分享）；加好友/机器人无扫码（Mac 无摄像头，只输入码）、加机器人未接 invite token resolve；附件无客户端压缩（iOS 降 2048 JPEG，Mac 直传原图）、无全屏查看器、无 @mention 富文本。**未合 main。**



> **2026-06-04 Mac 个人钱包原生重画 + iOS 钱包死代码清理（`feat/mac-login-align` 续，#253/#212）**
> - **背景**：用户「钱包什么的 已经迁移了的 都重新弄一下 ios 也一起」。核查现状：iOS 个人钱包 `WalletV2View` 已是新 PNC/Polar 模型（活，挂 MeTab）；`GroupWalletView` 也是新模型但**零入口**（#227）；老 `WalletView`(billing v1) 已零引用=死；**Mac 完全没有钱包**。数据层 `BillingService`/`GroupWalletService`/`APIClient` 本就跨平台。
> - **Mac 个人钱包**：新 `MacWalletView`（原生 List `.inset` 镜像 iOS 钱包：余额/包/账本，Theme token），作为 sheet 从 `MacMeView` 弹出；MacMeView 加钱包概览（余额+阈值）。抽跨平台 `WalletV2Format`（formatPnc/各 label/阈值·过期文案/formatters），iOS `WalletV2View` 删自带 static helper 改复用 —— 两端同源不复制。
> - **iOS 清理**：删死的 `WalletView.swift`；`BillingService` 砍掉只被它用的 v1 成员（Balance/fetchBalance/applySilentUpdate/redeem/Summary/fetchSummary/Log*/fetchLog），只留 `WalletV2 + fetchWalletV2`。双端 build 印证无他处引用。
> - **群钱包（用户「iOS+Mac 都现在做」）**：抽跨平台 `GroupWalletShared`（`GroupWalletFormat` + `AmountForm`），iOS `GroupWalletView` 删自带 static/本地 enum 改复用。新 `MacGroupWalletView`（原生 List `.inset` 镜像 iOS：群池/份额/认缴/成员/操作 + 充值·认缴·取出 sheet + 退群/解散确认），`crewId→subjectId` 走跨平台 `listCrewsV2`（`CrewAPI.getCrewV2` 是 iOS-only）。**接入口**：iOS `CrewDetailV2View` 加「账户 > 群钱包」NavigationLink（#227 收口）；Mac `MacRemoteSessionsView` 工具栏「群钱包」按钮 → sheet。
> - **缺口（记 tech-debt 🟡）**：删 v1 钱包连带删了**兑换码入口**，新钱包两端都没有兑换 UI（后端仍能兑换）——待定是否在新钱包补。
> - **验证**：iOS Simulator + macOS 双端 `xcodebuild` BUILD SUCCEEDED（个人钱包 + 群钱包 + 入口）。未合 main。真机/真账号视觉与写操作（充值/认缴/取出/退群/解散）回合未实测。

> **2026-06-04 PendingBot Mac 登录界面对齐 iOS（`feat/mac-login-align`，未合，#253/#212）**
> - **动机**：用户「开 Mac 我看看 → 登录界面要和 iOS 统一」，选了**完全对齐三种登录**（Apple+Google+邮箱）。Mac 原本是极简 email-only（一个 SF Symbol + 验证码），iOS 是打磨过的完整版（BrandMark logo + 三登录 + 「你是？」人机验证分步 + Turnstile + 验证码 + 机器人彩蛋）。
> - **跨平台基座**（commit 1）：`Theme`/`Platform`/`Haptics` 去掉 `#if os(iOS)` 整体围栏 → 原生 macOS 拿到同一套 `Palette/Fonts/Metrics` 设计 token（UIFont 辅助用 `canImport(UIKit)` 精确围）；`Platform.isMac` 原生 Mac 为 true（0.88 桌面字号）；`Haptics` Mac 端 no-op。`AppleSignIn`/`GoogleSignIn` 放开到 macOS：Apple 原生 `ASAuthorizationController`（NSWindow anchor），Google 走 GoogleSignIn-iOS 的 **macOS target**（`signIn(withPresenting: NSWindow)`，该包对 macOS 本就链接）。
> - **共享逻辑**（commit 2）：抽跨平台 `WelcomeViewModel`（stage/Turnstile token 时序/resend 冷却/test-email 后门/Apple/Google/邮箱 OTP 全套），iOS `WelcomeView` 改薄渲染层、**顺手删掉内联的 Apple SIWA ~90 行**改走共享 `AppleSignIn.run()`。两端登录逻辑不再各写一份（避开 copy-paste 债）。
> - **Mac 重画**（commit 3）：`MacWelcomeView` 逐块原生镜像 iOS（同 logo/排版/pill/箭头行/人机验证/彩蛋/Theme token），渲染层 AppKit + `MacTurnstileWebView`（NSViewRepresentable），glass 用 macOS 26 `.glassEffect` + `.regularMaterial` 回退。
> - **验证**：iOS Simulator + macOS **双端 `xcodebuild` BUILD SUCCEEDED**；Mac app 已启动到桌面。**未做（记 tech-debt 🟡）**：① 本 session TCC 屏幕录制权限被拒，**截不了图 → 视觉确认待用户**；② **Apple/Google 在 Mac 上的真实 sign-in 回合未跑**（邮箱 OTP 与 iOS 同路、可信）——Google 还依赖一个 **macOS 型 OAuth client** 配置（现有 GIDClientID 是 iOS 型，Mac 上可能 invalid_client），启用前必须按 tech-debt 清单坐实。
> - **合 main**：待用户（且 Mac 三登录真验证前别对外声称可用）。

> **2026-06-04 PendingCrew 中栏群聊 UI 对齐 PendingBot iOS（`feat/pendingcrew-chat-align`，未合）**
> - **动机**：中栏群聊原是自绘简易气泡（圆角 12、两色填充、无头像、行内文字标签），与 PendingBot **iOS** 那套打磨过的群聊（头像+名字抬头+连续圆角+hairline+暖色 token+时间分隔 pill）观感脱节。**原生重画**对齐，数据仍绑 `CrewWhiteboardEntry`，不抽共享包、不引 PendingBot 私有代码（保 PendingCrew 可独立开源定位）。spec/plan 见 `docs/superpowers/{specs,plans}/2026-06-04-pendingcrew-chat-*`。
> - **edge（零迁移）**：核到中栏白板端点 `GET /v1/crews/:id/messages` 读的是 conversation 的 `messages` 表（经 `mapMessageToEntry`），sender 身份本就在行里（`user_id`/`sender_bot_id`/`log_payload.session_id`），只是映射没透出 → 纯序列化补 `sender_user_id`/`sender_bot_id`/`sender_session_id`（commit `788614c8`，+3 vitest，17 passed）。
> - **PendingCrew（9 个新文件 + 重构）**：`CrewTheme`（搬 iOS Theme 数值）、`CrewColorHash`（搬 iOS 头像配色算法，subagent 发现并纠正了计划里的错误常量）、`CrewSenderResolver`/`CrewAvatar`（bot/session/human 三态）、`CrewBubbleRow`/`CrewTimeSeparator`/`CrewInteractionCard`/`CrewComposer`/`CrewRosterBar`；`CrewChatView` 重构成瘦容器。
> - **过程坑**：计划误判"新文件被 project.yml glob 自动纳入、无需 xcodegen"——实际 `.xcodeproj` 已 commit，加文件**必须重跑 xcodegen**，否则文件不进 target、build 假绿。Task 12 重生 pbxproj 收口（commit `a01c74f6`）；干净构建已独立核实真绿（9 文件全编译 → BUILD SUCCEEDED）。
> - **待**：① 真机/真用视觉核对（需用户登录态 + 有 session/bot/多消息的 crew）；② `localUserId` 暂 nil（AppModel 不暴露 user id）→ 多人 crew 里人类作者归属错，已记 tech-debt 🟡；③ 合 main 待用户。

> **2026-06-04（夜）观测/计费尾巴三 lane 落地 + 应用到 EU（本 session，已合 main，未部署）**
> - **背景**：用户「都做」→ dynamic workflow 三 lane 并行（隔离 worktree），由合并方串行 integrate。**PendingCrew 按用户指示不碰**：Lane C（captain/crew #241/#242）整条 **parked**，未合并（另有 `feat/pendingcrew-chat-align` 活跃 session）。
> - **观测/prompt（#247/#248/#249，合 `feat/observability-langfuse-finish`）**：① prompt-loader override 源从 `i18n_prompts` 表切到 **Langfuse Prompt Management**（`<name>/<locale>` production label，bundled `.md` 仍兜底，`LANGFUSE_ENABLED` 关时纯本地）+ **DROP i18n_prompts**（迁移 20260604103403）；② traceGeneration 发**完整 prompt/completion 本文**（router.ts:580；**反转**早先"只发结构指标"隐私口径——Langfuse 第一方，用户要全功能）；③ arena Elo→**Bradley-Terry MLE**（`lib/arena-bradley-terry.ts`，response shape 不变，iOS 解码不动）+ 每票喂 `langfuse.score`。
> - **计费尾巴（#252/#228/#226，合 `fix/billing-tails-email-norm`）**：① welcome-bonus **email 规范化**防薅（迁移 20260604102812：`normalize_email` + `welcome_bonus_grants` dedup 账本 + `claimWelcomeBonus`）；② `topup_succeeded` PostHog 事件**改接 Polar/RC webhook**（原接在已删的 lemon/iap）；③ group-invite 流**解耦旧分摊**死表（`groupBillingInviteSnapshot`→中性 hint）。
> - **验证**：edge typecheck 0 + **497 vitest 全绿**（把 `router-trace.test` 从"无 content"断言改为"校验完整 input/output 转发"，匹配 #248 新行为）。两迁移已 **push EU**——**main worktree 顺手从旧 US 库 relink 到 EU `zafhoiwwpanpuashtnxy`**，db push 走 **session pooler**（`aws-1-eu-central-1.pooler:5432`；直连 `db.<ref>` 在本网络 TLS EOF）。schema regen 干净（i18n_prompts 去 / welcome_bonus_grants 入）。
> - **未做/blocked**：#248 运行时（部署 + 开 prod `LANGFUSE_ENABLED` + 真实一轮 trace 到达面板，可用 PostHog/Sentry MCP 自动核）；#252 **DeviceCheck 主力**（真机）；#226 **物理 drop**（subject_wallets/group_member_billing 仍被 live RPC 写，需多-RPC 重写专项）；Lane C parked。新增 **3 条 tech-debt**（normalize_email 双实现、B 段表 drop 卡 RPC、iOS 兜底文案）。**未部署 worker、未 push main**（按约定等用户）。

> **2026-06-04 Supabase 迁 EU 区（Frankfurt）+ 观测三件套上线（`feat/managed-config`，已部署）**
> - **动机**：用户数据 GDPR/EU 驻留。主库原在 US（us-west-2），pre-launch 无真实数据 → **EU 新建项目 `zafhoiwwpanpuashtnxy`（eu-central-1）、全套迁移重跑、不迁数据**。旧 US 库 `sslzhblojwkxfdyisity` 留作回退，EU 端到端全验后再删。
> - **Phase 1 库**：180 迁移干净 apply（87 表 + 4 BI 视图 + `ensure_rls` event trigger + `metabase_ro` 角色）、seed（6 preset bots + 19683 地名）、schema regen、edge typecheck 全绿。**修了一个账本漂移**：`public.rls_auto_enable`（public schema 建表自动开 RLS 的安全网）早于 `0001_init` squash、只活在 US 库从未进账本，空库重跑撞 42883；已把 live 定义逐字补回迁移 `20260524175632`，账本自洽（任何空库可重建）。
> - **Phase 2/3 代码+部署**：硬编码仅 3 处（wrangler `SUPABASE_URL` + iOS `HostedConfig` URL/anon key）。worker secret 换 EU anon/service + 新 `REALTIME_WEBHOOK_SECRET`（worker secret + EU vault 两边同值）；**deploy 切 EU**（health=production、AASA 200、`/b/*` 查库 404 非 500 = 连库成功）。
> - **观测**：**Sentry + PostHog 生产启用**（EU host：`eu.i.posthog.com` / `cloud.langfuse.com`）。Langfuse keys 已备但 `LANGFUSE_ENABLED` 暂 false —— 用户要全功能（发完整 input/output 本文），等 `traceGeneration` 发本文（#247/#248）再开，免得先发半成品指标 trace。
> - **附带发现**：supabase storage **空**（附件走 R2），换区零影响，少一摊。`feature flags` 经评估**不迁 PostHog**——现有 `*_ENABLED` 是运维 kill-switch，故意零运行时依赖，迁 PostHog 是反模式（循环依赖）。
> - **待**：Phase 4 控制台 Auth（Site URL / Apple+Google OAuth / Turnstile secret / SMTP / email 模板，用户配）；Phase 5 iOS 端到端验证（真机注册登录→写库→realtime）；旧 US 库删除；Langfuse 发本文 + prompt→Langfuse Prompt Mgmt（#247）+ arena Elo→Bradley-Terry（#249）。
> - **Grafana 解卡**：建 4 个 security-definer 聚合视图绕 RLS（不给宽松 policy），dashboard 03/05 SQL 指向视图（迁移 `20260604044057`，已 apply EU）。看板端到端待 Grafana Cloud 账号 + datasource。`metabase_ro` 正名 `bi_ro` 未做（成本铺开到 README，搁置）。
> - **Phase 4 Auth 已配+验**：Site URL / Apple / Google / Turnstile / SMTP(Resend) 全配好；`/auth/v1/settings` 实测 apple+google+email 全 enabled。
> - **signup P0 修复**：EU 重建逼出潜伏 bug —— 计费退役 drop 了 `group_billing_config` 表却漏改 `bootstrap_user_id`（仍往里 insert），空库每次注册都 500「Database error saving new user」；US 库同样潜在坏，只是没真注册没暴露。`CREATE OR REPLACE` 去掉死 insert（迁移 `20260604085445`，commit `fe4a8920`），admin `generate_link` 验证 signup 通、返回 OTP。
> - **prompt→Langfuse 第一步**：15 个 .md（zh 14 + en 1）已推进 Langfuse Prompt Management（命名 `<name>/<locale>` + production label），管道验证通。**loader 换源 + 退役 `i18n_prompts` 未做**（#247，留新 session）。
> - **登录决策**：评估过"纯 OAuth"（能省 SMTP/收件箱/email 滥用），**最终决定留 email OTP + Apple + Google 三种并存**（不把退路交第三方、email 触达、覆盖面）。改为"把防滥用做好"；`reject_disposable_email` / Turnstile **留着**（现在是防滥用一环，别删）。

> **📋 `feat/managed-config` 接手清单（新 session 按序做）**
> - **块1 · EU 收尾**：Phase 5 iOS 真机端到端（email OTP 登录 → 写库 → realtime）→ 验过**删旧 US 库** `sslzhblojwkxfdyisity` → `feat/managed-config` **合 main**。清 `devtest@pendingname.com` 测试用户。
> - **块2 · 防滥用（发计费前）**：welcome bonus（35 PNC）薅羊毛 —— 主力 **iOS DeviceCheck/App Attest 绑 bonus（一设备一次，跨账号无效）** + 辅助 **email 规范化（gmail 去 `+`/`.` 归一查重）**。详见 tech-debt 🔴 条。email 规范化零风险可随手先加。
> - **块3 · 托管化续做**：#247 prompt→Langfuse loader 换源（prompt 已推好）/ #248 Langfuse 发本文 + 开 `LANGFUSE_ENABLED` / #249 arena Elo→Bradley-Terry + 喂 Langfuse score / #246 Grafana 看板出图（待 Grafana Cloud 账号）。
> - **测试账号**：登录留 email；测试用免费 Google 账号一键登 / `你的邮箱+别名`（Resend 已接能收码）/ Apple 用 Sandbox tester。本地开发可 `supabase start` + Inbucket(`:54324`)看邮件。

> **2026-06-04 计费/观测上线收口 + 全项目死代码清理（计费 lane，已部署）**
> - **送/兑换全改走 Polar**：新用户 welcome **35 PNC**（= 旧 3500 PND 原值）via `lib/billing-grant.ts:grantSignupBonus`（挂 `/me/profile`，幂等 + 仅 BILLING_ENABLED 时种）；兑换码 `billing_redeem` RPC 退化为只校验+标记 used，入账走 `creditRedemptionToPolar`（ensureCustomer+grantCredits）；`/redeem` 受 BILLING_ENABLED 门控（关时拒绝、不消耗码）。
> - **退役老路径**：A 段 billing-v2/v1 孤儿已 **drop 到生产**（7 表 + 8 RPC + signup 触发器，迁移 `20260603112148`）；删 `apps/board`（旧自制后台，改用 dashboard 栈）；删一批死代码（balance-cache / getThreshold / gateUsage / decayShareIndex / SessionUser / 废错误码 / dev:web 等）。B 段（`subject_wallets` / `group_member_billing` + invite 流）留 #226。
> - **kill-switch（默认全 OFF）**：`BILLING_ENABLED` + 观测 **per-service** `SENTRY_ENABLED` / `POSTHOG_ENABLED` / `LANGFUSE_ENABLED`（`lib/feature-flags.ts`）。纯 env var、零运行时依赖；**启用步骤见 `deploy.md`**。
> - **已部署**：worker 上线（kill-switch 全关 = 不挡人/不烧配额，零行为变化）；A 段 drop 已 db push + schema regen。**送/兑换在生产休眠**（计费开关关）。
> - **死代码全扫**：workflow fan-out 全仓扫 60 处 → 安全区（edge/supabase/packages）清 17 项；Swift 区（iOS/macOS/crew）22 项**只登记交接**（见 tech-debt，owner session 用 xcodebuild 核验后清）。
> - **未验**：`ensureCustomer` 的 409（已存在客户）分支待 sandbox spike 实测（P0 spike 已验证全新客户 create+grant+balance）；启用计费前用 token 跑一次。
> - **大扫除**：worktree 30→2、分支 60+→2（只剩 main + 计费分支），死分支全删。

> 2026-06-03 整合分支 `chore/billing-dashboard-specs` = main(#212 Mac) + 计费(P2/认缴/退役/尾巴) + dashboard(观测/Refine/Grafana) + iOS 群钱包。
> - iOS 钱包/计费 UI 接群钱包（实缴池+认缴）：edge `GET /v1/group-subjects/:id/wallet` 读端点（群池+我的份额/占比/认缴+成员明细）；iOS `GroupWalletService` + `GroupWalletView`（充值/认缴/取出/退群/解散，骨架待视觉定稿）；修个人钱包 `WalletV2` 解码崩溃。**连根拔旧 per-conversation 分摊**做了安全部分（删死 `lib/group-billing.ts`+3 配置路由 + 退役 `GroupBillingSheet`），剩 invite 流解耦 + 表/RPC 物理 drop 留 #226。
> - **未决/未验**：群钱包页入口待定（群聊≠group_account，须从 group_account subject 起，#227）；真机/真数据未验（端点未部署 + 无群账号数据 + Polar 配置未填 secret）。

> **2026-06-03 #212 Mac 真复用收口**：把 Mac 端「轮询 + 手抄 iOS 查询」纠正成真复用。**实时通道**（`RealtimeManager`/`RealtimeSocket` 去 gate，两端同一条自建 RealtimeHubDO，删 Mac 三处轮询）+ **4 条查询全部收口成共享 fetch**（会话 `ConversationFetch`、bot 好友 `BotContactsFetch`、人类好友 `ContactsFetch`+中性 `ContactProfile`、来信 `EnvelopeFetch`+`EnvelopeRun` 移共享）——iOS 缓存/富渲染层叠在共享 fetch 上、Mac 投影 summary。仅剩**消息历史**1 条仍是 Mac 薄读复刻（iOS 那条是喂 GRDB 缓存的脆弱重管线 #145-147/#150，按 tech-debt 等 Mac 接附件渲染时再收）。另:`PlatformImage` 抽象 + `ServerImage` 跨平台 + Mac 人类好友真实头像;**macOS 打开 Development 签名**(根治 supabase.gotrue.swift 钥匙串反复弹授权/-34018)。iOS 会话 tab 进模拟器验证无回归；好友/来信为同种逐字搬迁+两端编译过（无 tap 工具未逐 tab 点验）。#212 保持 in_progress（剩 Mac 功能缺口：机组完整/头像图片其余面/附件 + 消息查询收口）。

---

## 0. 这个文档是什么 / 不是什么

这是**活的进度视图** —— 回答"现在到底做到哪了、验证没、卡在哪、下一步是什么"。它是 task system / roadmap / tech-debt 三者之间的**对账与汇总层**，把它们串起来，补上"进度叙事"这个谁都没覆盖的缺口。

四个账本各有本职，**不要混用**：

| 账本 | 本职 | 粒度 |
|---|---|---|
| **Task 系统**（内置 TaskList） | 原子勾选清单，**做没做的事实源** | 单个可提交单元 |
| **roadmap**（`superpowers/plans/2026-05-28-v1-0-implementation-roadmap.md`） | 计划 / 做事顺序 / 依赖 | phase / T 编号 |
| **tech-debt**（`tech-debt.md`） | 结构风险 + 关不掉的尾巴登记 | 风险条目 |
| **本文件**（progress） | 当前真实状态汇总 + 阻塞 + 下一步 | 工作流 / feature rollup |

**判断"做没做"以 Task 系统为准；判断"现在整体到哪了"以本文件为准；两者冲突 = 该对账了。**

## 1. 维护纪律（这个文档失效就白建了）

- **绑到已发生的动作**：小单元 auto-commit 的同一拍翻对应 task 状态；合 sub-agent worktree 后由汇总方对账那批 task。
- **`completed` = 已验证可用**，不是"代码写了"。需人工/真机才能 done 的，task 保持 open + 缺口记 tech-debt。
- **本文件每次 session 末、或合一批活之后更新**，顺手改 roadmap/tech-debt 对应条目，别攒到一次性审计。
- 顶部"最近对账"日期每次更新时改。**超过一两周没动 = 大概率已漂移，需重新对账。**

---

## 2. v1.0 主线（按 roadmap phase）

状态：✅ 完成且验证 · 🟡 部分/有洞 · ❌ 未做。验证列：代码=已合入树 / typecheck / 真机=端到端跑过。

| Roadmap | 状态 | 验证 | Task# | 缺口 / 下一步 | tech-debt |
|---|---|---|---|---|---|
| T0.1 PendingBot 三端脚手架 | 🟡 | 代码 | — | Mac 仅"我"+"好友"tab 接真数据；消息/Crew/来信仍 placeholder | 🔴 Mac 业务接入 |
| T0.2 PendingCrew 双端脚手架 | ✅ | 代码 | — | — | — |
| T1.1 Subject schema | ✅ | 代码 | #161-163 | — | — |
| T1.2 群账号权限矩阵 | 🟡 | 代码 | #167 | edge `/v1/group-subjects/*` 有；**iOS/Mac 客户端没消费**，仍走旧 client 规则 | — |
| T1.3 群账号扫码登录 | 🟡 | 代码 | — | `devicePublicKey` 是 placeholder，没真绑设备 | 🟡 device key placeholder |
| T1.4 三端 IM 基础壳 | 🟡 | 代码 | — | Mac 三栏结构在；中栏会话列表 + 右栏消息流仍 placeholder | 🔴/🟡 Mac 子树 |
| T2.1 Crew schema 扩展 | ✅ | 代码 | — | ⚠️ 三组字段双写未 cutover | 🟡 三组字段双写 |
| T2.2 Captain 三种来源 | ✅ | 代码 | #163 | ⚠️ 实有第四种 `spawned_by_captain`，spec 未同步 | 🟡 spec §6.3.1 |
| T2.3 DAG + 环检测 | ✅ | 代码+单测 | — | 递归 CTE trigger + `crew_attach_as_child` + 内联测试 | — |
| T2.4 责任比例 5 规则 | ✅ | 代码+单测 | — | `crew_recompute_shares`/`propose_split_distinct`/tiebreaker 全有 | — |
| T3.1 Claude Code runner | ✅ | 代码 | — | 本轮修了 nested-ObservableObject 不回流 bug | — |
| **T3.2 Codex runner** | ✅ | 代码+单测 | #202 | argv codex 分支补 `--json`(JSONL 事件流,对标 Claude stream-json)+ `-m/--model` 透传;launch/env/discovery 早已 kind-无关复用。11/11 测试绿(含 model 透传) | — |
| T3.3 工作目录三层 | ✅ | 代码 | — | GitWorktreeService + session sheet | — |
| T3.4 子进程安全 | ✅ | 代码 | — | env 白名单 + SIGTERM/grace/KILL + 首启 disclosure | — |
| T3.5 Session 创建面板 | ✅ | 代码 | — | — | — |
| T4.1 Session↔群聊通信 | ✅ | 代码 | #166-169 | mailbox/whiteboard + post_to_crew | — |
| T4.2 Session 系统提示模板 | ✅ | 代码 | #168 | 走 prompt-loader | — |
| T4.3 Permission Request | ✅ | 代码 | #170-176 | schema + tool + iOS/Mac 卡片 | — |
| T4.4 Bot start_crew tool | ✅ | 代码 | — | `tools/start-crew.ts` + tool-def | — |
| **T4.5 跨端遥控 peer_device** | 🟡 | 代码+**runner 链真机验** | #204 | **服务端比账本旧写的完整得多(2026-06-02 重新核实)**:不止 SessionProxyDO —— `crew_sessions` 表 + 整条 runner HTTP 生命周期都在:`POST /v1/crews/:id/sessions`(创建)·`runner-hosts/:id/sessions/:sid/{claim,events,finish}`(`runner:write`)·`GET /v1/sessions/:sid/proxy/connect`·`PATCH .../permission-mode`。**runner 链 + viewer 读 已真机端到端验通(2026-06-02)**:① wire codec(`d6fba7a3`,14测试绿)② session 生命周期 API client(`289788b3`)③ **runner-loop 接线**(`8cabab1c`,CreateSessionSheet 登录态起 session → register host→createSession→claim→边跑边 appendSessionEvent→finish)④ **viewer**(`acf9db29`,RemoteSessionsView 轮询 listCrewSessions/getSessionEvents 渲染转写)。**真机验**:PendingCrew Mac 登录起 Claude Code session → DB 出现 crew_session(queued→running→cancelled)+ 4 条 session_events,viewer 原样渲染(截图核对一致)。途中抓到并修 createSession 路径 bug(复数 crews→单数 crew,`e986d778`,compile-only 抓不到)。**剩(都需 SessionProxyDO WS,非 HTTP)**:实时推送(session.state 边跑边推,现 viewer 靠 3s 轮询)+ **遥控发命令**(session.command,viewer 现只读)。**iOS PendingBot viewer 已补并真机验通(2026-06-02,`RemoteSessionsView.swift` + `getCrewSessionEvents`,入口 CrewDetailV2View terminal 按钮;用户用骆店账号在 iOS 上看到 test2 渲染)**。**每步需 device-grant `runner:write`,活验证要登录账号+真机** —— 宜作连贯 feature 一次做,别拆成孤儿/半接(create-不-claim 会留 queued 孤儿行) | 🟡 半截桥(服务端**全好**+codec,客户端链未接) |
| T4.6 iOS Crew Tab v2 | 🟡 | 代码 | — | 群聊 UI + live push + 权限卡done；剩附件、自我气泡高亮 2 洞 | 🟢 Crew Tab 2 洞 |
| T5.1 PendingCrew BYOK 未登录 | ✅ | 代码 | #177 | 本机 captain 池 + BYOK key | — |
| T5.2 双轨路由 | ✅ | 代码 | #177 | EdgeBackend/LocalBackend；⚠️ 无单测 | 🟢 backend 无单测 |
| **T5.3 端到端 QA** | ❌ | — | — | **BYOK/cloud 全链路从没真机跑通** | 仍延期 |

### roadmap 维度真实缺口（就这几个真"没做"）
- ✅ ~~T3.2 Codex runner~~ —— 已补完(#202,2026-06-02)。其上层 **JSONL 事件解析层**也已落地(#203,2026-06-02):`RunnerEventParser` 把 codex/claude 两种 JSONL flatten 成统一 `RunnerEvent` 模型,接进 `CrewSessionRun.events` 并在 session 窗口加「转写」tab 渲染;schema 取自实跑两个 CLI 的 fixtures,9 测试绿。本机 runner 闭环(Phase 3)真实缺口已清零(剩 T5.3 真机 QA 见下)。
- ❌ **T5.3 端到端 QA** —— 整链路没真机验证
- 🟡 **T4.5 客户端侧** —— **PendingBot 三端 viewer 代码齐了**：iPhone（只读已真机验 + 实时 banner/cancel 编译绿）、iPad（随 iOS universal，同代码）、**Mac（PendingBot macOS 端新接 Crew tab：crew 列表→session viewer→实时+cancel，编译绿）**。跨平台层（CrewSessionAPI / SessionProxyClient / SessionStatusStyle）已抽共享。另有 PendingCrew Mac 独立 app 的 runner 发布 + 实时/cancel 在 `feat/t45-ws-transport`。仍缺：**两设备 E2E QA**（Mac 起活 session + 任一 viewer 实时看&cancel）+ Mac app 登录骆店真机看 test2 + permission over WS。WS 地基铺好，差活 session 串一次。
- 🟡 **PendingBot 完整原生 Mac 版**（T0.1/T1.4，#212）—— 用户明确要完整原生 SwiftUI macOS（非 Catalyst）。架构:逻辑/数据/网络 100% 跨平台共享，UI 壳逐块原生重画。**2026-06-02 夜间一口气推进(均两端 BUILD SUCCEEDED + 合 main)**:
  - ✅ **我 tab**(MacMeView，先前已有)
  - ✅ **登录**(MacWelcomeView+MacRootGate，Email OTP+Turnstile，**用户真机验通**)
  - ✅ **机组 viewer**(MacRemoteSessionsView，实时 banner+cancel)
  - ✅ **消息**(MacMessagesView:会话列表+1:1/群文字聊天+流式发送;跨平台 ChatDataSource+ChatStream;查询列名/FK/role 已 DB 核对;第一版无 Realtime(轮询)/附件/群组 peer)
  - ✅ **好友**(MacFriendsColumn:机器人+人类好友列表;跨平台 FriendsDataSource;第一版只读)
  - **验证状态(2026-06-03 computer-use 重连后真机截图验通)**:**消息 tab 完整 IM 闭环跑通** —— 会话列表(真实数据)+ 聊天历史 + 发消息 + **SSE 流式 bot 回复** + user 右对齐蓝气泡/bot 左对齐灰气泡 + 会话预览轮询更新,全部截图确认。**好友 tab 跑通** —— bot 列表 + 点 bot 跳转到会话(pendingConversationJump 状态机工作)。修了一个真机发现的瑕疵:bot 气泡背景 controlBackgroundColor 浅色下≈白→改 secondary.opacity(0.15)。iOS 范本回归也已截图确认未退化。**机组列表空**:这台 Mac 登录的账号非 test2 owner(骆店),crew 自然空——数据/账号问题,非 bug(消息/好友/聊天全通证明数据层+RLS 都对)。
  - ✅ **来信**(2026-06-03,MacEnvelopeColumn feed 列表 + MacEnvelopeDetail markdown 正文;跨平台 EnvelopeDataSource 查 envelope_runs;第一版无 realtime/thinking-trace 实时/写信 compose)。**至此 Mac 五个 tab(消息/好友/机组/来信/我)都有真实内容**。
  - ✅ **UI 对齐 iOS**(2026-06-03):品牌视觉基础设施跨平台(Color(hex:)/ColorHash/BrandAvatar)→ 会话/好友/机组/来信列表 emoji 头像、聊天淡绿用户气泡+白 bot 气泡+米白背景+圆角18、tab 图标对齐(⌘机组)、app 图标补 macOS 全套尺寸、sidebar 收窄、间距调大。消息/好友真机截图验通;来信/对齐细节待 computer-use 重连或用户真机看。
  - **待接(follow-up)**:机组完整(创建 crew/群聊/详情，现仅 viewer)、Realtime 推送(现全轮询)、头像图片(ServerImage iOS-only,现用 emoji 占位)、附件/图片/语音、来信 thinking-trace/写信。详见 tech-debt。
- 🟡 **T1.2 客户端消费** —— 后端权限矩阵有了，客户端没用

---

## 3. 独立功能（不在 roadmap）

### Bot 邀请链接（取代旧 slug 分享 — decisions.md D1）
- **状态**：🟡 后端完成并验证；iOS UX 返工进行中（feat/invite-model 分支，未合 main）
- **决策**：旧 slug-直查模型作废（陌生人被 RLS 堵死、ship 即坏）。改为 **invite-token 模型**：好友可签发、关联签发者、7 天有效、可撤销、redeem 记 invited_by。见 decisions.md D1。
- **已落地并验证（2026-06-01）**：
  - ✅ DB（#191，迁移已 push 到 live + schema regen + typecheck 绿）：`bot_invite_links` 表 + `user_bot_contacts.invited_by` + `bot_invite_link_{create,list,revoke,resolve,redeem}` RPC（RLS 不放宽，definer 代写授权行）+ `get_bot_friends` 带 invited_by。
  - ✅ Edge（#192/#193，typecheck 绿）：`POST/GET /v1/bots/:id/invite-links`、`GET/POST/DELETE /v1/bot-invites/:token`、friends 返回 invited_by。
  - ✅ iOS 基础（BotInviteAPI.swift）：API client 方法 + 类型。
- **剩余（#194，未做）**：iOS UX 返工 —— scan/universal-link → resolve → redeem 的 AddBotSheet 改造（去掉手动 slug 加，改 token codec）、ManageBotSheet 分享区改成「签发/管理邀请链接」。**这是 UX 重设计，需 simulator 视觉验证（非仅编译）**。#121-127 旧 slug task 待 #194 完成后一起翻。
- **关联**：D2 群加入码同构（#195，未做）。

### Dashboard 栈接线（#206 — 零 VPS 方案，feat/dashboard-wiring 分支，未合 main）
- **状态**：🟡 代码/接线全部就绪并验证（edge typecheck + 469 vitest 绿、admin `bun run build` 绿、grafana JSON 全 jq 合法）；**待用户开第三方账号 + 填 secret**，真实端到端未验。
- **已落地（2026-06-03，所有外部 SDK 接入前都查了官方文档/核了已装包类型）**：
  - **Sentry**（block 3）：`withSentry` wrap 早就有；补了三处吞错点的 `captureException` —— `app.onError`（Hono 把 throw 转成 500 response，原来到不了 withSentry）、queue:audit 非瞬时失败、cron `safe()`。DSN 未设=no-op。
  - **PostHog**（block 1）：新 `lib/track.ts` `trackEvent(c,...)`（fire-and-forget，无 PII），接在 `message_sent / group_created / group_joined / voice_call_started(1v1+群) / voice_call_ended(群) / topup_succeeded(iap+lemon webhook)`。无 server seam 的事件（`signed_up` 触发器、`bot_created` 客户端直写、1v1 通话结束在 MeterDO、群注资/认缴在被改造的文件）记 tech-debt 留 iOS SDK/后续补，没造假。
  - **Langfuse**（block 2）：`traceGeneration` 接在 `persistAuditMessage`（每回合 model/tokens/cost/latency 都齐的唯一点），dedup 之后只发一次；隐私：只发结构指标不发 prompt/completion。装的是 v3 legacy SDK（Workers 友好）。
  - **Refine 后台**（block 4，`apps/admin`）：Refine v5 + react-router v7 SPA，custom dataProvider 走 edge（不直连 PG）、Supabase Auth、CF Pages 部署。**但 edge 没有 `/v1/admin/*` 面**——11 个端点缺口已记 tech-debt，dataProvider 逐条 `exists:false` 标注，不是无声 stub。
  - **Grafana**（block 5，`infra/grafana`）：5 张 provisioning dashboard（营收/钱包/群池/成本/转化），datasource 走只读 `metabase_ro`。SQL 全部基于真实列（agent 发现 spec 的 `pnc_ledger` 不存在，实表是 `billing_ledger`）。
- **待用户**：开 PostHog(EU)/Langfuse/Sentry/Grafana Cloud/CF Pages 账号、`wrangler secret put` 填 secret、建 `metabase_ro` 角色、连 Grafana→Supabase。详见 session 末清单。

---

## 4. Billing v2（#180-190）—— 代码完成 ≠ 可用

主路径（schema / settleUsage / LLM / voice / web tools / sandbox 计费 / share-index / cron）已落地并验证。以下 task 标 completed，但**真实可用还差人工/runtime**，缺口在 tech-debt：

| Task# | 缺口 | 谁能做 |
|---|---|---|
| #185 IAP | JWS 验签已实现（427 行手写 DER/ASN.1，14 单测绿）；**缺真 Apple sandbox 端到端** | 人工 |
| #186 LS refund | 入账 + 反向冲销代码全；**缺 LS test mode 联调** | 人工 |
| #188 Board admin | grant/claw-back RPC 有；**缺 pack 列表/作废/refund 列表/wallet 详情 UI** | 需设计 |
| #189 iOS 钱包 | 余额+账本(含 refund)显示全；**缺 IAP 购买流 / 群池贡献 UI** | 需设计 |
| #190 v1 退役 | 数据已迁；**v1 表当冷备未删，`billing_debit` 等 v1 RPC 仍被调，无 drop 迁移** | 观察期后 |

> 另：sandbox `vendorCostUsd` 仍硬写 0（无 Cloudflare 价目），用户可免费无限跑 execute_code。见 tech-debt 🟡。

---

## 4b. Billing **引擎大转向 → Polar(钱包 SoR)+ WalletDO(边缘门禁缓存)**（2026-06-02，#207-209）

billing-v2 的自研结算引擎(settleUsage/packs/本地账本)**改为外包**:Polar = MoR + 信用钱包事实源(`pnc` meter),RevenueCat = iOS IAP 入账。CF 上 WalletDO(per-subject DO,强一致)做边缘门禁缓存 + 用量 outbox,push-sync + 稀疏对账。设计见 `specs/2026-06-01-billing-engine-design.md`、`specs/2026-06-02-billing-p2-architecture-fork.md`。

| 块 | 状态 | 验证 | 说明 |
|---|---|---|---|
| P0/P1 Polar 引擎 + 单位 + 封装 | ✅ | 代码 + **真 sandbox spike** | pnc.ts / polar-client / billing-polar;收/扣/退/余额/幂等真打通 |
| P2-A WalletDO | ✅ | 代码+单测 | balance + pending outbox + alarm flush + 稀疏对账 |
| P2-B wallet-client | ✅ | 代码+单测 | gate/debit/credit/applyAbsolute RPC |
| P2-C LLM router 门禁+扣费 | ✅ | 代码+单测 | 替 settleTurnV2;gate 接进 `lib/billing.ts requireBalance`(messages/envelope/语音共用) |
| P2-D 语音(1v1+群) | ✅ | 代码+单测 | realtime-meter + room-voice 走 WalletDO |
| P2-F sandbox | ✅ | 代码+单测 | gate+按时长扣(占位单价) |
| P2-G 充退/state_changed push | ✅ | 代码+单测 | Polar/RC webhook → wallet.credit / applyAbsolute(官方类型核实) |
| **集成** | ✅ | **typecheck 0 + 509 测试全过** | 四并行分支已合 chore/billing-dashboard-specs |
| **P2 群成本分摊 重挂(#208)** | ✅ | 代码+单测 | 用户拍板用 v2 共享池法。share-index.ts + 原子 RPC 迁移 + group-wallet.ts(contribute/refund/dissolve)+ router/群语音/sandbox 扣费后衰减 + 端点 /topup·/leave·/dissolve。计划 `plans/2026-06-02-group-wallet-polar-rehome.md` |
| me.ts /wallet/v2 余额改读 WalletDO | ✅ | 代码 | 替 packs 求和(会显示过期值);明细读 pnc_ledger |
| **群钱包 认缴(pledge)模型(#213)** | ✅ | 代码+单测(534) | 实缴池+认缴统一:group_pledges 表 + 部分取出 + settleGroupSpend(消费按份额拆池衰减+认缴个人直扣)+ 门禁聚合 + 端点 /pledge·/withdraw。spec/plan `2026-06-02-group-billing-pledge-model*` |
| 群分摊 尾巴(#210) | ✅ | 代码+单测(474) | 链式退款冲群(clawbackFromGroups)/ 群池漂移报警 / `/leave` 一步退群 / 群 bot 异步回复前置 gate —— 全做完 |
| billing-v2 死代码退役(#209) | ✅ | typecheck 0 + 472 测试 | 删 16 文件(billing-v2.ts/group/pack/lemon/iap/refund/expiry + pack cron)+ 去 /lemonsqueezy·/iap 路由 + room-voice OwnerRef→WalletOwner + 清孤儿 env/cron。旧 packs/ledger 表留冷备 |
| throttle 降级 / low 提醒 / sandbox 真实单价 | ❌ | — | 已记 tech-debt 🟡(throttle 经 OpenRouter 官方文档核实不适用 passthrough) |

**待用户**:Polar 加 `customer.state_changed` webhook 事件;开 Grafana/PostHog/Langfuse/Sentry 账号(dashboard #206);真实 product_id 填 billing-packs.ts;轮换 Polar token;**群分摊模型拍板(#208)**。

---

## 5. 账本一致性待办（本次对账发现的漂移）

- [ ] #121-127 **不翻 completed**（代码已落但功能被 RLS bug 堵死、#128 未验证；按"completed=已验证"规则保持 pending，真实中间态由本文件 §3 记录）；RLS 修通 + #128 跑过后再一起翻
- [ ] tech-debt **T4.5 条目改为"服务端 P0 已落、客户端未接"**（现写成"只有文档"，已过时）
- [ ] tech-debt 新增 **bot 分享 RLS 闭环 bug**（游离缺口，三个账本都没记）
- [ ] roadmap 标注 T3.2 / T5.3 未做、T4.5 半截
