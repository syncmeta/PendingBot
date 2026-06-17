# 技术债 / 项目根基风险登记册

这个文件是 PendingBot 的**结构性问题登记册**，由各个 Claude Code / Codex session 在日常开发中**顺手记录**，不是一次性审计的产物。

记什么（按严重度从高到低）：

- 🔴 **根基级** — 影响整个项目、让根基不稳的问题。错误的数据模型、会随规模放大的设计错误、跨模块的隐性耦合、安全/数据一致性隐患、迁移账本漂移之类。
- 🟡 **拆东墙补西墙** — 为了让 A 跑通而硬塞进去、把代价转嫁到 B 的修复；绕过类型/校验/约束的 workaround；复制粘贴而非抽象；"先这样以后再说"的临时实现。
- 🟢 **不规范** — 偏离本仓库既定约定（见 `CLAUDE.md`）的写法、命名、结构；不致命但会慢慢腐蚀一致性。

**不记**：linter/typecheck 已经能抓的纯风格问题、个人口味、与项目健康无关的琐碎 TODO。

---

### 🟡 系统级 model slug 全是硬编码常量 — 一批占位/疑失效 + 该统一收进 board 配置
- **发现**: 2026-06-17 · `feat/preset-content-realign`（排查「预设机器人配置对不上」延伸出的全库引用审计）
- **背景/用户定的纪律**: **model slug 绝不硬编码**，不适合硬编码的配置统一收进 board CMS 管理（同 `feedback_no_hardcoded_prompts` 把 prompt 赶进 loader 通道的思路）。现状是各功能的「系统模型角色」都写死成代码常量，散落多处、无统一配置入口；其中一批还是早期手编、没核验过的占位 slug。
- **位置（系统 model 角色硬编码全清单，edge 为主）**:
  - 会话标题 → `apps/edge/src/lib/title-runner.ts:27` `TITLE_MODEL_SLUG = 'google/gemma-4-31b-it'`（✅ 2026-06-17 核验存在于 OpenRouter 目录，有效）
  - 群消息路由 fallback → `apps/edge/src/llm/group-router.ts:52` `FALLBACK_MODEL_SLUG = 'google/gemma-4-31b-it'`（同上有效）
  - 群机器人介绍 fallback → `apps/edge/src/lib/group-bot-intro.ts:27` `MODEL_FALLBACK = 'google/gemma-4-31b-it'`（同上有效）
  - 识图/视觉 → `apps/edge/src/llm/vision.ts:53` `DEFAULT_VISION_MODEL = 'moonshotai/kimi-latest'`
  - 写信探索/协作 → `apps/edge/src/lib/envelope-runner.ts:78-79` `DEFAULT_EXPLORER_MODEL`/`DEFAULT_COLLABORATOR_MODEL = '~google/gemini-flash-latest'`（iOS 镜像 `apps/pendingbot/Sources/Features/Envelope/EnvelopeAPI.swift:121-122`）
  - 语音默认模型 → `gpt-realtime-2` 散在 `durable-objects/realtime-meter.ts:47`/`durable-objects/room-voice.ts:42`/`routes/group-voice.ts:74`/`routes/realtime.ts:61`/`llm/providers.ts:94`；mini 档 `llm/providers.ts:101` `gpt-realtime-mini-2025-12-15`（iOS 镜像 `BotManagement.swift:1285,1506-1507`）
  - delegate 工具默认/示例 slug → `apps/edge/src/lib/bot-reply/tools/delegate.ts:26-27`（`claude-opus-4.7` / `~google/gemini-2.5-pro`）+ 描述 `tool-defs.ts:343`
  - 附件视觉总结（迁移 seed）→ `supabase/migrations/0064_attachments_vision_summary.sql:65-68`（`anthropic/claude-opus-4.7` + `claude-sonnet-4.6`）
  - 预设 bot / 每用户 self bot 的 `bots.model_id`（产品向另有 spec 覆盖，见关联）
  - 标题任务曾 pin（`0036_pin_title_to_gemma.sql`）→ 配置已迁 KV、表已 drop，仅留迁移痕迹
- **明确排除（非「选模型」硬编码，别误伤）**: provider/apiStyle 关键字 `'gemini'`（`providers.ts:26/37`、`bot-reply/index.ts:866`、`delegate.ts:100` 的路由判断）；preset resolver 的 series/author 匹配串（`model-presets.ts:17/178`）；iOS 厂商图标/显示名映射（`ModelPicker.swift`、`SubConversationView.swift:117/119`）。
- **问题**:
  - ~~`gemma-4-31b-it` 疑失效~~ **已核验（2026-06-17 curl OpenRouter 337 模型）：全部硬编码 slug（`google/gemma-4-31b-it` / `moonshotai/kimi-latest` / `~google/gemini-flash-latest` / `anthropic/claude-opus-4.7` / `claude-sonnet-4.6`）均存在、有效**——基础设施这批常量没有失效 bug，问题纯粹是「配置卫生」（写死、散落、运营不可配），非功能故障。语音 `gpt-realtime-2` 走 OpenAI 原生 realtime 端点、不经 OpenRouter，目录无匹配属正常。
  - 没有统一的「系统模型角色」配置入口——换代/纠错都要改代码 + 发版；`task_routing`/模型目录配置 #263 已迁 KV，这批 fallback/固定模型是漏网的代码常量。
- **影响**: 失效 slug 直接让对应功能报错；违反配置化纪律，运营/产品改不了。（bot 引用侧脏数据经审计已穷尽：裸 `bot_slug` 仅 `preset_conversation_templates`〔ipsum 悬空〕+ `preset_group_templates`〔dolor/adipiscing 悬空〕两处，其余 19 张表 `bot_id` 均有 FK 兜底——产品向 spec 覆盖。）
- **建议（收进 board 的形态）**:
  1. 起一组「系统模型角色」配置 key（title / group-router-fallback / group-bot-intro / vision / envelope-explorer / envelope-collaborator / voice-default / voice-mini / delegate-default / attachment-vision），走已有的 KV config 通道（#263 的 config→KV loader），board 出一个管理页编辑，跟 `model_presets` 页同处。
  2. edge 各处常量改成「读 config，读不到才回落代码默认」；代码默认换成当前**有效**的规范 slug（先核验 OpenRouter 目录）。
  3. iOS 侧镜像的默认（envelope/voice）改为从 `/v1/config` 之类下发，别两端各写一份。
- **状态**: 🟡 **基座 + 3/8 角色已落**。基座 `6b0ab921`（`lib/model-roles.ts` 注册表 + `getModelRole(env, role)`〔override ?? code default，isolate 60s 缓存，KV 失败回落〕+ `routes/board-model-roles.ts` GET/PUT + 挂 `/v1/board/model-roles`）。`4ecf801d`：title / group-router / group-bot-intro 三处常量删掉、改 `await getModelRole(env, …)`（edge typecheck 0，零回归，board 写覆盖即生效）。**待**：① 剩 5 角色 swap —— vision / envelope-explorer / envelope-collaborator / voice-default / voice-mini，它们的默认值被**纯同步函数**（`pickVisionModel`、`resolveEnvelopeSettings`）或 **DO 上下文**消费，要改函数契约（同步→异步，或把 resolved slug 从有 `env` 的调用方穿进去），比前 3 个 invasive、regression-sensitive，逐处验。② admin 配置页（镜像 `feature-flags.tsx` + resource-map 一条）。③ iOS envelope/voice 默认改 `/v1/config` 下发，别两端各写。
- **关联**: 预设内容漂移（产品向）spec `docs/superpowers/specs/2026-06-17-preset-content-realignment-design.md` —— 同根（占位 model slug）；那份管「预设 bot/引导/群」的内容，本条管「基础设施硬编码 model 角色」的工程治理。

### 🟡 codex `item/permissions/requestApproval` 回错响应形状（套了 `{decision}`，真 schema 要 `{permissions}`）
- **发现**: 2026-06-17 · `fix/codex-mcp-tool-approval`（修 post_to_crew 被拒、对 codex 0.137.0 真 schema 时顺手撞见）
- **位置**: `apps/pendingcrew/Sources/Mac/LocalRunner/CodexAppServer/CodexAppServerBackend.swift` `handleServerRequest` 的 `.approval` 分支。
- **问题**: 三个 `*/requestApproval` 共用一句 `respond(serverId:id, result:["decision": decision])`。对 `item/commandExecution` / `item/fileChange` 正确（响应 schema = `{decision: <enum>}`，accept/decline 是合法枚举值）；但对 **`item/permissions/requestApproval`** 错 —— 真 schema `PermissionsRequestApprovalResponse` **required `{permissions: GrantedPermissionProfile, scope?, strictAutoReview?}`，根本没有 `decision` 字段**（`codex app-server generate-json-schema` 0.137.0 核对）。回 `{decision:...}` → codex 解不出 → 该权限请求会失败/被当拒。
- **影响**: codex worker session 若申请超出 `workspace-write` sandbox 的额外权限（网络访问 / cwd 外写），这条审批会坏 —— agent 拿不到权限或 turn 出错。captain 报到只 `post_to_crew`（不碰额外权限）所以没撞上；本次 `post_to_crew` 被拒是 elicitation 那条（`mcp_tool_call` approval，已修 `158021d2`），与此**独立**。
- **建议**: `.approval` 按 method 分形状回包 —— permissions 分支：allow→授予 requested permissions（`{permissions:<granted>}`）、deny→空 profile（`{permissions:{}}` = 批准空 = 实际不给）；别套 `{decision}`。改前先用真 codex 跑一轮触发 permissions 审批，确认 codex 对 malformed 响应的实际行为 + 正确 grant 形状（本次没做，避免扩散当前 fix 的 scope）。
- **状态**: 待办（独立于 elicitation 修复；真实触发前低优先）。

### 🟡 PendingCrew 登录搬 PendingBot + 同发布者确认卡 — P1+P2 代码落地，待真签名 GUI + Apple/Google 后台配置
- **发现**: 2026-06-17 · `feat/pendingcrew-login-port`（P1：确认卡 + 现有扫码视觉对齐；spec/plan `2026-06-17-pendingcrew-login-port*`）
- **背景**: 登录入口改为「检测本机 PendingBot 已登录（共享 keychain `pfa_`）→ 确认卡一键 mint `pendingcrew_control` grant / 换号→登录页」。**沿用 scoped grant 安全模型**（PendingCrew 不持全权 Supabase session，守 2026-06-08 SSO spec）。PendingBot 家族凭据 payload 加 `displayName`/`avatarSeed` 且放开到 iOS 也写；edge `/v1/me/family-credential` 回 `displayName`。P1（T1-T7）：PendingCrew 215 单测绿 + Mac/iPad build 绿 + PendingBot 双 build 绿 + edge typecheck 0。
- **真签名尾巴（必须 Xcode GUI 正常签名验，headless ad-hoc 必 `-34018`，别在 build 绿就判 done —— 按 `feedback_no_shortcut_debt` verify 要覆盖最终使用路径）**:
  1. **共享 keychain 跨 app 真读**：PendingBot（已登录）写 `pfa_`+profile 进共享组 `M42BKJN82S.com.pendingname.shared` → PendingCrew `CrewLoginIdentity.current()` 真读到、确认卡显示正确头像+账号。需两个 Apple Development 正常签名 app。
  2. **确认卡端到端**：Mac 侧栏「登录」→ sheet 出确认卡 →「继续」→ `tryFamilySSO` mint grant → 进主界面；iPad 同链路（首屏 gate）。
  3. **iPad 检测依赖 PendingBot-iOS 写凭据**：T2 已放开 writer 到 iOS，但「同一台 iPad 上 PendingBot 登录→写 `pfa_`→PendingCrew 读」未真机验。
  4. **Apple Sign In capability 未注册**：PendingCrew App ID（`com.pendingname.pendingcrew`）在 Apple Developer portal 没开 Sign in with Apple → headless 加 `com.apple.developer.applesignin` entitlement 必挂签名（T9 已回退、保留 build 绿）。修：Xcode GUI → Signing & Capabilities → 「+ Sign in with Apple」（automatic signing 自动注册到 App ID）→ 再把 entitlement 加回 `PendingCrew.entitlements`。在此之前 Apple 直接登录运行时不可用（代码已就位、编译通过）。
  5. **Google OAuth client id 未建**：需 Cloud Console 给 `com.pendingname.pendingcrew` 建 iOS client id、填进 `Info.plist` `GIDClientID`（现为 `YOUR_` 占位 → `CrewGoogleSignIn.run()` 抛 `.missingClientID`）、并加进 Supabase Auth → Google → Authorized Client IDs。
- **P2 已落代码（直接登录栈，plan T9-T15，218 单测 + Mac/iPad build 绿，T14 过独立 reviewer APPROVED）**：Apple/Google/邮箱直接登录 = vendored `Crew{Email,Apple,Google}SignIn`/`CrewWelcomeViewModel`/`CrewTurnstileWebView` + 内存态 `CrewSupabaseStack`（session 不落 keychain）+ `CrewLoginExchange`（`session→pfa_→mint→signOut`，失败也清，TDD）。`CrewWelcomeView`(iPad)/`CrewMacWelcomeView`(Mac) 三胶囊 + 邮箱，旧 `LoginView` 删（扫码并入 `CrewQRLoginView`）。引 supabase-swift + GoogleSignIn 两重依赖进 PendingCrew（仅为一次性 session，D5 Port-Full）。**Apple/Google 后台配好前，邮箱 OTP + 扫码 + 确认卡已是可用路径；P2 前不拆扫码**（现作第三胶囊保留）。
- **附带修复（已闭合）**: `PendingCrewTests` 7 个 Codex/Session 测试文件的 stale `@testable import PendingCrew`（host-less bundle 编不过）→ 改纯 `import XCTest`，commit `74ce8047`。意味 #345-360「completed」时该单测 bundle 从未 `xcodebuild test` 真跑绿（completed=已验证 纪律漏，已补绿 215 测）。
- **状态**: 🟡 P1+P2 代码全落地（18 commit，build/单测全绿）；待 ① Apple Sign In capability（Xcode GUI）② Google client id（Cloud Console）③ 一次签名 GUI E2E（确认卡/三直接登录/扫码 + session 不落盘核查）。未合 main（用户发起）。
### 🟢 captain prompt 提到的 `start_session` 工具未实装
- **发现**: 2026-06-17 · `feat/crew-naming`
- **位置**: `apps/pendingcrew/Resources/Prompts/crew-captain.zh.md`（写 `start_session(brief, runner?)`）vs `apps/pendingcrew/Sources/Mcp/McpServer.swift`（只有 post_to_crew / read_whiteboard / ask / answer_decision / rename_crew）。
- **问题**: prompt 教机长用 `start_session` 把明确编码任务排队，但本地 MCP server **没这个工具**——机长调不到。起 worker session 的真实通路（手动 `CrewSessionWindowView` / relay `task_request`）不经此工具。prompt 与实装漂移（spec 概念先行、工具没补）。
- **影响**: 机长可能调一个不存在的工具 → 收到「未知工具」。本次 crew-naming 只在同文件加命名条、未碰这条，单独记。
- **建议**: 要么在 McpServer 实装 `start_session`（captain-only，写 task_request 进控制/白板通道、app 起 session），要么把 prompt 改成现有真实通路的说法。
- **状态**: 待办（与 crew-naming 无耦合）。

### 🟡 PendingCrewTests 的 `@testable import PendingCrew` 无构建序边 → 干净 `xcodebuild test` 编不过
- **发现**: 2026-06-17 · `feat/crew-naming`（跑新单测时撞上）
- **位置**: `apps/pendingcrew/Tests/PendingCrewTests/`（`Codex*Tests` / `SessionConfigTests` 用 `@testable import PendingCrew`）+ `apps/pendingcrew/project.yml`（PendingCrewTests `dependencies:` 只有 SwiftTerm；pbxproj 里 0 个 PBXTargetDependency 指向 app target）。
- **问题**: 测试 bundle 是 standalone（`TEST_HOST=""`），多数自包含源码**直接编进 bundle**；但 6 个测试文件 `@testable import PendingCrew` 取只在 app module 里的类型（Codex* / SessionConfig）。test target **没有**对 app target 的依赖边 → `xcodebuild test -scheme PendingCrew` 从干净 DerivedData 跑报 `unable to resolve module dependency: 'PendingCrew'`，只有 DerivedData 里已存在 app 的 testable swiftmodule（IDE 跑过 / 先 build）时才偶然过。
- **影响**: 命令行/CI 无法可靠跑这套 XCTest（本仓 Swift 的 pre-merge 约定本就是 `xcodebuild build` 不是 test，平时不暴露）。新写单测（含 crew-naming 三个）连带跑不了 —— 本次靠 standalone `swiftc` 跑通新逻辑（LocalCrewControlStore + 名字归一化，12 检查全过）+ app build 编译兜住。
- **建议**: 二选一让 CLI 可跑：(a) 给 PendingCrewTests 加 `dependencies: - target: PendingCrew`（注意直编进 bundle 的自包含源码与 module 内同名类型可能撞符号，需确认 @testable 测试文件与直编源码不交叉引用）；(b) 把 Codex*/SessionConfig 的**源文件**也加进 test target 显式清单、去掉那几处 `@testable import`（与现有自包含约定一致）。
- **状态**: ✅ 已闭合 by `feat/pendingcrew-login-port`（commit `74ce8047` 把那 7 个 `Codex*`/`SessionConfig` 测试文件的 `@testable import PendingCrew` 改成纯 `import XCTest`，靠直编进 bundle 的源码供符号 = 该条建议的 (b) 方案）。两分支合并后 `xcodebuild -scheme PendingCrew test` 从干净跑 **238 测全绿**，CLI 可靠可跑。

### 🟡 新建机器人模型预设 — 数据源近似 + 端到端待部署后真验
- **发现**: 2026-06-15 · `feat/create-bot-presets`（新建机器人一页式 + 模型预设）
- **背景**: bot 模型池从手挑改成 board 管规则、OpenRouter 目录动态解析的"预设"。spec `2026-06-15-create-bot-presets-design.md`、plan `2026-06-15-create-bot-presets.md`。edge typecheck 0 + 599 vitest 全绿 + iOS build 绿，但 **E2E 全未真验**（见下）。
- **尾巴**:
  1. **端点冒烟 + 模拟器 E2E 未做**：`GET /v1/model-presets` 的 curl 冒烟、以及 iOS 模拟器走一遍（建私有/公有/自定义/换名字/点预设看模型/进自定义页是否秒开/无外部采用者公有 bot 可删）都**需要 worker 部署后才能验** —— 代码已 committed 但未 deploy，DB 迁移已 db push prod（表存在但服务端代码未上线）。合并 + 部署后必须补这轮真验，别在单测/build 绿就判 done（按 `feedback_no_shortcut_debt`：verify 要覆盖最终使用路径）。**这也是 plan Task 4.1 Step4 / 4.2 的"中国旗舰真实 slug + 原生路由是否生效"实测点**。`fix/model-presets`(2026-06-16) 的旗舰 `latest_in_series` 改造 + 列表性能根治也并入此轮真验：部署后 curl `GET /v1/model-presets` 确认 top-flagship/cn-flagship 返回真旗舰（opus-4.8 / gpt-5.5 / v4-pro / qwen3.7-max / kimi-k2.6 / glm-5.1 / minimax-m3），并看 CF 日志冷/热耗时确认冷启动不再卡（catalog 由 N× build 收敛成 1× + `*/30` cron 预热）。**注意部署顺序：先 deploy worker（认 `latest_in_series` resolver）再 db push（改两预设 kind），反了旧 worker 不识新 kind 会让这俩预设解析返回空**。
  2. **最热门 = LMArena 评分代理，非真实使用量榜**：OR 官方用量榜(`datasets/get-rankings-daily`)要 `OPENROUTER_API_KEY`，edge 没有(目录公开/推理走 AI Gateway 统一计费)，用户拍板 v1 不加 secret。现用 LMArena `text` 子集 rating 排序——语义是"评测质量榜"。将来要"真热门"再加 OR key + 换 `most_popular` resolver 数据源。
  3. ~~**旗舰 most_expensive 会选到 pro/ultra 档**~~ **（已闭合，`fix/model-presets` 2026-06-16）**：top-flagship/cn-flagship 改 `latest_in_series` —— 每条产品线锚 series 前缀，系列内按 `-./` 分段排除小号/特化/滚动别名后取发布日最新（实测选出 opus-4.8 / gpt-5.5 / deepseek-v4-pro / qwen3.7-max / kimi-k2.6 / glm-5.1 / minimax-m3，全是真旗舰；most_expensive 之前选的是 o1-pro 2025-03 老款、deepseek-r1-distill 蒸馏小模型）。**但引入新命名-漂移尾巴（🟢，留意）**：① series 前缀（openai 用 `gpt-5`）锁了大版本，`gpt-6` 出来要改 seed（新迁移 UPDATE `params.lines`）；② `NON_FLAGSHIP_SEGMENTS` 排除集（fast/flash/mini/nano/lite/air/turbo/distill/code/preview/exp/plus）按当前 7 家命名拍的，新厂商用别的小号命名会漏（段精确匹配已避免 `mini`→`minimax` 误杀，但关键词黑名单本质脆弱）。新模型若选错旗舰，先查 `model-presets.ts` 的 `isNonFlagshipVariant` + 该迁移的 seed `lines`。真正想根治可改 `manual` 由 board 维护具体 slug（旗舰是季度级慢变量）——本次按用户"要 opus/gpt/kimi latest 这种"选了自动方案。
  4. **速度快候选集 cap + min_rating 1200 是拍的**：`resolveFastest` 候选筛选阈值（质量下限、候选规模）按当时真实数据拍的，未长期观察；模型生态变了可能需调。cap 2026-06-16(`fix/model-presets`)由 40 降到 15（每候选要单发 OpenRouter endpoints 请求拿吞吐，Workers ~6 并发连接上限下 40 会排长队拖慢冷解析）。

### 🟡 去轮询 Phase 5 — 本地跨进程靠目录监听、远端 hub 真推 + iOS 实时通道未验
- **发现**: 2026-06-15 · `feat/crew-comms-rework`（Phase 5：群聊去 3s/2s 轮询，改事件驱动）
- **背景**: `PendingCrewBackend` 加 `whiteboardChanges(crewId:) -> AsyncStream<Void>`，`CrewChatView`/`CrewSessionWindowView` 删 `pollLoop`/`rosterPollLoop`(3s) + `badgeTimer`(2s)，改 `for await` 订阅。Local 走 `LocalWhiteboardStore.changes`(进程内 append) + `directoryChanged`(DispatchSource 监 whiteboards 目录，补 helper 子进程 `post_to_crew` 跨进程写)；Edge 走 `CrewRealtimeClient` hub `.changed` 帧。
- **未验证尾巴**:
  1. **远端 hub 真推 → UI 刷新（活体）未验**：Edge `whiteboardChanges` 接 `CrewRealtimeClient`，但只到「编译 + 单测(codec/请求构造) + 双 build 绿」。真账号下 hub 发 `crew_announcements`/`crew_sessions`/`messages` 的 `change` 帧 → 中栏/右栏真刷新、断线重连后续推 —— 全未真机 E2E（与 Phase 4b 同源：`CrewRealtimeClient` 活体行为本就留手动验）。
  2. ~~**iOS 无实时通道**~~ **（已闭合）**：原本 `CrewRealtimeClient` 在 `Mac/` 子树 + `#if os(macOS)`，iOS 上 `EdgeBackend.whiteboardChanges` 返回空流。已在本分支 commit `38018eaa` 把 `CrewRealtimeClient` 移出 `Mac/`、去掉 `os(macOS)` gate（它只 `import Foundation`），`EdgeBackend.whiteboardChanges` 合并成单一跨平台实现 —— **iOS/iPad 现在也连 hub**（PendingCrew 全程 device-grant，iOS 登录态有 `imageAuth` 凭据）。剩下的只是与下面第 1 条同源的「活体 hub 真推 → 刷新」未做真机 E2E。
  3. **目录监听粒度到目录、不到 crewId**：`directoryChanged` 是 whiteboards 目录级 DispatchSource 事件（atomic write = temp+rename，per-file fd 会失效，只能监目录）。任一 crew 的 JSON 写都会让**所有**订阅者重拉自己那一份 —— 单用户低频可接受；多 crew 高频时会有放大（每个开着的 crew 视图都 refresh 一次）。
  4. **badge 的「纯审批解决」边角**：未读角标 = pending 审批(`LocalApprovalStore`) + 白板新消息。`badgeTick` 现由 `whiteboardChanges` 事件 bump。新审批请求 / agent 进展都会写白板 → 触发事件，覆盖主场景；但**只改 `LocalApprovalStore`、不碰白板**的审批状态变化（BYOK 下 MCP server 跨进程解决一个 pending）不会即时 bump badge，要等下个白板事件才重算。`LocalApprovalStore` 无 publisher、又是跨进程文件写，事件化它需要再给它接一份目录监听（同 `directoryChanged` 套路）—— 本次未做，留待审批解决的实时性成问题时补。

### 🟡 PendingCrew codex app-server backend v1 — 核心闭环已落，真机链路 + 协议字段名未验
- **发现**: 2026-06-14 · `feat/codex-app-server`（用户："让 codex 像在这个目录下直接跑一样，做成结构化 codex 客户端对标 codex desktop"）
- **背景**: codex 从占位交互式终端搬到 `codex app-server`（本地子进程 + stdio 换行分隔 JSON-RPC 2.0）。spec `2026-06-14-codex-app-server-backend-design.md`、plan `2026-06-14-pendingcrew-codex-app-server-backend.md`、协议 bible `2026-06-05-codex-app-server-reference.md`。Phase 0–5 全落（SessionBackend 抽象 / RPC 帧+dispatcher / ThreadItem+transcript / 协议 builders / SessionConfig argv / env 守卫 / connection / backend / runner 接线 / 结构化视图）。**145 单测 0 失败 + macOS/iOS 双 build 绿**，但**所有验证都是单测 + 编译**——本环境没有真 codex 登录态，没 spawn 过真 app-server。
- **真机尾巴（必须人工验，别在单测绿就判 done）**:
  1. **认证模型未定**：内部 spec 实测(0.137.0)说 app-server 自动读 `~/.codex/auth.json`；当前 OpenAI 官方文档说凭据"客户端驱动"(`account/login/start`)。两者矛盾，**装的是哪个版本/哪种行为只能在用户机器上探**（`initialize`→`account/read` 看返不返 chatgpt 账号）。现 backend 没做登录流，假设自动继承；若是客户端驱动版会连不上。
  2. **ThreadItem 字段名版本锁**：`CodexThreadItem` 解码按 reference spec 的文档形态写，**没和真 `codex app-server generate-json-schema` 抓包对齐**。字段名对不上时会大量落 `.unknown`（不崩，但渲染退化）。真机要跑 `generate-json-schema` 核字段名。
     - **⚠️ 已部分核实并修（`fix/codex-captain-crew-tools`，2026-06-15，针对 0.137.0 真 schema）**：跑 `codex app-server generate-json-schema` 后发现**两个 outbound 字段是凭印象编的、被 codex 静默丢弃** —— 这正是"机长报告没有 read_whiteboard/post_to_crew 工具"的根因：(a) `thread/start` **无** `mcpServers` 字段，MCP 必须走 `config.mcp_servers.<名>={command,args,env}`（已改 `CodexProtocol.threadStartParams`）；(b) `turn/start` **无** `additionalContext` 字段，白板"自动注入"对 codex 全程是假的，已改成把白板作首条 `text` input 前置。`initialize`/`turn/start`/`turn/interrupt`/审批服务器请求(`item/*/requestApproval`)等其余 outbound 形状已对 schema 核过=对。**仍未真机验**：`CodexThreadItem` **inbound** 解码字段名（schema 已 dump 但未逐一比对）、`initialize` capabilities 具体键、认证模型、turn/审批/计费 roundtrip。**教训**：`CodexProtocolTests` 之前**断言了这两个虚构字段**（测了个虚构却"通过"）—— 凭印象写协议 + 单测照抄印象 = 假绿；已改成按真 schema 断言当回归护栏。下次接外部协议先 dump schema 再写 builder + 测试。
  3. 一轮 turn 端到端渲染、审批 roundtrip、`developerInstructions` append-vs-replace 语义、计费 tick（`usedPercent`↑ + API dashboard 无账单）——全未真机验。
- **行为分歧（有意 fail-safe）**: codex 审批 provider（`CrewSessionRunner.makeApprovalProvider`）long-poll 设了 ~30min 上限→超时判 `deny`，而 claude 的 `McpPermissionHook` 生产是**无限等人**。这是防 codex turn 永久挂死的安全侧选择，但和 claude 不一致；若要 codex 也无限等需改掉这个上限。
- **未做（v1 明确 defer，按需再加）**: 逐字 delta/token 流式（已 opt-out，只渲染 `item/completed`）、`turn/steer` 回合中插入、`resume`/`fork`、额度展示 UI、peer rollout JSONL 跨读、codex hooks 系统。
- **状态**: 🟡 协议层已对真 schema 核完（2026-06-16，`chore/ledger-reconcile`，codex-cli **0.137.0** 真机 `generate-json-schema` dump）。**inbound `CodexThreadItem` 字段名逐一比对完 + 修了 4 个真 bug**：① `userMessage` 取 `content:[UserInput]` 的 text（原读顶层 `text`→空气泡）；② `reasoning.summary`/`content` 是 `[String]` 数组（原当 String→推理渲染空）；③ `fileChange` 从 `changes:[FileUpdateChange].path` 派生 summary（原读不存在的 `summary`）；④ tool call 用 `server`+`tool`/`namespace`+`tool`/`tool`（原读不存在的 `name`→显示成 "mcpToolCall"）。测试改用真 schema fixture（原断言虚构字段=假绿，正是上次教训）。**已对真 schema 核为正确**：outbound `thread/start`（cwd/`config.mcp_servers`/`developerInstructions`/`approvalPolicy:on-request`/`sandbox:workspace-write`/`approvalsReviewer:user` 全合法枚举）、`turn/start.input=[{type:text,text,text_elements}]`(=`UserInput`)、`turn/interrupt`、notification 名 `turn/started`·`turn/completed`·`item/completed`(读 `params.turn.id`/`params.item` 对)、**command/fileChange 审批 decision `accept`/`decline`**(=`CommandExecutionApprovalDecision`)。initialize 补了 schema 必填的 `requestAttestation:false`。
  - **真机实测已补（2026-06-16 · 本机 codex 0.137.0 已登录 · `chore/ledger-reconcile`）**：① **认证模型 ✅** —— 真起 app-server 发 `account/read` 返 `{type:chatgpt, planType:prolite}`，**自动继承 `~/.codex/auth.json`**，无需 `account/login/start`；backend「不做登录流、假设自动继承」的设计正确（内部 spec 对、官方文档「客户端驱动登录」在此版本不适用）。③ **真 turn 端到端 ✅** —— `thread/start`→`turn/start` 一轮，收到 `item/completed`：`userMessage`(`content:[UserInput]`)、`reasoning`(`summary`/`content` 均为**数组**)、`agentMessage`(`text:"PONG"`, `phase:"final_answer"`)——与修后 `CodexThreadItem` 解码**逐字段吻合**（活体验证，非仅静态 schema）；**计费 tick ✅** `thread/tokenUsage/updated` 带真 token 数（total/input/cached/output/reasoning）。**剩**：② permissions 审批 decision 形状（见下条，命令/改文件审批已验证正确）+ 一次 **app 内 `CodexTranscriptView` 活体渲染**（数据层已证，只差 GUI 像素，并入 Mac GUI QA #342/#290）。codex-app-server 已合 main（「未合 main」字样失效）。
  - **🔴→✅ codex session「跑半天转圈不结束、不知道在干嘛」根因 found+fixed（2026-06-17 · `fix/codex-session-hang`，commit `cb12cb64`+`f70eecb3`）**：用户报 codex session 卡死、claude 没事。真机复现（注入**真 crew MCP server 二进制** + captain prompt，codex-cli 0.137.0）定位为一类「turn 永不 complete」的挂死：
    1. **`handleServerRequest` 把非审批的 server-request 一律静默丢**（根因，已修）。codex 在 turn 里会发 `mcpServer/elicitation/request`（你 `~/.codex` 一堆全局插件触发的 MCP elicitation）等客户端回复，原 `guard method.hasSuffix("requestApproval") else { return }` 直接 return 不答 → codex 永等、`turn/completed` 永不来 → 右栏「运行中…」转圈不结束。claude 在自己进程里处理 elicitation，所以不挂。**修**：handleServerRequest 改 switch（`CodexProtocol.serverRequestKind`）—— approval 走审批、`mcpServer/elicitation/request` 回 `{action:decline}`（真 schema `McpServerElicitationRequestResponse`，v1 无 elicitation UI）、其余未建模（`item/tool/requestUserInput`/`item/tool/call`/`account/*`/`attestation/*`）一律回 JSON-RPC error 兜底，**绝不再静默丢 = 绝不挂死整轮**。
    2. **crew `ask` 工具无限阻塞**（已修）：`McpServer.awaitReply` 原 `while true`（生产 maxWaits=nil），没人答就让 codex 那次 `tools/call` 永不返回 → turn 挂死。加默认 maxWaits=3600（≈30min，与审批 provider 一致），到点返回「自行判断」。
    3. **codex stderr 没人读的潜伏死锁**（顺手修）：原 `standardError = Pipe()` 无 readabilityHandler，codex 往 stderr 写满 ~64KB 内核缓冲会阻塞写、卡死整个 app-server——只有长 session 累积到才撞上（短 turn/单测验不出）。加 handler 持续清空。
    - **CodexProtocolTests** 加真 schema 回归护栏（serverRequestKind 覆盖全部 ServerRequest 方法 + decline 形状），app build 绿 + 相关单测全绿。
    - **仍未真机 GUI 活验**：本机登录态在已安装旧 build，本地新 build 签名不同够不到那份 keychain 会话，没法自驱跑到「起 codex captain」态 —— 需用户 rebuild 起一个 codex captain session 看是否报到完成（不再转圈）。协议层已证「答 decline 即解锁」。
    - **残留（本次明确未覆盖，用户选「只根治挂死」）**：(a) **permissions 审批 decision 形状**仍走 accept/decline（见下条 #permissions，permissions 归 `.approval` 不进兜底分支）—— 少见的网络/sandbox 升级审批仍可能被 codex 判无效→挂；(b) **crew codex 继承你整份 `~/.codex` 全局插件**（computer-use/codex_apps/cloudflare-api[未登录]/xcodebuild/browser…，复现时见 `codex_apps` startup failed/transport error）—— 若某全局插件的 tool call 自己 hang（codex↔插件，绕过客户端），server-request 兜底救不了，需「crew session 隔离全局插件（dedicated CODEX_HOME / `-c` 关插件）」，用户本轮明确不做；(c) **无逐字流式**（delta opt-out，只渲 `item/completed`）= 用户「不知道在干嘛」的另一半，turn 进行中只有「运行中…」转圈无细节，v1 defer，要像 claude 实时流需开 delta + 渲进行态。
    - **✅ codex「思考过程是空的」根因 found+fixed（2026-06-17 · `fix/crew-chat-bugs`）**：真实 reasoning `item/completed` 在 ChatGPT 鉴权下带 `summary:[]`(空)+`encrypted_content`(加密原文,本机今日 rollout JSONL 实证),可读思考**只在** `item/reasoning/summaryTextDelta` 增量流里 —— 而 v1 opt-out 了 deltas → 「思考过程」恒空白。**修**：`CodexTranscript` 按 `itemId` 累积 `summaryTextDelta`/`textDelta`（随流出现并增长），`item/completed` 空 summary 时保留累积值（非空则以 completed 为准）；`CodexThreadItem` 加 memberwise init 供合成。把上面 (c) 的**推理那半边**接通了（`agentMessage` 逐字流式仍 defer）。单测（`CodexTranscriptTests` 两条新回归）+ macOS/iOS build 绿；**一次 app 内 `CodexTranscriptView` 真 codex 回合活验仍欠**（同 keychain 旧 build 问题，并入 Mac GUI QA #290）。

### 🟡 codex `item/permissions/requestApproval` 审批 decision 形状未建模（command/fileChange 审批正确）
- **发现**: 2026-06-16 · `chore/ledger-reconcile`（对 codex-cli 0.137.0 真 schema 核审批 roundtrip）
- **位置**: `apps/pendingcrew/Sources/Mac/LocalRunner/CodexAppServer/CodexAppServerBackend.swift:handleServerRequest`
- **问题**: 该 handler 对所有 `*requestApproval` 服务器请求统一回 `{decision: "accept"|"decline"}`。这对 **command**(`item/commandExecution/requestApproval`)和 **fileChange** 审批是**正确**的（decision 枚举 = `accept`/`acceptForSession`/`cancel`/`decline`，已核）。但 **permissions** 审批（`item/permissions/requestApproval`）的 decision 是**另一套富结构**——一个标签联合：`deny` 或 `allow{ fileSystem: AdditionalFileSystemPermissions, network, scope: turn|session }`（`GrantedPermissionProfile`），**不接受裸 `"accept"`/`"decline"`**。
- **影响**: 常见审批（批命令 / 批改文件，占 ~95%）正常。但 permissions 升级请求（网络放行 / sandbox 越权等较少见路径）会收到无效 decision → codex 大概率报错或挂起该 turn。pre-launch + 多数走 workspace-write 命令审批，影响面有限，但不是 0。
- **建议**: handler 按 method 分流：`*permissions/requestApproval` → 单独构造 `{decision:{deny}}` / `{decision:{allow:{fileSystem,network,scope}}}`（按 `PermissionsRequestApprovalResponse` schema），其余维持 accept/decline。需先把 `GrantedPermissionProfile`/`AdditionalFileSystemPermissions` 几个小结构建模。
- **状态**: 待办（command/fileChange 审批已验证正确；permissions 路径待真机遇到时按 schema 补）。`fix/codex-session-hang`(2026-06-17) 的 server-request 兜底**不覆盖本条** —— permissions 后缀含 `requestApproval` → 归 `.approval` 走 accept/decline，仍是错形状；要修得按 method 单独分流构造 `PermissionsRequestApprovalResponse`。

### 🟡 crew machine 收口 — runtime_location 降为派生镜像列 + CrewGround corpus 与服务端分家 + captainAgentKind 本地-only
- **发现**: 2026-06-14 · `feat/crew-machine`（machine 概念 + 新建流程精简）
- **三条尾巴**:
  1. **`temporary_group_meta.runtime_location` 现为派生镜像列**：本次把 crew 的运行位置收口成单个 `machine_id` FK（事实源），但因 `runtime_location`/`runtime_kind` 被 6+ 处读取（`session-world-model.ts`、`crew-comms.ts`、`messages.ts`、`crew.ts` 等），没物理删——改成 `create_crew_with_captain` RPC **写入时从所选 machine 派生**（NULL→local_host / kind=fly→fly_machine）。两个真值（machine_id + 派生的 runtime_location）并存有漂移风险（若以后有别的写路径绕过 RPC 直写 runtime_location）。**根治**：读取方逐个改成从 machine 派生 / 读 machine_id，然后 drop `runtime_location` 列 + Swift `RuntimeLocation` 枚举。
  2. **CrewGround 地名 corpus 与服务端 `place_names` 分家**：CrewGround 随机目录名用 app 内置 `apps/pendingcrew/Resources/crewground_places.txt`（**GeoNames cities15000，CC BY 4.0，asciiname 去标点/空格去重，~3.2 万条**，离线可用），服务端 `random_place_name()` 用的是 `place_names` 表（**中文**地名，建群/会话标题用）。两份独立、来源不同（GeoNames 全球英文 vs 中文）。本是有意（CrewGround 离线也要能用 + 用户要权威全球地名），但若以后要统一来源需对齐。corpus 刷新：重跑 `cities15000.txt` → asciiname 去标点去重即可。
  3. **`captainAgentKind` 只在本地 crew 持久**：建 crew 选的 captain coding-agent（claude_code/codex）存在 `LocalCrew` + 穿过客户端模型，但 **edge crew 表无此列**——relay/登录态远端 crew 不记住 captain kind（解码恒 nil→默认 Codex）。pre-launch + captain 跑本机，可接受；要远端 crew 记住时给 `temporary_group_meta` 加列 + RPC 透传。
- **状态**: 常驻参考（1 是日后清理项；2/3 是有意取舍，记着别当 bug）。

### 🟡 PendingCrew 机长建 crew 即无条件自动启动 — 无 opt-out / 无空闲回收 + 活 spawn 未 E2E
- **发现**: 2026-06-14 · `feat/crew-captain-autostart`（用户要"新建 crew 机长直接启动、群里报到、点头像进 session"）
- **背景**: chunk2 spec（`2026-06-10-pendingcrew-chunk2-captain-session-design.md` §21/§47）当初**刻意把机长定为手动启动**，自动启动/常驻"留 crew 设置（后排，token 成本考量）"。本次按用户要求把机长改成**建 crew 时无条件自动起**（`CrewStore.createCrew` 置 `captainAutostartRequest` → `MacThreePaneView` 观察到调 `CrewSessionRunner.startCaptain`）。
- **代价/缺口**:
  1. **无 per-crew 开关**：每建一个带 captain 的 crew 就**立刻 spawn 一个真 claude 进程**（机长常驻 PTY），token 从创建起就在烧 —— 正是 spec 当初担心的成本。没有"建 crew 时不要自动起机长"的选项，也**没有空闲超时回收**（机长起来就一直活到手动停/退应用）。
  2. **只覆盖"新建"**：重开 app 不会自动复活机长（run 是内存态）；老 crew / 重启后仍靠保留的手动「⚓ 启动 Captain」按钮兜底。这是有意为之（"新建即起"语义），但和"机长应该常驻"的直觉有落差。
  3. **活 spawn 未 E2E**：build + 109 单测绿、自动起走的是和手动按钮**完全相同**的 launch 路径（只换触发点），但"建 crew → 机长真的 spawn → `post_to_crew` 在群里报到 → 点头像进 session"这条**真机链路没跑过**（需真 claude CLI + 有工作目录的 crew；同 spec §63 标的"真机尾巴"）。
- **修法（若成本/体验成问题）**: 建 crew sheet 加"自动启动机长"勾选（默认开）→ 决定要不要 set `captainAutostartRequest`；机长空闲超时回收（spec 原计划的 crew 设置）；可选"app 启动时复活上次在跑的机长"。
- **状态**: 待办（功能可用；①②是产品取舍，③是真机冒烟尾巴，用户下次建 crew 时顺手看一眼即可）。

### 🟡 PendingCrew vendored 聊天视图重拷指引 + 接缝清单（drift 风险）
- **发现**: 2026-06-13 · `feat/crew-chat-align`（群聊对齐 PendingBot）
- **背景**: PendingCrew 群聊为对齐 PendingBot 且两 app 保持独立，采用 **vendor 一份拷贝**（不共享 package）。`apps/pendingcrew/Sources/Chat/Vendored/` 下的文件是 PendingBot `apps/pendingbot/Sources/` 对应文件的**逐字拷贝**（顶部有 `// VENDORED from … @ <hash>` 注释）。PendingBot 改聊天 UI 后 PendingCrew **不会自动跟上** —— 这是 vendor 模式的固有代价（换来视觉一次性对齐 + iPad 几乎免费）。
- **再对齐怎么做**: 对照 PendingBot 源**重拷** `Vendored/` 那批文件（Theme/BubbleView/ComposerView/MarkdownText 等），然后复核下面 5 类 PendingCrew 接缝是否仍成立。接缝全部打了 `// PENDINGCREW SHIM:` 注释，`git grep "PENDINGCREW SHIM"` 可一次性列出。
- **接缝清单（重拷时必须重新套用）**:
  1. `BubbleView.swift`：`FileAttachmentChip`/`saveToAlbum` 的 `APIClient().download` → `CrewAttachmentDownload.data(path:auth:)`（+ 注入 `@EnvironmentObject appModel`）；头像槽 `BotAvatar/UserAvatar` → `CrewAvatarBadges(sender:size:)`。
  2. `GroupBubbleSender` 被搬出 BubbleView 到 `Adapter/GroupBubbleSender.swift`，并加了 3 个 crew 字段 `isCaptain/sessionStatus/isSession`（默认值，不破坏 vendored 用法）。
  3. `MarkdownText.swift`：`PendingBot.Theme` → `PendingCrew.Theme` 模块限定名。
  4. `ComposerView.swift`：`HostedConfig.environment.workerURL` → 占位 URL（ServerImage shim 忽略 serverURL）；加了 `placeholder` 参数。
  5. 三个 shim 文件（`Shims/ServerImage.swift`、`UserAvatar.swift`、`AttachmentDownload.swift`）+ 本地 `Adapter/CrewChatMessage.swift`（`typealias ChatMessage`）是 PendingCrew 自己维护的，不在重拷范围；但若 PendingBot 改了 `BubbleView` 读取的 `message`/`Attachment` 字段或 `ServerImage`/`UserAvatar` 的 init 签名，要同步调这几个 shim/模型。
- **test bundle 陷阱**: `PendingCrewTests` 只能纳入 `Chat/Adapter` 下的**纯 Foundation 文件**（`CrewChatAdapter/CrewChatMessage/GroupBubbleSender`），**不能整目录**（`CrewAvatarBadges`/`ThemeCrewExtras` 依赖 Vendored 的 Theme/BotAvatar，会让 bundle 编不过）。往 `Chat/Adapter` 加新 UI 文件时注意别让 test bundle 拖进去。
- **状态**: 常驻参考（不是待办）。每次"再对齐 PendingBot"时按本条操作。

### 🟢 模型盲盒 — 端到端未验 + 持久猜测记录未回放
- **发现**: 2026-06-14 · `feat/model-blindbox`
- **现状**: 盲盒功能（藏名/猜模型/换模型/regen 重抽/bot 惊喜披露/tool 弹卡片）代码全落，edge typecheck+582 vitest 绿、iOS+macOS 双 build 绿。但有两条尾巴：
  1. **端到端冒烟未做**（同 #290/#297 约束）：新 edge 端点（`/v1/conversations/:id/model`、`reveal-model`、`prompt_model_guess`）**未部署 prod**，且模拟器无登录态 → 跑不通实流程。验证清单见 plan Task 11.1 step 3，需用户主动 `bun --filter='@pendingbot/edge' run deploy` + 登录态真机/模拟器。**未真机验前不算 done**。
  2. **持久猜测记录只写不回放**：`model_guesses` 表每次揭示落一行（actual/guessed/correct），但 iOS 目前只在 `GuessModelSheet` 猜的当下显「✓猜对/✗你猜的是X」，**重开会话只见揭示后的真名，不见历史猜测结论**。回放（气泡/卡片上长显「你猜了X·对/错」）是 plan 里标的 nice-to-have，未做。
  3. **guess_prompt 卡片即时出现**：已处理 tool turn 内的情况（turn 结束若调过 `prompt_model_guess` 就一次性 `loadHistory`+`loadConvModelState`）；纯 realtime INSERT 路径（log 行经 realtime 到达、非本端发起的 turn）是否把 `guess_prompt` 派进 `guessPromptMsgIds` 未审，最坏情况是下次重开才出卡片（罕见，1:1 场景基本走 turn 路径）。
- **状态**: 待办（主要是①需用户 deploy 后端 + 真机冒烟；②③视体验决定要不要补）。

### 🟢 PendingCrew iPad 群聊未做真账号端到端验证
- **发现**: 2026-06-13 · `feat/crew-chat-align`
- **现状**: iPad 外壳（登录→crew 列表→群聊）代码全落，macOS + iOS Simulator 双 build 绿、`PendingCrewTests` 109 绿。但**真账号端到端未验**：模拟器无登录态（device-grant 凭据），进不到 crew 聊天 —— 与 #290 三端真机验证同款约束。
- **待验**: iPad 真机/真账号扫码登录 → 见 crew 列表 → 进群聊 → 发消息 → 看 bot 回；顺带 macOS/iPad GUI 深/浅色群聊视觉确认（气泡/markdown/composer/头像徽标/卡片对齐 PendingBot）。
- **状态**: 待办（随 #290 真机批次或单独一次真账号 QA）。

### 🟢 Supabase legacy anon/service_role key 仍在项目里启用 — 全端已切新 key 后应停用
- **发现**: 2026-06-10 · `chore/supabase-new-api-keys`(API key 迁新体系收尾)
- **现状**: edge/admin/iOS/Mac 代码已全部切到 `sb_publishable_…`/`sb_secret_…`(worker 已部署并线上验证),但 Supabase 项目里 legacy `anon`/`service_role` JWT key **仍处于启用状态**(Dashboard → API Keys → Legacy tab)。两套并存是迁移期的预期形态,不是事故。
- **遗留的 legacy 消费者**: (a) 已安装的旧 iOS 构建(二进制里嵌着旧 anon JWT)——pre-launch 只有用户自己的真机,装一次新构建即清零;(b) 本地 `supabase start` 栈(CLI 仍发 legacy 格式,`HostedConfig` `.dev` 与 `.dev.vars.example` 注释已说明);(c) 边角脚本若直接拿旧 key 调用(已知的 envelope-replay/list-convs 已切新名)。
- **修法**: 真机装上新构建、确认无别处引用后,在 Dashboard 把 legacy keys disable(可随时 re-enable,非删除)。官方截止 2026 年底,不急,但停得越早攻击面越小——legacy service_role JWT 与 JWT secret 绑定,不可单独轮换。
- **状态**: 待办(一次 Dashboard 操作 + 真机冒烟)。

### 🟡 board 管理台无可用浏览器登录路径(EU Supabase CAPTCHA 挡客户端登录) — ✅ 已解决/被取代 2026-06-13
- **发现**: 2026-06-09 · `feat/board-console` e2e 验证时
- **现象**: `apps/admin` 登录页走 `supabase.auth.signInWithPassword`,EU 项目(zafhoiwwpanpuashtnxy)Auth 开了 CAPTCHA 保护 → 客户端登录返回 `captcha protection: request disallowed (no captcha_token found)`。客户端 OTP(`signInWithOtp`)同样会被 captcha 挡。**只有 service_role 的 admin API(generate_link+verify)能绕过 captcha** —— 这正是本次 e2e 用来 mint JWT 验证后端的方式。
- **影响**: board 后端已端到端验证可用(requireAdmin/CRUD/audit 全通),但**没有真人能从浏览器登进去** —— 部署后前门仍是锁的。
- **修法(择一,属"board auth 加固"未来工作)**: (a) 给登录页接 Cloudflare Turnstile 控件,`signInWithPassword({options:{captchaToken}})` 带 token;(b) 直接做用户定的 passkey+TOTP+密码栈(passkey 需先核 Supabase 原生支持,见下条相关);(c) 仅临时:Supabase 后台关 CAPTCHA 验完再开(不作为长期方案,削弱真 app 注册防护)。
- **状态**: ✅ 已解决/被取代（2026-06-13 · board 认证整体改走 **Cloudflare Access**，应用内不再放第二个登录，task #289）。CAPTCHA 挡的是 supabase 客户端登录，而 board 前端已删 login / auth-provider / supabase client —— 2026-06-16 复核 `apps/admin/src` 对 `signInWithPassword`/`signInWithOtp`/`supabase` **零命中**，登录走 Access（`credentials:include`）。原"接 Cloudflare Turnstile"方案随之作废；第二因子归 Access policy。

### 🟢 `wrangler dev` 默认 env 无 KV/DO/R2 绑定 — board feature-flags 本地 PUT 会 500
- **发现**: 2026-06-09 · board e2e 时
- **现象**: `wrangler.jsonc` 的真实绑定全在 `env.production` 下,默认 env(`wrangler dev` 用)只有 vars。`c.env.MEMORY` undefined → feature-flags PUT 抛 `Cannot read properties of undefined (reading 'put')` 500;**读路径不受影响**(`loadOverrides`/`readOverrides` catch 后回退 env 默认 —— 优雅降级符合设计)。`--env production` 会触发容器镜像构建(要 Docker),不适合轻量本地调试。
- **本次 workaround**: 临时在 wrangler.jsonc 顶层加 `kv_namespaces: [{binding:'MEMORY', id:…}]`(本地模拟,不碰生产 KV),验完 `git checkout` 还原。
- **修法(若本地调 board 写路径成为常态)**: 把 MEMORY(及按需 PROMPTS_KV)的 kv_namespaces 永久加到默认 env —— 本地是 miniflare 模拟,加了无副作用;或接受每次临时加。
- **状态**: 接受(一次性 e2e 已过);记此免得下个 session 重新踩。

---

### 🟢 功能开关(board)运行时切的传播延迟 ≤60s + Sentry 仍 env-only
- **发现**: 2026-06-08 · `feat/board-console`(计划 `docs/superpowers/plans/2026-06-08-board-feature-flags.md`)
- **位置**: `apps/edge/src/lib/feature-flags.ts`(isolate 60s TTL 缓存)、`apps/edge/src/routes/board-feature-flags.ts`(PUT 写 `cfg:feature-flags` KV)
- **取舍 1(传播延迟)**: board 切 Billing/PostHog/Langfuse 后,worker 端要 ≤60s(isolate-local TTL 缓存)+ KV 全球传播(秒级)才全节点生效。PUT 没做显式 cache-bust —— isolate 多、bust 不可靠。对 pre-launch 开关可接受;若将来要"切了即时全网生效",得改更短 TTL 或挪到一个单点 DO 读。
- **取舍 2(Sentry 不上 board)**: Sentry 开关保持 env + 重部署,**故意不做运行时切**。原因:(a) `@sentry/cloudflare` 的 `withSentry` options 回调签名是同步 `(env)=>CloudflareOptions|undefined`,容不下异步 KV 读;(b) 错误捕获器的 kill-switch 必须零运行时依赖,不能让它依赖 KV/DB,否则一次边缘存储抽风会顺手静音它。board 页给 Sentry 一行只读展示。这不是债,是刻意设计,记此供将来回看"为什么 Sentry 不在 board"。
- **状态**: 接受(pre-launch)。即时生效需求出现时再处理取舍 1。

## 使用约定

- 发现就追加一条，**只记录、默认不顺手去修**——修一个根基问题往往是独立的一摊活，会冲散当前任务的焦点。除非用户当场要你修。
- 当前任务里如果**新引入**了一个明知是临时/将就的实现，也要主动记一条（诚实标注自己挖的坑），别让它无声沉底。
- 修掉某条后，把 `状态` 改成 `已解决` 并附 commit / 日期，不要直接删——保留它当过的坑的历史。
- 条目按严重度分组；同组内新的放上面。

## 条目格式

```
### 🔴/🟡/🟢 一句话标题
- **发现**: YYYY-MM-DD · 分支或 session
- **位置**: path/to/file.ts:line（或模块名）
- **问题**: 哪里不对
- **影响**: 为什么动摇根基 / 它在替什么遮羞
- **建议**: 该往哪个方向收（可选）
- **状态**: 待办 / 已解决（commit、日期）/ 不修（原因）
```

---

## 🔴 根基级

### 🔴 `Features/*` UI 整体被无谓 `#if os(iOS)` 一刀切 → Mac 被迫平行重写,两套 UI 长期漂移
- **发现**: 2026-06-08 · `feat/tri-platform-ui`
- **位置**: `apps/pendingbot/Sources/Features/*`、`apps/pendingbot/Sources/Mac/*`
- **病根**: 当年图省事把整个 `Features/*` 包进 `#if os(iOS)`,并非真有 iOS-only 依赖(实测只一小撮薄 shim:haptics/导航标题/剪贴板/二维码/键盘类型)。Mac 因此在 `Sources/Mac/` 整套平行重写,功能恒为 iOS 子集(典型:建 bot 只能单模型,无 arena)。两套 UI 靠人维持一致 → 必然漂移(#212 / `feat/mac-login-align` 就是在逐屏补这个漂移)。
- **影响**: 三端体验不一致;每个新功能要写两遍;Mac 永远慢一拍。
- **✅ 已基本解决(2026-06-09,已合 main `b4d0b131`)**: `feat/tri-platform-ui` 彻底版全 slice 迁完——好友/消息/会话/来信/我/Crew/群 全部跨平台 conform FeatureSurface + 接 WideRootView,iPad 收敛三列,`Sources/Mac/` 删到只剩 MacWelcomeView(登录壳)。两套 UI 在业务面正式合一。**剩尾巴(已记下方各 🟡 条 + task #290-292)**:Phase 7 三端真机/模拟器验证(代码全绿但未真机验)、Mac composer 三横幅、Mac 二维码名片等降级。`feat/mac-login-align`(#212 对齐版)作废,以本条为准。
  - **(2026-06-09)WideRootView 接共享 FriendsTabView/MessageTabView surface + 删 4 个 Mac 平行文件(双端 BUILD SUCCEEDED)** — 好友/消息 tab 中列取 `listColumn(selection:)`、右栏取 `detailColumn(selection:)`(`db4d7d1c` 接线 + `92912e00` 删 `MacFriendsView`/`MacBotManagement`/`MacMessagesView`/`MacRootView`)。crew/envelope/me 仍走各自 Mac 平行列(`MacCrewListColumn`/`MacEnvelopeColumn`/`MacRemoteSessionsView`/`MacMeView`,留待后续 slice)。
  - **✅(2026-06-09)Crew slice 收口 → WideRootView 现 100% 共享 surface,零 Mac 平行列(双端 BUILD SUCCEEDED)** — `CrewTabV2View` conform FeatureSurface(Selection=crew id 字符串,detail `CrewDetailV2View(crewId:)` 按 id 自取),crew tab 中列/右栏改取共享 surface(`25eb18f4` conform + `73faafbe` 接线 + 删整个 `Mac/Views/MacRemoteSessionsView.swift`(`MacCrewListColumn`+`MacRemoteSessionsView`))。**至此五个 tab 全部由共享 FeatureSurface 渲染,`WideRootView` 内再无任何 `#if os(macOS)` Mac 平行列**;顺手删了已成死代码的 `selectedItemId`/`pendingConversationJump`/切 tab 清 selection 的 onChange。**同时解决了下方 2026-06-08「Mac ConversationView 跨平台」条目的第 3 个尾巴**:`decideCrewProposal`/`decidePermissionRequest` 的 `#if os(iOS)` 围栏 + macOS no-op `#else` 已拆(`7c5f8735`),CrewAPI 已全跨平台,机组提案/权限请求的决定在 Mac 走真实 round-trip。剩"渲染像素 + 真账号"待 Phase 7 真机。
    - **✅ 已解决(`feat/tri-platform-ui`,2026-06-09,双端 BUILD SUCCEEDED)**:Group slice 跨平台化后,删孤儿 `Sources/Mac/MacGroupWalletView.swift`(grep 零引用确认 + `xcodegen` 重生 pbxproj),并摘掉 `CrewDetailV2View` 群钱包行的 `#if os(iOS)` gate——Mac 现共用跨平台 `GroupWalletView`,群钱包入口恢复。`Sources/Mac/` 现只剩 `MacWelcomeView.swift`(macOS 登录门户)。
  - **✅ 已解决(`feat/tri-platform-ui`,双端 BUILD SUCCEEDED)**: detail 恒拿 `bot: nil` 的装饰性降级已修 —— ConversationView 于 `bot==nil` 调 `resolveBotIfNeeded()`(`ConversationView+Loading.swift`)按 `conversation.bot_id`/`pendingPeer.peerId` 自取 `bots` 行,`effectiveBot = bot ?? resolvedBot` 驱动头部 `· <模型>` 后缀 + `BotConfigView` 入口 + pre-chat 设置按钮。**gated on `bot==nil` → iOS(恒传 bot)为 dead path,行为零变化**。剩"渲染像素 + 真账号"待 Phase 7 真机。

### 🔴 好友列表(FriendsTabView)与消息/会话slice焊死 — 跨模块隐性耦合
- **发现**: 2026-06-08 · `feat/tri-platform-ui`
- **位置**: `Features/Friends/FriendsTabView.swift` ↔ `Features/Message/ConversationView.swift`(+9 扩展)
- **耦合**: FriendsTabView 宽屏详情列**就是** `ConversationView`,导航栈用 `PendingPeer`(消息slice类型)。想共享好友列表必须连消息slice(24 文件/~10k 行)一起跨平台化,而消息slice又焊死 Call(iOS-only 语音)/相机相册(iOS-only)/键盘 inputAccessoryView(iOS-only UIKit)。
- **处置**: 已测绘全部 iOS-only 面,plan 用**内部 `#if os(iOS)` 围栏**(非整文件锁)隔离 Call/相机/键盘,Mac 干净降级(无语音按钮、相册→文件选择、composer 用 safeAreaInset 代 inputAccessoryView)。这些 Mac 降级在 Phase 4 实装时各记一条 🟡。
### 🔴 客户端多账号本地隔离只靠"登出时擦库"一条腿,无 account_id 维度过滤 + URLCache 登出不清
- **发现**: 2026-06-08 · session(用户问"登一个号再登另一个号数据会混吗")
- **位置**: `apps/pendingbot/Sources/Storage/AccountStore.swift:226`(`signOut`)、`apps/pendingbot/Sources/Storage/LocalDatabase.swift:338`(`wipeForSignOut`)、`:378`(`loadConversations` 等读查询)、`apps/pendingbot/Sources/Storage/ProtectedURLCache.swift`、`apps/pendingbot/Sources/PendingBotApp.swift`(`onChange(of: accountStore.current)`)
- **问题**: 本地 SQLite(会话/消息/好友/群)的账号隔离**完全依赖"登出时 `wipeForSignOut()` 物理删库 + 轮换 Keychain 密钥"**。表里虽有 `user_id`/`account_id` 列但**读查询一律 `fetchAll` 不带 WHERE 过滤**,DB 本身不区分账号。两个具体缺口:
  - ① **URLCache(图片/HTTP 缓存)登出时不清**。`signOut()` 删了 DB 却没调 `URLCache.shared.removeAllCachedResponses()`,`~/Library/Caches/ProtectedURLCache/` 是全用户共用目录、非账号作用域。实害有限(缓存键是 `/v1/uploads/<id>` 级 URL,B 通常不会去请求 A 的 upload id),但"登出后磁盘仍残上一个账号的图片缓存"是事实,隐私/卫生缺口。
  - ② **强制换号(不经过 `signOut`)会泄漏**。`observeAuth()` / 后台刷新拿到**另一个 user 的 session** 时直接 `current = makeAccount(session:)`,不比较 `old.id != new.id`、不触发擦库;`PendingBotApp` 的 `onChange` 只判 `old == nil && new != nil`(纯登入)。因为没有 account_id 过滤,A 的整库在 B 的会话里仍可读。日常无 UI 经路(换号必走 signOut→signIn),属 token 刷新返回异身/服务端 session swap/会话劫持等例外时的洞。
- **影响**: 账号隔离是隐私/数据一致性根基。当前"擦库一条腿"在正常登出登入流程下是安全的,但①让登出后残留可缓存内容、②让任何"绕过 signOut 的 session 变更"直接串号。两者都随功能增长易被无声打破(谁加个直接切号入口或改刷新逻辑就踩)。
- **建议**: ① `signOut()` 里补 `URLCache.shared.removeAllCachedResponses()`(顺手把 ProtectedURLCache 目录也清)。② `PendingBotApp.onChange` 加 `if let o=old?.id, let n=new?.id, o != n { LocalDatabase.shared.wipeForSignOut(); AvatarCache.shared.clear(); URLCache… }` 守护强制换号。③ 中长期:给本地表加 `account_id` 并让所有读查询带 `WHERE account_id = ?`,把隔离从"擦库"升级为"作用域过滤"(纵深防御,即使擦库漏了也不串)。
- **状态**: 待办(仅记录,未修)。

### 🔴 pnc_ledger 计费账本曾对 anon 可读、对 authenticated 可改写(RLS 没开);宽 grant 习惯需审计
- **发现**: 2026-06-08 · chore/security-advisor-hardening(Security Advisor 体检)
- **位置**: `pendingbot.pnc_ledger`(整数事实源账本)+ 各表的 anon/authenticated grant
- **问题**: pnc_ledger 是计费的整数事实源,但**RLS 一直没开**,且 `anon` 有 SELECT、`authenticated` 有 INSERT/SELECT/UPDATE/DELETE —— 任何登录用户能读/篡改**全量**账本、未登录用户能读全量。`me.ts /wallet/v2` 用**用户态 client** 读它,注释还写着"RLS 仅本人",但那道保护从来不存在(RLS 没开,只靠应用层 `.eq('subject_id', …)` 过滤,绕过即泄)。根因是**给表发 grant 时习惯性放宽**(连 anon 都给了 SELECT),而 RLS 没跟上。已修(`20260608083813`:开 RLS + subject 维度 SELECT policy + 收 anon/写权限)。
- **影响**: 计费账本是钱的事实源,世界可读可改 = 数据泄露 + 篡改面。同类风险:**只要某张敏感表 grant 给了 anon/authenticated 又忘了开 RLS(或 RLS policy 比 grant 宽),就是同样的洞**。Supabase Security Advisor 的 `rls_disabled_in_public` 只抓"RLS 没开"这一种,抓不到"RLS 开了但 policy 太宽"或"grant 给 anon 太多"。
- **建议**: ① 上线前把 **Security Advisor 跑成准入门**(`get_advisors security` 必须无 ERROR)。② 审计所有表的 anon grant —— anon 默认应几乎什么都没有(只有少数公开资源如 disposable_email_domains 才需要);写个 CI 断言"anon 不持有任何 pendingbot 表的写权限、敏感表无 SELECT"。③ 约定:新表一律先 `ENABLE ROW LEVEL SECURITY`,再按需加 policy;grant 走最小权限,别习惯性给 anon/authenticated 全 CRUD。
- **状态**: pnc_ledger 实例已解决(`20260608083813`,db push 已应用 prod;验证:RLS on、anon 无权限、authenticated 仅 SELECT 自己、policy 生效)。**全表 grant 最小化审计 + advisor 准入门(①②)待办**。
- **已审计为有意保留(Security Advisor 余项,非洞)**: 6 个 `bi_*` SECURITY DEFINER 视图(Grafana BI 让 bi_ro 跨 RLS 读聚合,故意的)、16 个 `rls_enabled_no_policy`(service-role 专用表,开 RLS 无 policy = 锁死 = 安全)、71 个 `authenticated` SECURITY DEFINER 函数(`20260524175632` 显式授的 RPC 面,内部自带 authz)。两个配置项留用户:`auth_leaked_password_protection`(Dashboard Auth 开关)、`pg_net in public`(迁 schema 有风险,暂留)。

### 🔴 账号删除级联靠手维护,有两类静默杀手(NO ACTION 外键 + 收敛式 RI 交织);已第二次漂移
- **发现**: 2026-06-08 · fix/account-deletion-cascade
- **位置**: `supabase/migrations/0052_auth_delete_user_trigger.sql`(`_before_auth_user_delete` BEFORE DELETE 触发器)+ 全 schema 指向 `auth.users`/`pendingbot.users`/`pendingbot.subjects`/`conversations` 的外键 `ON DELETE` 动作
- **问题**: `delete from auth.users` 能不能成功靠**两套手维护的东西**+ 一个 **Postgres RI 陷阱**同时不出错:
  - ① 0052 触发器里逐表写死的 cleanup(删 bots/messages/convs、置空 audit_log/invites…);② 每张引用用户/subject 的表的 FK `ON DELETE` 动作。任何新表带个指向 user/subject 的 `NO ACTION`(Postgres 默认!)外键又没被照顾,就静默让全站删号报 "Database error deleting user"。这次 subject 体系(2026-05-24)整套没纳入 → 8 张 crew/runner 子表 `NO ACTION`。**migration `20260608051247` 给它们补了动作**。
  - ③ **更隐蔽的杀手——收敛式多路 RI 交织**:一行同时被同一次 `delete from auth.users` 语句里的**一条 CASCADE 路径**和**一条 SET NULL 路径**命中,Postgres 在级联中途重校该行外键 → 23503(`insert or update on … violates …_fkey`)。device-login challenge 就是:`approved_by_user_id→users SET NULL` + `approved_subject_id→subjects SET NULL` + `issued_grant_id→grants CASCADE(随 subject)`,三路收敛在同一行。**纯改 FK 动作治不了**(它是级联中途对该行的"写"),`20260608051247` 把 issued_grant 改 CASCADE 后**仍然报同样的错**——这是教训:当时凭静态 FK 分析断定"级联是干净的",没复现就宣布修好,结果没修好。后来用回滚事务复现才钉死:删 subject 单独干净、删 auth.users 不干净,差就差在 auth.users 这一层的 SET NULL 路径。**全 schema 审计出恰好 4 张收敛表**(subjects / user_bot_contacts / group_join_requests / group_subject_members)。`20260608061958` 在 BEFORE 触发器里把这些行**提前单路删掉**(级联前删，互不交织),根治。
  - **这是第二次漂移**:0002→0052 已补过一次同类账。
- **影响**: 账号删除是合规面(数据删除权)+ 产品面(注销)的根基功能,却是最容易被新表悄悄打破的一类——破坏者离它很远(加张无关表),症状是全站删号挂掉,且**只有真正执行删除才暴露**(CI/typecheck 完全抓不到)。两类杀手都会随表数量**反复**复发。
- **建议**: 把两个隐式不变量都变成红灯。① **NO ACTION 审计**:CI 断言"从 `auth.users` 出发的删除闭包里没有未被触发器覆盖的 `NO ACTION`/`RESTRICT` 外键"。② **收敛式 RI 审计**:CI 断言"没有一张表同时拥有指向 user/subject 的 CASCADE 外键和 SET NULL 外键"(本次那条 `bool_or(act='c') AND bool_or(act='n')` 查询),命中的必须进 BEFORE 触发器提前删。③ 约定:新表带指向 user/subject/conv/bot 的外键必须显式声明 `ON DELETE`,别吃 Postgres `NO ACTION` 默认。④ 流程教训:**删除级联这种"只有真删才暴露"的改动,别凭静态分析宣布修好——必须用回滚事务复现失败、再验证修复**。
- **状态**: 两个实例都已解决并 db push 应用 prod(`20260608051247` 补 NO ACTION + 子树动作;`20260608061958` BEFORE 触发器提前删 4 张收敛表)。验证:回滚事务模拟 4 张收敛表的提前删 + subject 子树级联在真实卡住账号 617259ec 上全部 clean;真删本身受 prod 写门禁,留用户在 Studio 作终确认。**防复发护栏(①②CI 审计)待办**。

### 🔴 边缘读投影授权门 ↔ Supabase RLS 对齐是隐式不变量,无测试守护
- **发现**: 2026-06-07 · feat/edge-read-offload(E6 对抗式审查 E4 授权门)
- **位置**: `apps/edge/src/routes/projections.ts`(`/messages/tail` 授权门)+ `apps/edge/src/lib/conv-cache.ts:resolveConv` + `supabase/migrations/*`(`conversations` / `messages` SELECT policies)
- **问题**: 热路径(命中投影 DO)读消息尾完全靠 worker 授权门(`resolveConv` → `conversations` SELECT RLS 可见性)决定放不放行;投影 DO 的内容是 service-client 回填的(绕 RLS),所以**门是热路径唯一权威**。当前是安全的,因为 `conversations` 的两条 SELECT policy(`conversations_participant_read`=is_participant、`conversations_temporary_group_view`=can_view_temporary_group)与 `messages` 的两条 SELECT policy(`messages_participant_read`=is_participant+排除 voice_call_summary、`messages_temporary_group_read`=can_view_temporary_group)**逐条对齐** —— 能看见 conversation 行的人正好能看见它的 messages。但这个对齐是**隐式的、靠人记**:E6 审查时是手工逐条比对 migration 才确认的,没有任何测试/断言守护。
- **影响**: 谁要是以后给 `conversations` 加一条**更宽**的 SELECT policy(让某类用户能看见会话行)却忘了给 `messages` 加对应 policy(或反过来),授权门会基于"能看见 conversation"放行,而热投影把**全量消息尾**喂给一个 RLS 本不允许读消息的用户 → **静默 IDOR**,且冷回落(`tailFromSupabase` 带 user JWT 走 RLS)只在投影 RPC 失败/空时才触发,正常热命中根本不经 RLS,这个洞不会被冷路径兜住。属安全/一致性根基隐患。
- **建议**: ① 在 spec §7.2 的"RLS 可见性规则对照表"里把"`conversations` SELECT 可见性必须 ⊆ `messages` SELECT 可见性"列为显式不变量,且任何动这两表 RLS 的 migration 必须同时复核对侧。② 更硬的做法:加一个 live-DB introspection 测试(或 CI 检查)断言"对每种 conversation_type,能 SELECT conversation 的角色集 == 能 SELECT 其 messages 的角色集",把隐式不变量变成会失败的红灯。③ 或者干脆让热路径授权门改判 `is_participant`/`can_view_temporary_group` 的**成员语义**(而非"能否 SELECT conversation 行"),与 messages 可见性同源,消除两表 policy 漂移的耦合面。
- **状态**: 待办(当前实现已验证安全,这是防回归/防未来漂移的护栏)

### 🔴 welcome bonus 可被 email `+` 别名薅羊毛 — 注册无 email 规范化
- **发现**: 2026-06-04 · feat/managed-config（讨论测试账号怎么收 OTP 时逼出来的）
- **位置**: signup 链路（`auth.users` 唯一性按 email **原文**）+ `apps/edge/src/lib/billing-grant.ts:grantSignupBonus`（welcome 35 PNC ≈ $1.30）
- **问题**: 注册只按 email 原文查重，没有规范化。`user+1@gmail.com` / `user+2@...`（Gmail 还忽略 `.`：`u.s.e.r@gmail.com`）对系统是**不同用户**、对邮箱是**同一个收件箱** → 一个真实 Gmail 能注册无限账号、每个都真实收到 OTP 走完整链路。已有的 `reject_disposable_email`（迁移 0050/0053）只挡一次性邮箱**域名**，挡不住正常域名的 `+`/`.` 别名。
- **影响**: 上线**开计费（`BILLING_ENABLED`）后**，welcome bonus 变成 Sybil / 薅羊毛向量 —— 一个邮箱无限薅 $1.30/账号 的 LLM 额度，规模化就是真金白银损失。现在 kill-switch 关着、bonus 休眠未暴露（**没在烧钱**），但这是**发计费前必须堵的洞**。
- **建议**: 两层。① **抬高造号成本**：注册时 email 规范化（gmail/googlemail 去 `+后缀`+`.`、归一后查重，堵 `+`/`.` 别名；只对已知规则大商做、别误伤小众商）+ 维护 disposable 黑名单 + 注册 rate limit。② **断薅羊毛收益（根本，移动 app 标准做法）**：welcome bonus **绑设备** —— iOS **DeviceCheck / App Attest** 让一台设备只领一次 bonus，跨多少账号都无效（比 email 规范化彻底，攻击者绕不过设备指纹）；或更狠 **绑首充**。**主力做 DeviceCheck，email 规范化当辅助**。
- **决策（2026-06-04）**: 登录**留 email OTP + Apple + Google 并存**（评估过纯 OAuth，最终为不把退路交第三方/email 触达/覆盖面而保留 email）→ 所以防滥用是**明确要做的路线**，不是靠砍 email 规避。
- **状态**: 🟡 进行中 —— **email 规范化半已落**（迁移 20260604102812：`normalize_email` + `welcome_bonus_grants` dedup 账本 + billing-grant `claimWelcomeBonus`；已 push EU + typecheck/497 测试绿，commit 6ab22018）。**DeviceCheck/App Attest 主力半仍待办**（硬卡真机，见 task #252）。

## 🟡 拆东墙补西墙

### 🟡 cache-first 视图把缓存读放进 `.task` → 首帧后才注入,每次出现都闪一下(已修 3 个主面)
- **发现**: 2026-06-16 · `fix/cache-first-init-paint`(用户报"头像/bot 名字/私有公有标签/对话页名字+模型 每次打开都过 0.x s 才更新,切 tab 回来也一样")
- **位置**: `apps/pendingbot/Sources/Components/UserAvatar.swift`、`Features/Friends/FriendsTabView.swift`、`Features/Message/ConversationView.swift`(+`ConversationView+Loading.swift`);同类未改面见"残留"
- **病根**: 这些视图号称 cache-first,但缓存读发生在 `.task`/`.onAppear` 闭包里 —— SwiftUI 的 `.task`/`onAppear` 在**首帧渲染之后**才跑,所以首帧画的是空/占位(`@State` 初值),0.x s 后缓存(或网络)值才注入 → 肉眼跳变。`.task` 每次 appear 都重跑;iPad/Mac 三列壳每次切 tab **重建**当前 tab(`FriendsTabView.load()` 的 `CancellationError` 注释自陈"Mac shell rebuilds the active tab on every selection change"),@State 清零 → 整体空→填,所以"切 tab 回来也闪"在 iPad/Mac 尤甚。`CacheRepository.cachedBots()/cachedContacts()`、`LocalDatabase.load*()`、`AvatarCache.shared.image(for:)` 全是同步的,本可在 `init` 同步读 —— 只是没这么用(`FriendsTabView.load()` 那段预热注释还写着"paint last-known friends **instantly**",但埋在 `.task` 里其实晚一帧)。
- **影响**: 首帧渲染正确性 —— **就是 task #265「app 首屏可视渲染验证」一直挂着没验的那个洞的可见症状**。不崩,但每次进页/切 tab 都肉眼跳一下,廉价感。
- **已修(本分支,均 iOS build 绿)**: 把同步缓存读从 `.task` 提到 `init`,用 `State(initialValue:)` 让首帧即带缓存值。① `UserAvatar`(`6ac8c98d`)init 同步 `AvatarCache` 命中即播种 `image` —— 覆盖所有头像(自己/对话头/好友列表/群 roster),暖缓存零闪;② `FriendsTabView`(`afb08e56`)`@MainActor init()` 播种 `bots`/`humans`/`lastActivity`,`load()` 收成纯网络刷新(删 `.task` 内预热块);③ `ConversationView`(`1969185f`)`bot==nil`(Mac/iPad detail 列)时 init 从本地 bots 缓存构造 `resolvedBot` 播种头部名字/模型后缀/语音键,`resolveBotIfNeeded` guard 改只判 `bot==nil` + 仅 fetch 结果变化才赋值(缓存对不重渲染=不闪,缓存旧静默纠正)。
- **残留 / 同类未改面**:
  1. **`MessageTabView` 会话列表仍在 `.task` hydrate**:行头像已被 ① 覆盖(不闪);行标题/排序的 `conversations` 仍 `.task` 注入 —— iPhone TabView 保活、列表持久基本无感,iPad/Mac 重建路径仍空→填。要彻底一致,同 ② 给它 `init` 播种 `ChatDataSource.cachedConversations()`。
  2. **盲盒模型 pill 固有一跳**:`convModelState`(`has_pool`/`reveal_mode`/`model_revealed`)走 `GET /v1/conversations/:id/model`,**本地无缓存**。非盲盒会话靠 ③ 的 bot 模型兜底已不闪;盲盒会话仍会从"bot 模型名"跳到"PendingModel/抽中模型"。要消除得把会话模型态也落本地缓存(未做)。
  3. **其它面未逐一审**:群设置(已 cache-first,需确认是否 init 播种)、信箱/钱包(本就无缓存,见各自审计条目)等还没按"init 同步播种"过一遍。
- **约定(新)**: cache-first 视图的"首帧要显示的缓存值"应在 `init` 同步播种 `@State`(读方法是 `@MainActor` 同步的,init 标 `@MainActor` 即可),`.task` 只做网络刷新;别把它留在 `.task` 里 —— 那等于晚一帧,必闪。
- **状态**: 🟡 进行中 —— 三个用户报的主面已修 + build 绿;残留 1/2/3 待定。**视觉验证(真不闪)需登录态 GUI 构建**(headless 装机回落 ad-hoc 签名→会话存不住,见 memory `feedback_sim_unsigned_keychain`),并入 task #265「首屏可视渲染验证」。

### 🟡 PendingCrew shared target 混入未 guard 的 AppKit，iOS build 当前被卡死 — ✅ 已解决 2026-06-16
- **发现**: 2026-06-15 · `codex/pendingcrew-empty-placeholder`（给 PendingCrew 未选中 crew 空态换 custom symbol 时跑 iOS build）
- **位置**: `apps/pendingcrew/Sources/Stores/LocalDataReset.swift`
- **问题**: `PendingCrew` target 的 `supportedDestinations` 同时包含 iOS/macOS，`project.yml` 又把整个 `Sources` 编进同一个 app target；但 `LocalDataReset.swift` 在 shared `Sources/Stores` 下直接 `import AppKit` 并调用 `NSWorkspace` / `NSApp`，没有 `#if os(macOS)` guard 或文件级排除。结果 `xcodebuild -project apps/pendingcrew/PendingCrew.xcodeproj -scheme PendingCrew -destination 'generic/platform=iOS Simulator' build` 在解析 AppKit 时直接失败。
- **影响**: macOS build 仍绿，但 iPad/PendingCrew iOS 目标已经不是可验证状态；任何 shared UI 改动都无法用 iOS build 做回归检查，容易把“支持 iOS”的 project 配置变成纸面承诺。
- **建议**: 把 `LocalDataReset` 拆成 cross-platform 协调器 + macOS-only relaunch 实现（或把该文件搬到 `Sources/Mac` 并给 iOS 提供 no-op/替代实现），同时让 `project.yml` 的 source inclusion 明确区分 shared 与 platform-only。
- **状态**: ✅ 已解决（2026-06-16 · commit `3b1389a1` 审计 Y1 重写该文件时已按建议加 guard —— `import AppKit` 包进 `#if os(macOS)`、`NSWorkspace`/`NSApp` relaunch 全套 `#if os(macOS)` 围栏，iOS 端走 no-op）。2026-06-16 本 session 复验 `xcodebuild -project apps/pendingcrew/PendingCrew.xcodeproj -scheme PendingCrew -destination 'generic/platform=iOS Simulator' build` = **BUILD SUCCEEDED**。当时其它分支记的"双端 build 绿"才对，本条"iOS build 卡死"（2026-06-15 codex 分支）已失效。

### 🟡 本地白板 app↔helper 并发读写同一 JSON（无锁，last-write-wins 偶丢消息）
- **发现**: 2026-06-08 · feat/session-crew-comms（chunk 4 实装 L7）
- **位置**: `apps/pendingcrew/Sources/Stores/LocalWhiteboardStore.swift`（`append` = load→mutate→atomic write）
- **问题**: chunk 4 把 `LocalWhiteboardStore` 去了 `@MainActor` 改 `@unchecked Sendable`，因为 `pendingcrew-mcp` helper（claude 子进程）要和 PendingCrew app **两个进程**读写同一份 `<dir>/<crewId>.json`。`append` 是 read-modify-write + 整文件 `atomic` 覆盖写，**无跨进程锁**。app（中栏 3s poll/发消息）与 helper（session `post_to_crew`）若几乎同时写，后写覆盖前写 → 丢一条消息。
- **影响**: 单用户本地、写频率低（人打字 + session 偶尔 post），命中概率小；但"session 上报"和"人发指令"挤到一起时**理论可丢**，且无任何告警。属数据一致性隐患（非根基级，因为白板是通信缓冲不是事实源，丢一条不致命）。
- **建议**: v1 接受。后续二选一：① 改 **append-only**（每条消息一个文件 / 一行 NDJSON 追加，避免整文件 RMW）；② 跨进程**文件锁**（`flock`）。append-only 更顺（读时合并排序）。
- **状态**: 待办（v1 故意接受）

### 🟡 T2 边缘读 cutover 只 build 验、runtime 从未跑过 + 两处边缘 vs Supabase 精度差
- **发现**: 2026-06-07 · feat/edge-read-cutover（T2 Phase3b）
- **位置**: `apps/pendingbot/Sources/Networking/EdgeReadSource.swift`、`ConversationFetch.list`、`MessagesFetch.latest`；edge 端 `routes/projections.ts` + 两个投影 DO
- **问题**: 会话列表 + 消息尾的读已切成 **edge-first（`/v1/conversations` & `/v1/messages/tail`）+ Supabase fallback**,但**这套边缘端点从未在 runtime 真跑过**——只有 vitest + 双端 build 绿,没有 `wrangler dev` 冒烟、没有真机/真账号验(用户当时定"直接切、build 验证、runtime 留后")。fallback 兜底(任何 error/可疑空 → 回落 Supabase)是唯一的运行期安全网。另有两处边缘行相对 Supabase 的**精度差**:① 边缘列表行无 `last_message_id`(UnreadJoin 该字段 nil;`last_activity_at` 改用 `updated_at` 不丢时间戳);② `user_user` 对端在会话 `user_id==myId` 时,合成 participant 被 `!=myId` 滤掉 → 该行本次刷新无 peer 名(本地缓存旧值或下次 Supabase 刷新补)。
- **影响**: pre-launch、无人用、有 fallback,所以不会崩;但**最终使用路径(iOS/Mac 真机 + 真 Supabase 边缘端点)未验证**——投影/delta/回填/2MB 护栏的 runtime 正确性、列表 hydration 的视觉效果都还是纸面。user_user 人类私聊的列表 peer 名可能短暂空(主要是 user-bot,影响面小)。
- **建议**: ① **runtime 冒烟**:部署 edge(或配 `.dev.vars` 跑 `wrangler dev`)+ 真 JWT 打两个端点,验投影命中/冷回填/授权门/2MB 护栏;② 真机/真账号验首屏(列表 + 开会话)走边缘路径渲染正确、fallback 触发正确;③ user_user peer:客户端映射时**保留本地缓存已有 embed**(别用边缘空值覆盖),或边缘端点解析对端;④ 押后优化:delta cursor(现 full-fetch since=0)、`{__truncated:true}` 富列懒取(现当 nil)。
- **状态**: 进行中（**2026-06-07 server 侧 runtime 已全验**:edge 部署生产(版本 4f90f3f8),用 admin generate_link+verify 拿真 JWT 打线上端点——`/v1/conversations`(冷回填返列表)、`/v1/messages/tail`(冷回填返消息+授权门放行属主)、**授权门 fail-closed 打别人会话→403**、delta(since+epoch 空增量 / 陈旧 epoch→full)、`/v1/models` cf-cache(300)、`/v1/me/account-deletion` request+cancel,全过。**并发现+修复一个真 bug**:非法 sentiment 原冒 500,改 zod 枚举→400(已复验)。**仅剩 app 首屏可视渲染**——需登录态新版 app,而模拟器登录被 CAPTCHA/Apple/OTP 挡死、无自主登录路,只能用户真账号设备做。task #262 in_progress、#265 收窄到 app 可视）

### 🟡 Langfuse prompt 分发的已知取舍（真源切 Langfuse + KV，弃用 bundled .md）
- **发现**: 2026-06-06 · chore/prompt-langfuse-kv
- **位置**: `apps/edge/src/llm/prompt-loader.ts` · `routes/langfuse-prompts.ts`（webhook）· `PROMPTS_KV`
- **问题**: prompt 真源从 bundled `.md` 迁到 Langfuse，运行时经 `PROMPTS_KV` 分发（webhook 推 + pull-on-miss），删了 `.md` 兜底、改 fail-loud。几个明知的尾巴：① **prompt 后端成硬依赖**——Langfuse keys 未配且 KV 空时 `getPrompt` 抛错（LLM 调用 5xx），无 kill-switch（`LANGFUSE_ENABLED` 现在只 gate trace 上报，不再 gate prompt 读取）；② **KV 无 TTL**——webhook 漏了某次更新则 KV 永久 stale（直到 isolate 重启或手动 `invalidatePromptCache`/重灌），`pull-on-miss` 只在 KV 完全无此 key 时触发；③ **webhook 无 version guard**——只认含 `production` label 的事件、正常 label 移动不回退，但乱序投递理论上可写旧版本；④ **发布非全网瞬时一致**——每 isolate 30s 内存 TTL + KV 最终一致传播。另：删 `.md` + Text rule 后 `wrangler deploy --dry-run` 因容器需 Docker（本地未跑）未端到端验证，JS bundle 正确性由 typecheck + 零 `.md` import + 512 vitest 保证。
- **影响**: pre-launch 单人、无真实用户，全部可接受（用户明确「空了就空了、不管中途可用性」）。有真实流量后：①是可用性单点（Langfuse/KV 故障 = prompt 不可用），②可能让线上静默跑陈旧 prompt。
- **建议**: 上线前评估：KV value 加长 TTL（如 6h）作 webhook 漏更新的兜底定期校准；webhook 加 version guard（KV 现有 version 更高则忽略）；或 cron 定期从 Langfuse 重新 seeding KV。
- **状态**: 待办（pre-launch 接受现状）

### 🟡 PendingCrew runner 生终端化 Phase 1 的尾巴
- **发现**: 2026-06-04 · feat/pendingcrew-runner-backends（runner 改内嵌真终端 Phase 1）
- **位置**: `apps/pendingcrew/Sources/Mac/{LocalRunner/AgentTerminalSession.swift, Views/{AgentTerminalView,CrewSessionWindowView}.swift, Services/CrewSessionRunner.swift}`
- **背景**: runner 从一次性 `claude --print`/`codex exec --json` 改成 SwiftTerm `LocalProcessTerminalView` 内嵌交互式 CLI（自动审批 `--dangerously-skip-permissions` / `-a never`），保订阅计费 + 完整交互。spec/plan 见 `docs/superpowers/{specs,plans}/2026-06-04-pendingcrew-runner-*`。Phase 1 只本机闭环。
- **遗留**:
  1. **跨端"看 agent 输出内容"降级**：拔掉了结构化 `RunnerEvent` 推送（旧路径没人验证过、按用户授权干净拔）。远端仍能**控**（命令），但**看不到 agent 具体输出**——待 Phase 2 把 PTY 当 SSH 式字节隧道补回（spec §5）。
  2. **首条 prompt 注入用固定 sleep**（`CrewSessionWindowView.swift` 0.6s/4s）等终端 REPL 启动——脆。正解=检测终端就绪（prompt 锚点）再注入。
  3. **自动审批=放权**：全自动跑 coding agent 有误删风险；靠工作目录 git worktree 隔离 + 真终端可人工介入兜底。
  4. **CLI flag 漂移**：claude/codex 自动审批 flag 写死，升级改名会启动失败——应 fail-loud。
  5. `PendingCrewAPI.appendSessionEvent` 现 caller-less，留作 Phase 2 复用；不用则删。
- **状态**: 待办（Phase 2 隧道补 #1）。**Phase 1 像素级真验未做**——需用户本机 claude/codex 登录态起 app 验终端托管/注入/交互。

### 🟡 captain `recruit_temp_bot` 招的 ephemeral_bot 暂无消费方 — ✅ 已解决/作废 2026-06-16
- **发现**: 2026-06-05 · feat/crew-captain-orchestration（captain 工具补全）
- **位置**: `apps/edge/src/lib/bot-reply/tools/recruit-temp-bot.ts`（写 `temporary_group_members.member_kind='ephemeral_bot'` + `ephemeral_spec`）
- **问题**: 工具结构上对（无触发器、service-role insert 安全），但招进来的 ephemeral_bot 行**没有任何 edge / iOS 代码读或渲染**——`ephemeral_bot`/`ephemeral_spec` 目前只出现在生成的 schema.ts。即招了也不会在花名册显示、更不会在群里发言/被唤醒。
- **影响**: `recruit_temp_bot` 当前是"结构有效但端到端无效"的半截工具。captain 调它不会出错，但临时 bot 不会真的参与。
- **建议**: 要让它端到端可用，需补：① 花名册渲染 ephemeral_bot 成员；② 一条让 ephemeral 参与者能被唤醒发言的 turn 路径（类似 captain dispatch）。归 captain 编排后续 + T5.3。
- **状态**: ✅ 已解决/作废（2026-06-16 · 审计 R1 把 edge bot-当-captain 编排面整套退役，`recruit_temp_bot` 工具随之删除）。2026-06-16 复核：`apps/edge/src/lib/bot-reply/tools/recruit-temp-bot.ts` 文件已不存在、`recruit_temp_bot`/`recruitTempBot` 在 edge src **零命中**。消费方无需再建（工具本身没了）；captain=本地 session 模型下不走这条 edge 招募路径。

### 🟡 normalize_email 双实现（SQL + TS）须手动保持同步
- **发现**: 2026-06-04 · fix/billing-tails-email-norm（#252 email 规范化）
- **位置**: `pendingbot.normalize_email`（迁移 20260604102812）+ `apps/edge/src/lib/billing-grant.ts:normalizeEmail()`
- **问题**: 同一套规范化规则（lowercase / 去 `+tag` / gmail 去点统域）在 SQL 和 TS 各写一遍。实际跑 welcome-bonus dedup 的是 **TS 版**；SQL 版供未来 DB 侧 hook/对账。两者漂移会出现"DB 认为不同、edge 认为相同"的 Sybil 判定缺口。
- **影响**: 规则演进（新增某大邮箱商别名规则）时漏改一边 → 防薅羊毛静默漏判。
- **建议**: 长期收敛到单一事实源（纯 DB 触发器 或 纯 edge），删另一份；短期两处注释互指（已加）。
- **状态**: 待办

### 🟡 subject_wallets / group_member_billing 物理 drop 卡在多-RPC 重写（#226 尾巴）— ✅ 已解决 2026-06-11（chore/drop-group-billing-tables，#295）
- **解决**: 迁移 `20260611013529` 重写 8 个 live RPC（`open_group_conv`/`bootstrap_user_id`/`group_invite_user`/`group_invite_link_redeem`/`group_join_request_create`/`group_join_request_decide`/`group_remove_member`/`group_set_member_mute`）去掉死表读写 → `DROP TABLE group_member_billing` + drop `group_member_invitations.billing_snapshot`/`invitee_participates` 快照列。`subject_wallets` 核实早已不在 live（引用也已清零）。mute 状态收敛到 `conversation_participants.muted`（0045 起本就双写镜像）。edge 删 invite-decide 的 gmb INSERT；iOS 删 per-member freeze 整套 UI（见下条说明）+ GroupSettingsView mute 改读 participant 行 + 本地缓存 v10 迁移删 `frozen` 列。已 db push EU + live introspection 复核（表 0/引用函数 0/快照列 0）+ 建群写路径 smoke 通过。
- **🔴 顺手修掉一个 P0**: live `open_group_conv` 还在 INSERT 已于 20260603112148 drop 的 `group_billing_config` → **2026-06-03 起生产建群（POST /v1/groups）一直是坏的**（42P01），与 `bootstrap_user_id` 同根因（20260604085445 修 signup 时漏了这个函数）。pre-launch 无人建群所以没炸出来。本迁移重写时一并去掉该语句。
- **附带产品面决定（按"基线未验证就大胆重写"口径）**: per-member freeze（`overdrawn`/`frozen_at`、"已达上限"徽章、冻结横幅、composer 锁、消息隐藏）的唯一写入方 `apply_audit_split` 已随 billing-v2 退役删除——纯死状态，iOS 整套 UI 连根移除。新模型的会话级 gate（群钱包 exhausted → `dispatchGroupTurn` no_balance + continue 流）不受影响。**task #291（Mac composer 三横幅）的 freeze 横幅半项随之作废**，只剩 continue/@-mention 两项。
- **发现**: 2026-06-04 · fix/billing-tails-email-norm（#226）
- **原问题**: 旧 per-conversation 分摊退役后这两表已无业务读路径，但仍被一批 live RPC 无脑 INSERT/UPDATE/SELECT，直接 DROP 会断建群/加群/静音；A 段孤儿清理 20260603112148 因此把它们留给 #226。

### 🟡 PendingCrew 群聊 user 作者无法区分是哪个人 — AppModel 不暴露登录 user id — ✅ 已解决 2026-06-05（feat/crew-captain-orchestration）
- **解决**: `GET /v1/me/subject` 新增 `user_id`(device grant → `granted_by_user_id`;user JWT → `c.var.userId`);iOS `UserSubject.userId` 透出,`CrewStore.refreshSubjects` 回填 `AppModel.currentUserId`,`CrewChatView.localUserId` 改指过去。多人 crew 现可区分自己 vs 其他人类。
- **发现**: 2026-06-04 · feat/pendingcrew-chat-align（中栏群聊 UI 对齐，Task 12）
- **位置**: `apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift`（`localUserId` 取 nil）；根因 `apps/pendingcrew/Sources/Stores/AppModel.swift` + `PendingCrewAuthCredential.swift`（只有 `kind`+`token`，opaque `pdg_` device-grant，无 user id）
- **问题**: 新群聊行 `CrewSenderResolver.resolve(...)` 设计支持用 `sender_user_id == localUserId` 区分"我"vs 其他人类成员（左右对齐 + 头像）。但 PendingCrew 的 `AppModel` 没暴露当前登录 user 的 id（device-grant token 不可解出 sub），故 `localUserId` 只能传 nil → **所有 `user` 作者一律落"我"/右对齐**。
- **影响**: BYOK 单人场景**正确**（就一个 human）；但 crew 里有多个真人成员时，别人发的话也会显示成"我"右对齐、不显头像/名字——多人群里人类作者归属错。edge 已把 `sender_user_id` 透出（白板序列化），缺口纯在客户端拿不到本地 user id。
- **建议**: 让 `AppModel` 暴露 `currentUserId`（device-grant 换 token 时一并取/存 user id，或加一个 `/me` 拉一次缓存），再把 `CrewChatView.localUserId` 指过去即可——解析逻辑已就位。
- **状态**: ✅ 已解决（走 `/v1/me/subject` 的 `user_id` 通道,best-effort 在 refreshSubjects 时回填）

### 🟢 bi_ro BI 角色读不了 RLS 受限表 — ✅ 已解决 2026-06-04（#246：security-definer 视图全覆盖 bi_cost_by_category/bi_subjects/bi_group_pool_*；角色已正名 bi_ro）
- **发现**: 2026-06-03 · chore/dashboard-sql-repoint（#238 看板重指 Polar schema）
- **位置**: `supabase/migrations/20260602051354_metabase_readonly_role.sql`（角色 NOBYPASSRLS + 无函数 EXECUTE）;受影响表 `group_pledges`/`group_pools`/`group_contributions`/`bots`/`group_join_requests` 的成员域 RLS policy
- **问题**: `bi_ro`（Grafana Postgres 数据源连接角色，pooler 形式 `bi_ro.<ref>`）是 NOBYPASSRLS,且没有 grant 任何函数 EXECUTE。这些表的 RLS policy 要么 `TO authenticated`(无 auth.uid() 时 0 行匹配),要么 `USING <fn>(...)` 调 `_grp_caller_role`/`is_bot_invitee`/`is_participant`(角色无 EXECUTE → SELECT 直接 42501 报错)。实测:`group_pools`/`group_contributions` 返回 200 但**永远 0 行**;`group_pledges`/`bots`/`group_join_requests` 直接 **500 permission denied for function**。
- **影响**: 看板 03(群池/认缴/实缴)在补 policy 前**全空或报错**;看板 05 的"创建 bot""加入群"两 stage 也一直报错(早于本次改动、与计费重指无关)。BI"看(只读)和改(可写)分家"的设计在 RLS 表上没打通——只读角色拿不到聚合数据。
- **建议**: 已起草 `supabase/migrations/20260603094114_bi_ro_group_billing_read.sql`(给 bi_ro 在 3 张群计费表加 `FOR SELECT TO bi_ro USING (true)` 的宽松读 policy),但 `db push` 被 auto-mode 当作未授权的生产权限变更拦下,**未 apply**(文件留在主 worktree `/dev` 未跟踪,待用户审阅)。`bots`/`group_join_requests` 同类问题需另起一摊(本任务范围外)。决策口径:要么给 bi_ro 逐表加只读 policy + grant 相关函数 EXECUTE,要么为 BI 单独建 `security definer` 聚合视图。
- **状态**: 待办（看板 SQL 已按真实 schema 写对并重导;数据落地等 RLS 读权限收口）

### 🟡 Mac 端消息历史查询仍是 iOS inline 的手抄复刻（其余 4 条已收口）
- **发现**: 2026-06-03 · feat/t45-ios-viewer（#212 真复用收口）
- **位置**: `apps/pendingbot/Sources/Networking/ChatDataSource.swift:loadMessages`；对照 iOS `Features/Message/ConversationView+Loading.swift:402`（18 列超集 → `Row` → cache）
- **问题**: #212 把 Mac 复刻的查询往「共享 fetch、iOS 也改用」方向收口，**已收口 5 块**：实时通道（`RealtimeManager`/`RealtimeSocket` 去 gate，两端同一条自建 RealtimeHubDO，删了 Mac 轮询）、会话列表（`ConversationFetch.list()`）、bot 好友（`BotContactsFetch.list()`）、人类好友（`ContactsFetch.fetch()` + 中性 `ContactProfile`，iOS `ContactsAPI` 改成映射它）、来信（`EnvelopeFetch.list/get`，`EnvelopeRun` 从 iOS-only 移到共享）—— iOS 缓存/富渲染层叠在共享 fetch 上、Mac 投影薄 summary，查询形状单一来源。**仅剩 1 条仍复刻**：消息历史 —— iOS 是 18 列超集喂 GRDB 缓存 + recall/voice-recap/citations/tool-trace/attachments 派发的重管线（#145-147/#150 验证过的最易碎路径），Mac 是 4 列轻读（id/role/content/message_seq）只渲染纯气泡，两者**合理地不同**，强行统一要么逼 Mac 扛它不渲染的 14 列、要么动那条脆弱管线。
- **影响**: 这条查询形状两边各存一份，列漂移时不会编译报错、只在运行期错——属"复制粘贴而非抽象"。但风险被 Mac 只读核心稳定列（id/role/content/message_seq）压低；真正的根治时机是 Mac 渲染富内容（附件/citations）时，那时 Mac 自然需要 iOS 超集行，顺势抽 `MessagesFetch` 最划算。
- **建议**: 等 Mac 接附件/citations 渲染时，把 `ConversationView+Loading` 的 `Row`+查询抽进共享 `MessagesFetch`（iOS 缓存派发叠在上、Mac 投影），收口时进模拟器验 iOS 不回归。
- **状态**: ✅ **已解决（2026-06-03）** —— Mac 接图片附件渲染时顺势收口:新增 `Networking/MessagesFetch.swift`（`MessageRow` 18 列超集 + `AttachmentRef` 从 iOS-only 移来 + `latest()` + `attachmentMeta()`）;iOS `ConversationView+Loading` 改调它（删局部 Row + 内联 attachments 查询,200 行 dispatch 字节级不变）;Mac `ChatDataSource` 改调 + 投影 + 滤 log/deleted/语音 recap + 解析图片附件。**至此 Mac 5 条查询（会话/bot好友/人类好友/来信/消息）全部两端同一份,零手抄复刻**。两端编译过;iOS 消息列表模拟器冒烟无回归（会话内消息因无 tap 工具未点验,改动逐字搬迁+dispatch 未动,风险极低）。剩余 Mac 缺口:bot/会话/来信头像（数据层补 avatar_path）、非图片附件的 icon+name chip、Mac 全屏看图 viewer。

### 🟡 Mac 聊天附件 / 群聊补全 — 未真机验 + 三处未对齐 iOS
- **发现**: 2026-06-04 · feat/mac-login-align（#212 聊天补全：附件 + 群聊）
- **位置**: `apps/pendingbot/Sources/Mac/Views/MacMessagesView.swift`（MacChatView）；`apps/pendingbot/Sources/Networking/ChatDataSource.swift`（`upload`/`loadGroupSenders`/`conversationType`/`sendPeerMessage`/`sendMessage(attachmentIds:)`）
- **问题**: Mac 端补了图片/文件附件（NSOpenPanel → 复用跨平台 `/v1/upload`）+ 群聊渲染（发送者抬头 + 按 type 路由发送：user_bot/self/group 走 SSE，user_user 直插 Supabase）。双端编译过，但**只做了编译校验，没进真机/真账号验**：附件上传回合、群消息收发、user_user 直插的 canonical realtime 行回填都是写操作回合，headless build 回落 ad-hoc 签名跑不了登录态，需 Xcode GUI 构建 + 真账号点验。三处刻意**未对齐 iOS**：(1) 上传图片**无客户端压缩**——iOS `encodeImageForUpload` 把库内 HEIC/大图降到 2048px JPEG，Mac 直传原图（大图慢 + 可能超 vision 内联上限，bot 看不到图但 chip 仍在）；(2) **无 @提及**（iOS 这块也未定型，本轮明确不做）；(3) **无附件全屏查看器**（iOS 有 `ImageViewer` 但 iOS-only，Mac 点图不放大）。另外群发送者 `loadGroupSenders` 无本地缓存预热（iOS 有 GRDB `hydrateGroupSendersFromCache` 先画再网络刷新），Mac 首帧群抬头会闪一下 seed 头像再补真名。
- **影响**: 中。附件/群聊的"骨架可用"已具备且复用经验证的后端通道，但 (a) 整条写路径未真机验，(b) 无图片压缩在弱网/大图下体验差且可能触发"上传了但 bot 看不见"的隐性失败。
- **建议**: 真机验三条写回合（附件发送、群收发、user_user 1:1）；把 iOS `encodeImageForUpload` 的 2048px JPEG 压缩抽成跨平台 helper（用 `PlatformImage` / CoreGraphics，避开 UIKit），Mac 上传图片前走它；@提及 / 全屏看图待 iOS 这两块定型后再镜像。
- **状态**: 待真机验 + 三处对齐缺口未补

## 🔴 根基级

### 🔴 Bot 公开分享链路被 `bots` 表 RLS 堵死 — 陌生人扫码/点链接解析 public_invite bot 命中 0 行
- **发现**: 2026-06-01 · chore/progress-ledger（对账 task #121-128 时实测）
- **位置**: `supabase/migrations/20260527091508_drop_public_open_visibility.sql:56`（`bots_visible_read` policy）、`supabase/migrations/0022_fix_bots_rls_recursion.sql:15`（`is_bot_invitee`）、`apps/pendingbot/Sources/Features/Friends/FriendsTabView.swift:1944`（`runLookup` 直查 supabase）
- **问题**: bot 分享功能（slug / 二维码 / Universal Link，task #121-128）代码已几乎全做完且提交，但 iOS 解析 slug 是**直接查 Supabase** `bots` 表、靠 RLS 控可见性。唯一的 SELECT policy `bots_visible_read` 对 `public_invite` bot 要求 `is_bot_invitee(id, auth.uid())` —— 而该函数只在 `bot_invites` 表有预先邀请行时为真（邀请只能由 bot 主人按 handle 主动塞）。陌生人扫码/点分享链接时**还不是被邀请人** → SELECT 命中 0 行 → iOS 显示"找不到这个机器人,或者它不允许你加入"。
- **影响**: 整个分享链路（slug→二维码→扫码→universal link→AddBotPreviewPage）对"非预先邀请者"全部走不通 —— 而分享功能的**全部意义**就是给陌生人加。UI 文案还写着"别人按这个标识、链接或二维码加你的机器人",与 RLS 实际行为直接矛盾。这是个"iOS+edge 表层都做了、DB 授权层没跟上"导致的 ship 即坏缺口。edge 侧也确认没有任何按 slug 解析 bot 的路由（纯靠 client 直查）。
- **建议**: 二选一：(a) 放宽 `bots_visible_read`，让 `visibility='public_invite'` 对所有 authenticated 可 SELECT（public 的本意就是可被发现自加）；(b) 加一个 service-role 的 `GET /b/:slug` 解析端点，绕开 client 直查 + RLS。改完跑 #128 验证（含真机扫码闭环），通后翻 #121-128 状态。注意 `is_bot_invitee` 的"单向门"语义要和 spec `project_bot_visibility` 对齐确认。
- **状态**: ✅ **已解决/被取代（2026-06-03 核实）** —— 旧的「client 直查 bots 表靠 RLS」分享路径已被**邀请链接模型**(decisions.md D1，task #191-194)整体取代：`bot_invite_links` 表 + `apps/edge/src/routes/bot-invites.ts` 的 `GET /v1/bot-invites/:token`(service-role RPC `bot_invite_link_resolve` 预览) + `POST /:token/redeem`(`bot_invite_link_redeem` 授予)。iOS 走 `resolveBotInvite`/`redeemBotInvite` 经 worker，**不再 client 直查 bots 表**，所以 RLS 堵死的结构性病根消失(redeem 由 service-role 写，bots/user_bot_contacts RLS 保持严格)。注:这是「结构性 blocker 消失」，完整的陌生人扫码闭环真机 QA 仍未单独跑(并入分享功能整体验证)。

### 🔴 PendingBot Mac 端业务接入只覆盖 5 tab 中的 1 个,其余仍是 placeholder — ✅ 已解决/被取代 2026-06-09
- **发现**: 2026-05-29 · feat/mac-multiplat-t01-p0(worktree wf_bb2bdb07-141-5)
- **位置**: `apps/pendingbot/Sources/Mac/MacRootView.swift`、`apps/pendingbot/Sources/Features/**`、`apps/pendingbot/project.yml`
- **问题**: T0.1 P0 把 `project.yml` 里的 `EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]` 大锅排除摘掉了,改用 `#if os(iOS) ... #endif` 包住每个 iOS-only 文件。但实际包了 `Sources/Components/*` + `Sources/Features/*` 整两层目录(再加 Networking 里 7 个文件),原因是这些目录里的 UI 类全部转性依赖 UIKit / PushKit / CallKit / Theme(UIColor) / Haptics(UIKit)。Mac build 现在能过,但能拿来用的 Mac 真实视图只有 `MacMeView`(账号信息 + 退出登录),消息 / 好友 / Crew / 来信 4 个 tab 仍是 `MacTabPlaceholder`。
- **影响**: 用户在 Mac 端只能看自己账号 + 登出,看不到任何聊天、好友、Crew、来信内容 — Mac 端基本不可用。后续 T0.1 P1+P2 真正接业务时,要把 iOS 业务里 UIKit-tied 的小部件抽成 cross-platform 等价物(`UIImage`→`Image+platform helper`、`UIPasteboard`→`NSPasteboard`、`Haptics`→Mac noop、`UIViewRepresentable` 桥不能用要找 SwiftUI 等价或 Mac-only 重写),工作量按文件数估在 30+ 文件级别;短期不可能"开关一拨就好"。
- **建议**: T0.1 P1 — 先把 Models / Storage / Networking 里已 cross-platform 的部分往上抽通用 `Theme` / `PlatformColor` / `PlatformImage` 抽象层,让 `Sources/Components/` 里小部件(`UserAvatar` / `BotAvatar` / `Theme` / `Haptics` / `Platform` / `RelativeMessageTime` / `EmptyHint`)能不带 `#if os(iOS)` 编译过 Mac;T0.1 P2 — 接 `MessageTabView` 等价物(读 supabase `conversations` + 走 `ChatStream` 已是纯 Foundation),把"消息" tab 做出来。Crew / Call 强依赖 PushKit/CallKit 的,Mac 端等 v2 再说。
- **状态**: ✅ 已解决/被取代（2026-06-09 · 被 `feat/tri-platform-ui` 彻底版整体取代，合 main `b4d0b131` —— 五个 tab 全部 conform 共享 `FeatureSurface` 渲染，`WideRootView` 内零 Mac 平行列，详见本文件「🔴 `Features/*` 被无谓 `#if os(iOS)` 一刀切」条的处置记录）。2026-06-16 复核：`apps/pendingbot/Sources/Mac/` 只剩 `MacWelcomeView.swift`（登录壳），4 个 `MacTabPlaceholder` 已不存在。剩余仅 Phase 7 三端真机/模拟器可视验证（task #290）+ 个别降级项（Mac composer 两横幅 #291 / 二维码名片 #292）。原"部分完成 · P1 好友 tab"描述以此失效。

### ✅ Apple IAP JWS 验证未实现 — IAP 路由当前 fail-closed
- **发现**: 2026-05-29 · feat/billing-v2-webhooks
- **位置**: `apps/edge/src/lib/billing-v2-iap.ts:verifyAppleJws`
- **问题**: `/v1/billing/iap/purchase` 和 `/v1/billing/iap/notify` 已经接入了数据流（idempotency、pack 发放、refund_events、handler 分发），但 JWS 签名校验函数直接 `throw new Error('apple_jws_verification_not_implemented')`，所有 Apple 路径目前返回 501。原因：Workers 没有内置 X.509 解析，要实现 Apple ASN V2 完整链验证需要手写 ASN.1/DER 解码 + ECDSA P-256 链验证 + Apple Root CA G2/G3 指纹固定化，工作量不小。
- **影响**: 上 iOS IAP 之前必须先解决，否则要么 Apple 充值彻底跑不通、要么用环境变量 bypass 验证（已被显式拒绝写入代码以避免静默旁路）。Lemon Squeezy（HMAC-SHA256）已完整实现，所以上架顺序可以先 LS / Web、再补 Apple。
- **建议**: 实现路径已写在 `verifyAppleJws` 函数注释里：(1) 解 JWS header.x5c → 3 张 DER cert；(2) ASN.1 解 X.509 取 SPKI + issuer；(3) 链验证（leaf signed by intermediate, intermediate by root, ECDSA-P256）；(4) Root SHA-256 比对 Apple Root CA G2 / G3 内嵌指纹；(5) 校验 NotBefore/NotAfter；(6) importKey('spki', leaf.spki, 'ECDSA P-256') + verify on signing input；(7) 校验 `iss==='Apple Inc.'` 和 `bundleId === env.APPLE_IAP_BUNDLE_ID`。落地后，本文件这条状态置为已解决。
- **状态**: ✅ 已修复（2026-05-30 · 零依赖手写 DER/ASN.1。新增 `apps/edge/src/lib/billing-v2-iap-verify.ts`：`verifyAppleJwsChain` 做 x5c 链解码 → 每张 cert 解析（SPKI/validity/ECDSA 签名 DER→JOSE raw）→ **Apple Root CA G3 SHA-256 根固定**（常量已用 openssl 双工具核对官方 cert）→ validity 窗口 → 链验证（leaf←intermediate←root + root 自签）→ SubtleCrypto ES256 验 `header.payload` → decode payload。`verifyAppleJws` 改为调它 + `bundleId===env.APPLE_IAP_BUNDLE_ID` 断言，函数签名不变、三个 caller 零改动。单测 `billing-v2-iap.test.ts` 用 SubtleCrypto 现造 P-256 三级链 + DER builder，覆盖 happy/篡改/错根/断链/过期/非ES256/默认pin拒自签根/签名输入字节——14 测全绿，typecheck 0 error。**仍待真机**：无真实 Apple sandbox JWS，端到端未跑，首次接 iOS IAP 时需用 sandbox 交易回归一次。）

### 🔴 计费事实源、成本字段和销售 markup 混在旧 credits 框架里 — 🟡 框架已拆/大部分解决 2026-06-16
- **发现**: 2026-05-29 · codex/billing-v2-design
- **位置**: `apps/edge/src/llm/router.ts`、`apps/edge/src/lib/billing.ts`、`apps/edge/src/lib/ai-gateway.ts`、`supabase/migrations/20260514065304_local_cost_billing.sql`、`supabase/migrations/20260516042918_drop_audit_observability.sql`
- **问题**: 现有计费路径把 provider-reported cost、AI Gateway cost、本地价格表估算、voice 本地计算、web tool 成本和 runtime markup 折进 `audit_log.cost_usd` / `tool_cost_usd` / `cost_credits` 这组旧字段里。历史迁移曾把 `cost_usd` 从“provider cost”改成“local pricebook cost”，后续又删掉 `provider_cost_usd` 和 raw model call 表并转向 AI Gateway 作为事实源，导致字段名、注释和实际结算语义互相打架。
- **影响**: 新增服务计费时容易继续塞进 parent audit 单列，无法清楚解释“供应商真实成本、用户扣减单位、销售利润”三者关系；余额门槛也只能用粗糙固定阈值，无法按服务预授权。当前已出现有 token 且 Gateway 有成本但落成 `skipped` 的行，说明计费链路缺少明确的 settling/failure 状态。
- **建议**: 以 `docs/billing-v2-design.md` 为目标态重做：PNC 作为成本单位，`27 PNC = 1 USD`；运行时不加 markup，销售 pack 时加 markup；用 usage events + pack ledger + reserve/settle 替代单列 `cost_credits`；所有 LLM、工具、语音、RealtimeKit、sandbox、存储等变量成本都进入统一 usage event。
- **状态**: 🟡 大部分已解决/演进（旧 credits 框架已拆）。计费已转 **PNC 为成本单位 + 运行时不加 markup + WalletDO 门禁/扣费 + usage 维度**，引擎外包 Polar(钱包/MoR)+RevenueCat(iOS)（见 `project_billing_outsourcing`）。2026-06-16 审计 + 复核佐证：`balance_credits`/`lifetime_topup_credits` 等 v1 credits 列已从 schema drop（schema.ts grep 零命中）、`getMarkup`/`usdToPnd`/`USD_TO_PND`/`DEFAULT_MARKUP` 已删（审计 Y4）、`getBalance`+`/v1/me/balance` 已删（R3）。**剩余尾巴**（见本文件「v1 billing 表 + 死函数留冷备」🟡 条）：`group-billing.ts splitAndDebit`、`balance-cache.ts`、`redemption_codes` 表（`billing_redeem` 仍活）未清；且整套 Polar/RevenueCat 引擎**端到端未验**（pre-launch，计费未开）。原"待办"以此更新。

### 🟡 Sandbox runtime usage_event 暂以 vendor_cost_usd=0 落账
- **发现**: 2026-05-29 · worktree-wf_bb2bdb07-141-3 (#183 billing v2 sandbox 接入)
- **位置**: `apps/edge/src/lib/sandbox.ts` (`runPython`)
- **问题**: billing v2 给 sandbox 加上了 `sandbox_runtime` usage_event 行（记录 elapsed seconds + conversation/owner），但 Cloudflare Sandbox 的 per-second container 价格目前没在 worker 里维护，所以 `vendor_cost_usd` 暂时硬写 0、`cost_source='manual'`。usage_event 行存在、ledger 不扣钱。
- **影响**: pre-launch 没有真实滥用流量，先记录形态再补价格是合理的折中；但发布前必须有真实价目，否则用户跑无限循环代码不计费。同样的 hole 也存在于 storage_transfer / push_delivery，这两类目前完全没接入。
- **建议**: (1) 把 Cloudflare Sandbox 的 container 价格表（memory-seconds + disk + network egress）建成 `sandbox_prices` 表，跟 `web_tool_prices` 同一个模式；(2) `runPython` 里改用真实价目算 `vendor_cost_usd`；(3) 顺手把 R2 上传/下载/转码、APNs 短信/邮件按同样的 usage_event + pricebook 模式补齐。
- **状态**: 部分迁移（2026-06-02 · billing P2 Phase F）。`runPython` 已从旧 billing-v2 `settleUsage(vendor_cost_usd=0)` 改为接 WalletDO（`wallet.gate` 前置门禁 + `wallet.debit('sandbox_runtime')` 后置扣费），不再写 0。但**价格仍是占位**（见下方新条目「sandbox 真实单价 + 计量维度待定」），核心 hole（无真实价目）未关。

### 🔴 Edge 用户态路由里 service-role 鉴权边界过于分散
- **发现**: 2026-05-25 · codex/security-architecture-audit
- **位置**: `apps/edge/src/routes/messages.ts`、`apps/edge/src/routes/groups.ts`、`apps/edge/src/routes/group-voice.ts`、`apps/edge/src/routes/contacts.ts`、`apps/edge/src/routes/friend-requests.ts`
- **问题**: 多个用户可调用的 route 在 `requireSession()` 后直接使用 `serviceClient()` 绕过 RLS，再在 handler 内用本地查询、RPC 或 if 分支证明 membership/admin/owner。单个点大多有检查，但检查语义分散在大文件里，缺少统一的“以用户身份解析资源 + 明确提升到 service-role 写派生状态”的边界。
- **影响**: 越权风险会随功能增长放大：新增分支很容易漏掉某一种 conversation type、subject role、deleted/withdrawn 状态或 billing ownership；审计也只能逐个 handler 追踪，难以证明最小权限。
- **建议**: 收敛出 route 级授权层，例如 `loadConversationForUser`、`requireGroupRole`、`requireSubjectRole`、`withServiceWriteAfterAuthz`，并为每类资源维护一套负向授权测试；优先拆 `messages.ts`、`groups.ts`、`group-voice.ts` 这种 800+ 行入口。
- **状态**: 部分修复（2026-05-25 · 新增 `apps/edge/src/lib/route-authz.ts` 和 `route-authz.test.ts`，`groups.ts` / `group-voice.ts` 的 group conversation、human/bot participant、owner/admin 检查已迁入共享 helper；`contacts.ts` 的 singleton `user_user` 会话查找已收敛到 `findSharedUserUserConversation`，`open-chat` 创建已下沉到带 advisory lock 的 `open_user_user_conv` RPC，防止多设备并发创建重复 1v1 会话；`messages.ts` 的 hard delete 权限已迁入 `authorizeMessageDelete`，recall 权限已迁入 `authorizeMessageRecall`，普通发消息会话/peer-gone 检查已迁入 `authorizeMessageSendConversation`，附件所有权检查已迁入 `authorizeAttachmentOwnership` 并复用于普通发送和首轮 `/messages/start`，并修复“群主硬删别人群消息”的越权边界；`friend-requests.ts` 的 peer-id 加好友必须带 source group 并验证双方同群；`messages.ts` normal send / regenerate 共用 `authorizeBotUse`，修复 regenerate 漏掉 revoked `public_invite` 复核的问题；runner host 执行面已收敛为 device-grant only，旧 user-JWT runner register/heartbeat/claim/event/finish RPC 从 authenticated 撤权；`messages.ts` 三条 bot turn 路径的 pinned model / arena random routing 已收敛到 `resolveMessageBotTurnRoute`，余额 402 payload 与 auto-lookback parent lookup 已抽成本地 helper。剩余主要是继续把普通发送 Phase 2 前置阶段拆成更小的可测试 primitive。）

### 🔴 线上 `pendingbot` exposed schema 有 `SECURITY DEFINER` 函数对 anon 可执行
- **发现**: 2026-05-24 · codex/security-architecture-audit
- **位置**: supabase/migrations/0033_billing.sql、supabase/migrations/0034_billing_admin_rpcs.sql、Supabase live advisors
- **问题**: 线上库里多组 `SECURITY DEFINER` 函数在暴露给 PostgREST 的 `pendingbot` schema 下仍允许 `anon`/`authenticated` 执行，包括 `billing_admin_grant`、`billing_credit`、`billing_debit`、`billing_issue_codes`、`start_user_bot_turn`、`open_self_conv` 等。Supabase advisor 和 `has_function_privilege()` 查询都确认这不是静态误报。
- **影响**: 任何漏掉内部鉴权的 definer RPC 都会绕过 RLS 直接以 owner 权限写账本、开会话或改业务状态；这违反最小权限原则，是计费和越权面的最高优先级风险。
- **建议**: 新增权限收敛迁移：先 `REVOKE EXECUTE ON FUNCTION ... FROM PUBLIC, anon, authenticated`，只给确需客户端调用的 RPC 授权；内部/触发器/worker-only 函数移到未暴露 schema 或仅授予 `service_role`；同时为 definer 函数固定 `search_path` 并跑 Supabase security advisors 验证清零。
- **状态**: 已修复（2026-05-25 · 新增 `20260524175632_harden_function_execute_privileges.sql`，默认撤销 exposed schemas 的函数执行权，仅给客户端必需 RPC 重新授权，billing/bootstrap/trigger/internal 函数仅保留 `service_role`。仍需部署后跑 Supabase advisor 复核现网。）

### ✅ 设备授权审批可由客户端请求体放大 scope
- **发现**: 2026-05-24 · codex/security-architecture-audit
- **位置**: apps/edge/src/routes/device-login.ts:52、apps/edge/src/routes/device-login.ts:237、apps/edge/src/lib/device-grants.ts:83、supabase/migrations/20260524122559_subject_device_login_grants.sql
- **问题**: `/device-login/challenges/:id/approve` 只按 `grantKind` 调 `subject_can_authorize_device_grant`，但最终写入的 `requested_scopes` 直接来自 approve 请求体。`pendingcrew_control` 这类授权通过后，客户端仍可提交 `runner:write` / `runner:read`，后续 `requireSubjectAuth()` 只信任 grant row 的 scopes。
- **影响**: 用户只具备 crew 控制能力时，可能铸出 runner 能力 token，越过 `subject_can_manage_runners` 的意图边界。
- **建议**: 服务端按 `grantKind` 和 subject role 派生允许的 scope 集合，拒绝任何超集；或把 scope 校验下沉到 `subject_can_authorize_device_grant` / consume RPC，保证数据库里永远不会落入过宽 grant。
- **状态**: 已修复（2026-05-25 · `device-login.ts` 按 `grantKind` 限制 scope，且批准 scope 必须是原 challenge 请求 scope 的子集；`device-login.test.ts` 覆盖 control grant 不能带 runner scope、app/grant mismatch、consume 后 token scope。）

### 🔴 群聊计费跳过用户后没有落库排除状态
- **发现**: 2026-05-24 · codex/security-architecture-audit
- **位置**: apps/edge/src/lib/group-billing.ts:17、apps/edge/src/lib/group-billing.ts:183、supabase/migrations/0045_group_chat_rpcs.sql:1046、supabase/migrations/0066_group_member_freeze_and_default_handle.sql
- **问题**: 初次审计只看了 0045 里的旧函数体，那里 `apply_audit_split` 确实只在 `debited` 时更新 `group_member_billing`；但后续 0066 已用 `CREATE OR REPLACE FUNCTION` 覆盖该函数，并在 `skipped_overdrawn` / `skipped_capped` 时设置 `overdrawn=true`。
- **影响**: 已核实线上函数体包含 skipped 分支，当前不再是 live 风险；保留该条作为“旧函数体容易误判/回归”的历史记录。
- **建议**: 保留回归测试覆盖“迁移历史最终函数体包含 skipped 状态处理”，后续如果重写 `apply_audit_split` 必须同时保留这个分支。
- **状态**: 已解决（0066 已覆盖；2026-05-25 线上 `pg_get_functiondef` 确认）

### ✅ 附件 RLS 与 Worker 下载口径不一致，可能泄露附件元数据
- **发现**: 2026-05-24 · codex/security-architecture-audit
- **位置**: apps/edge/src/routes/upload.ts:331、supabase/migrations/0063_attachments_rls_avatar_visibility.sql:18
- **问题**: Worker 下载路径要求“上传者或当前参与者且存在未删除消息引用该附件”，但最新附件 RLS 允许任意当前会话参与者按 `attachments.conversation_id` 读取 attachment 行，和消息引用/删除状态无关。
- **影响**: 直接 PostgREST 读取可能暴露附件文件名、mime、大小、摘要、tags、`r2_key` 等元数据；消息撤回/删除后 raw bytes 仍由 Worker 挡住，但 DB 元数据隐私语义已经漂移。
- **建议**: 恢复 chat attachment 的 DB 读取为 uploader-only 或基于未删除 message reference 的 policy；头像可拆独立公开字段/头像表，不要把头像例外扩大到所有 conversation-bound 附件。
- **状态**: 已修复（2026-05-25 · `20260524175919_tighten_attachment_read_policy.sql` 将 DB metadata SELECT 收敛到 uploader、头像引用、或当前参与者可见的未删除消息引用；`migrations-security.test.ts` 覆盖 message reference / non-deleted / participant 条件。仍需部署后复核现网 policy。）

### ✅ Crew / 临时群 subject 钱包尚未接入 LLM 审计扣费分支
- **发现**: 2026-05-24 · codex/security-architecture-audit
- **位置**: apps/edge/src/llm/router.ts:386、docs/superpowers/specs/2026-05-24-crew-temporary-groups-design.md
- **问题**: 审计扣费当前只识别 `conversation_type = 'group'` 走 split，或 `opts.userId` 走单用户扣费；`temporary_group` / `crew` 的 `responsible_subject_id` 与 `billing_debit_subject` 尚未进入统一 audit billing 分支。
- **影响**: 如果 Crew / 临时群的模型或工具调用只带 `conversationId` 而不带 `userId`，初始状态会落到 `free`；如果临时补传某个人类 `userId`，又会绕过 subject wallet 的责任主体设计。
- **建议**: audit 层解析 billable subject：1v1 user、普通群 split、Crew/临时群 responsible subject 三类互斥；账本行记录 subject snapshot，避免以后靠调用方散落传参兜底。
- **状态**: 已修复（2026-05-25 · `apps/edge/src/llm/router.ts` 现在按 conversation type 解析 group split / responsible subject / legacy user；Crew 与临时群走 `billing_debit_subject`，audit metadata 记录 billing target。）

### ✅ definer helper 可被直接 RPC 传入别人的 user id 做关系探测
- **发现**: 2026-05-25 · codex/security-architecture-audit
- **位置**: `subject_has_user_access`、`subject_user_has_role`、`subject_can_authorize_device_grant`、Crew/runner/temporary-group view helpers
- **问题**: 这些函数为了给 RLS policy 使用而授予 authenticated 执行权；policy 里传的是 `auth.uid()`，但直接 `/rpc` 调用可传入任意 `p_user_id`，从而探测别人是否能看某个 subject / crew / runner 资源。
- **影响**: 不直接泄露业务行内容，但泄露成员关系、权限关系和资源存在性；如果后续 helper 扩展返回更细信息，风险会放大。
- **建议**: helper 内部绑定调用者：service_role 允许显式 user id；普通 authenticated 调用必须满足 `p_user_id = auth.uid()`。
- **状态**: 已修复（2026-05-25 · `20260524180643_bind_definer_helpers_to_auth_uid.sql`）

### ✅ legacy helper / trigger 函数缺少固定 search_path
- **发现**: 2026-05-25 · codex/security-architecture-audit
- **位置**: `uuidv7`、preset handle helpers、`bootstrap_new_user_trigger`、group billing freeze trigger 等 Supabase advisor 报告项
- **问题**: 部分早期函数没有 `SET search_path`，执行时受 role-level search_path 影响。
- **影响**: 对 definer/trigger 函数来说这是对象解析劫持面；当前多数函数体已 schema-qualified，但 advisor 仍会持续报警，且未来函数体改动容易踩坑。
- **建议**: 对存量函数统一 `ALTER FUNCTION ... SET search_path`，新函数默认在定义里写死 search_path。
- **状态**: 已修复（2026-05-25 · `20260524181807_pin_legacy_function_search_path.sql`）

### ✅ Realtime metering 诊断日志记录了完整上游 session 事件
- **发现**: 2026-05-25 · codex/security-architecture-audit
- **位置**: `apps/edge/src/durable-objects/realtime-meter.ts`
- **问题**: `session.created` / `session.updated` 事件被 `JSON.stringify(msg)` 后写入日志；这些事件可能包含由机器人记忆、备注、技能和会话上下文拼出的 realtime instructions。
- **影响**: Cloudflare logs / `wrangler tail` 可能暴露用户私密上下文或机器人内部提示词；这属于排障便利性覆盖隐私边界。
- **建议**: 语音/模型上游事件日志只允许字段白名单；需要调试 payload 时走短期、显式、脱敏的诊断开关。
- **状态**: 已修复（2026-05-25 · RealtimeMeter 只记录事件类型、session id、model、错误 code/type，并新增 `privacy-logging.test.ts` 防止整包日志回归。）

## 🟡 拆东墙补西墙

### 🟡 Mac 端整体业务子树被 build settings 排除，三端 IM 实质上还是 iOS-only
- **发现**: 2026-05-29 · feat/mac-3col-shell
- **位置**: `apps/pendingbot/project.yml`（`EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]`：`Components/* Features/* Models/* Networking/* Storage/*`）、`apps/pendingbot/Sources/Mac/MacRootView.swift`、`apps/pendingbot/Sources/Features/Message/*`（顶层 `import UIKit` + `UIViewRepresentable` + `UIImagePickerController` + `UIScreen.main`，无 `#if os(iOS)` 门）
- **问题**: spec v2 §11 三端齐目标要求 Mac 端跑通普通 IM，但当前为了让 Mac 能 build，`project.yml` 一刀把 `Features/ Components/ Models/ Networking/ Storage/` 整个子树从 macOS target 排除。`MacRootView` 因此只能渲染纯占位 3 列 shell（sidebar/list/detail 都是空态文案）——没有 `AccountStore`、没有 `APIClient`、没有任何会话或好友数据可读。Features/Message 那一堆（`ConversationView`、`BubbleView`、`ComposerView`、`ChatComposerAccessory`、`ChatActionSheet`、`MessageTabView`）也都顶层 `import UIKit`,直接共用要 (a) 在几十个文件里加 `#if os(iOS)` 门 + Mac 替代实现 (b) 把 UIKit 部分下沉到一个 iOS-only Components 层。
- **影响**: Mac 端会一直停在"空壳"阶段——每加一个 Mac 业务功能，都要先拆一刀 UIKit 门或者整段重写跨平台版。任由它发展，最终会形成"iOS 业务代码 + Mac 重写"两套并行实现的根基级分裂；T4.6 Crew Tab V2 多端方案能成立，是因为 Crew 一开始就走 SwiftUI-only。普通 IM 这块没有同样的预算，相当于 spec §11 三端齐目标被偷偷降级成"iOS+iPad 齐,Mac 占位"。
- **建议**: 接 Mac IM 之前必须先做一次跨平台抽层，至少这几步：(1) 把 `Models/`、`Storage/AccountStore`、`Storage/UnreadStore`、`Networking/APIClient`、`Networking/RealtimeManager` 等纯 Foundation 模块从 macOS 的 EXCLUDED 列表里拿出来（这些文件已经不 import UIKit）；(2) `Features/Message/*` 里 UIViewRepresentable 子组件抽进 `Components/iOS/` 子目录,顶层 view 用 `#if os(iOS)` / `#if os(macOS)` 各跑一份；(3) 写明哪些 iOS-only 能力（CallKit/PushKit/相机/UIImage 编码）在 Mac 上的对应方案（不做 / NSImage / 文件选择器）。短期不要为了多接一个 tab 而随手加 `#if`，会让以后真正拆层时阻力越大。
- **状态**: 待办（T1.4 stream 升级 Mac shell 到三列结构,但中间和右栏仍是 placeholder；真正的 Mac IM 接入留给后续 Phase 2+ stream）

### 🟡 通话内 voice_cost 实时预览还在用 v1 PND markup（与 v2 PNC 钱包单位不一致）
- **发现**: 2026-05-29 · feat/billing-v2-cutover
- **位置**: `apps/edge/src/lib/voice-metering.ts:broadcastVoiceCostPreview`（getMarkup + usdToPnd）、`apps/edge/src/durable-objects/room-voice.ts:broadcastCost`、iOS `RealtimeSocket`/`Manager` 的 `voice_cost` 处理（`delta_pnd`/`cumulative_pnd` 字段）
- **问题**: billing v2 cutover 后，权威扣费已全部走 v2 PNC（settleUsage）。但通话过程中给客户端广播的"本次通话已花费"实时预览仍走 v1 路径：`getMarkup(billing_config.markup) × usdToPnd`，单位是 PND ∂，字段名 `delta_pnd`/`cumulative_pnd`。用户在通话里看到 ∂ 估算，挂断后进钱包看到的是 PNC——单位对不上。
- **影响**: 纯展示层不一致，不影响真实扣费（扣费已是 v2 权威）。但用户体验割裂；且这是 billing.ts 里 getMarkup/usdToPnd 仅剩的运行时调用点，挡着把这两个 v1 函数彻底删掉。
- **建议**: 把广播改成 PNC：`usdToPncMicros(costUsd)` 累加，字段改 `delta_pnc_micros`/`cumulative_pnc_micros`，iOS voice_cost 处理同步改单位 + 文案。改完即可从 billing.ts 删 getMarkup/usdToPnd。
- **状态**: ✅ 已解决（2026-06-16，审计 Y4，merge `4e74e093`）—— 广播改 `usdToPncMicros` + `delta_pnc_micros`/`cumulative_pnc_micros`，iOS 同步改解码 + `WalletV2Format.formatPnc` 显示；markup 函数族 getMarkup/usdToPnd/USD_TO_PND/DEFAULT_MARKUP 已从 billing.ts 删除。端到端真验（通话中显示）待真流量。

### 🟡 v1 billing 表 + 死函数在 cutover 后留作冷备，未删
- **发现**: 2026-05-29 · feat/billing-v2-cutover
- **位置**: `users.balance_credits` / `subject_wallets` / `billing_ledger` / `topups` / `redemption_codes` / `group_member_billing` 表；`apps/edge/src/lib/billing.ts`（getBalance/getMarkup/usdToPnd/billingDebit/billingDebitSubject/getThreshold 等）、`apps/edge/src/lib/group-billing.ts`（splitAndDebit 整文件）
- **问题**: billing v2 cutover 让 v2 成为权威，v1 的扣费/gate 逻辑已不再被运行时调用（gate 已改读 v2 packs，debit 已改 settleUsage）。但 v1 的表和一批导出函数留着没删——作为一个周期的冷备，万一迁移有遗漏可回查。`/v1/me/balance`、`/v1/me/redeem`、`group-billing.ts`、`billing.ts` 的大部分导出现在是死代码（仅被自己的单测引用）。
- **影响**: 死代码 + 未用表，读代码时容易误以为还在用 v1；balance-cache.ts 的 KV 缓存也不再被写。不致命，但要在 v2 线上跑稳一个周期后清掉。
- **建议**: 跑稳后开 chore 分支：删 group-billing.ts、billing.ts 里 v1-only 导出、/me/balance + /me/redeem（或改 redeem 走 v2 issuePack）、balance-cache.ts；再写一个 drop-v1-tables 迁移（备份后 DROP）。
- **状态**: 🟡 大部分已清（2026-06-16，审计 R3/Y4/Y7）—— `users.balance_credits`/`lifetime_topup_credits`/`lifetime_spent_credits`/`balance_updated_at` + `usage_events` 已 db push drop；`subject_wallets`/`billing_ledger`/`topups`/`group_member_billing` 此前已 drop；billing.ts 的 getBalance（R3）/getMarkup/usdToPnd（Y4）+ `/v1/me/balance`（R3）已删。**剩**：`group-billing.ts splitAndDebit`、`balance-cache.ts`、`redemption_codes` 表（`billing_redeem` 仍用、活）未动。

### 🟡 sandbox / container runtime 没有任何计费路径（v1 + v2 都缺）
- **发现**: 2026-05-29 · feat/billing-v2-services
- **位置**: `apps/edge/src/lib/sandbox.ts`、`apps/edge/src/routes/code-exec.ts`、`docs/billing-v2-design.md` §5 `sandbox_runtime`
- **问题**: billing v2 design §5 把 `sandbox_runtime`（container/runtime 秒数、磁盘、网络）列为应纳入 PNC 账本的成本分类，但 v1 从来没有给 sandbox 计过费，code-exec 工具调用 Cloudflare Sandbox SDK 时不产生任何 usage_event / audit cost。因此 billing v2 dual-write（#183）也无从镜像——没有可镜像的 v1 成本。当前 `dualWriteV2` 只接了 model 成本（llm/voice）和 web_tools。
- **影响**: 沙盒是可被滥用的变量成本（长时间运行的 container、磁盘、egress），目前完全免费。用户可以无限跑 execute_code 不掉余额。pre-launch、单人、沙盒 auto-sleep 的现状下风险有限，但发布前必须补上，否则是一个开口的成本漏洞。
- **建议**: 在 sandbox 生命周期（启动→运行→sleep）打点 container-seconds，按 Cloudflare Sandbox 计价转 `vendor_cost_usd`，走 `settleUsage({category:'sandbox_runtime', quantityUnit:'seconds'})`。design doc §7 要求 sandbox 走周期 settle + 余额 ≤ 0 立即终止容器——这部分要和 sandbox.ts 的 sleepAfter 生命周期一起做。
- **状态**: ✅ 基本闭合（2026-06-02 · billing P2 Phase F）。`runPython` 现在：执行前 `wallet.gate`（`exhausted` 抛 `SandboxGateError`，code-exec 工具转「余额用完」文案，不跑代码）；执行后按 wall-clock 秒数扣 `wallet.debit(category:'sandbox_runtime')`，dedupeId=`sandbox:<conv>:<startedAt>` 幂等。subjectId 复用 router 解析（群/临时群/crew→`responsible_subject_id`，否则发起 userId）。**仍未做**：周期 settle + 余额≤0 中途终止容器（当前最小可用=执行完一次性扣，30s 超时已封顶单次成本，长任务跨多次调用各扣各的，可接受）；真实单价见下条。

### 🟡 sandbox 真实单价 + 计量维度待定（当前 wall-clock × 占位价）
- **发现**: 2026-06-02 · billing P2 Phase F
- **位置**: `apps/edge/src/lib/sandbox.ts`（`SANDBOX_USD_PER_SECOND` 常量）
- **问题**: (1) **单价是占位**——`SANDBOX_USD_PER_SECOND = 0.0001`（≈0.36 USD/h）是随手填的 stand-in，**不是定价决策**。真实数字得从 Cloudflare container 计价（running 态按 provisioned memory+disk 计费）推。(2) **计量维度可能不对**——现在按 **wall-clock 秒** 计，但 Cloudflare 实际按 memory-seconds + disk + egress 计；CPU/内存重的任务和空转任务被同价对待。Sandbox SDK `runCode` 的返回（官方文档核实：`{ code, logs, results, error, executionCount }`）**不含任何时长/资源字段**，所以 worker 侧只能拿 wall-clock，要按内存/CPU 计就得换数据源（容器 DO 自报 or CF 用量 API）。
- **影响**: 占位价上线 = 系统性多扣或少扣；wall-clock 计量对滥用者（高内存长跑）偏宽松。pre-launch 无真实流量，先把门禁+扣费形态接通是合理折中。
- **建议**: 发布前 (1) 用 Cloudflare container 实际价目替换 `SANDBOX_USD_PER_SECOND`，最好建 `sandbox_prices` 表（同 `web_tool_prices` 模式）；(2) 评估是否需从容器侧拿 memory-seconds 取代纯 wall-clock；(3) 视成本量级决定是否加周期 settle + 余额≤0 中途 kill 容器。
- **状态**: 待办
### 🟡 群语音 DO↔容器掉线重连/resync 控制逻辑已写+单测，但端到端音频恢复 runtime 未验证
- **发现**: 2026-05-29 · feat/group-voice-reconnect
- **位置**: `apps/edge/src/durable-objects/room-voice.ts`（heartbeat / onMediaClosed / runReconnect / resyncContainer / 多路复用 alarm）、`apps/edge/src/durable-objects/room-voice-reconnect.ts`（纯函数：nextBackoffMs / buildResyncCommands / shouldGiveUpReconnect）、`apps/voice-container/src/room.ts`（resetForStart + pong）
- **问题**: 控制面的掉线检测（close/error + 心跳丢 pong）、指数退避重连、resync 重放（start 复位容器 + 逐 bot add-bot）这套**控制逻辑已实现并有 vitest 覆盖**（退避表 + cap、resync 命令序列、drop→reconnecting→恢复/放弃的状态机用 mock socket 跑通）。但这个功能**无法在本地 runtime 验证**——线上 Cloudflare Container 部署被刻意搁置，没有活的容器实例可打。因此 `start` + `dial /control` + `{t:'ready'}` 握手 + 重放命令的**真实时序**、以及音频是否真的恢复，全都没跑过。
- **影响**: 端到端的「通话扛过容器抖动」目前是**未验证的纸面能力**。最关键的几个未知：(1) **OpenAI realtime 会话**在容器被 `start` 复位后是全新握手——掉线那一刻**进行中的那一轮 turn 大概率丢失**，bot 不会接着说，需要人或 VAD 重新触发；(2) **RealtimeKit 参与者**在新容器/复用暖容器上 rejoin 的时序未知——旧 participant 是否会 linger 30–60s 让新 leg 干净顶替，还是会出现双 participant / 抢占；(3) 重连窗口内（最坏 ~30s）**人类听到的是静音**，没有补偿音频或「正在重连」语音提示，只有 UI 的「重连中…」横条；(4) playout jitter-buffer 在新 leg 上要重新 pre-roll，恢复瞬间可能有一小段额外延迟/卡顿。
- **重试边界（reviewer 需知道何时仍会放弃）**: 退避 250/500/1000/2000/4000/8000ms，cap 10s；总 wall-clock 预算 `RECONNECT_MAX_WALL_MS = 30s`。预算耗尽（约 8 次拨号）后 `runReconnect` 调 `finalize()` 真正结束通话并广播 `voice_call{event:'ended'}`，日志 loud（带尝试次数）。重连期间 `sendMedia` 丢弃命令（有日志）——靠 resync 的 add-bot 重放重建 roster，不排队。
- **建议**: 等容器部署后做一次真机演练：通话中 kill 容器实例（或断其网络），观察 (a) DO 是否在 ~10s 内检测到并广播 reconnecting；(b) 新容器 ready 后 OpenAI/RTK 是否都重建、人能否继续听到 bot；(c) 进行中 turn 丢失是否需要补一条「我刚刚断了一下」式的提示音/系统消息；(d) RTK 双 participant 是否需要在 resync 前显式 leave 旧 meeting participant。若 (b)/(d) 有硬伤，考虑 resync 时让容器先显式 detach 旧 RTK participant 再 rejoin，而非纯靠 `start` 复位。
- **状态**: 待办（控制逻辑已合入 + 单测绿；端到端音频恢复待容器部署后 runtime 验证）

### 🟡 IM realtime 仍是 Worker 主动推送和 Postgres conv webhook 混合态
- **发现**: 2026-05-29 · codex/message-coordination
- **位置**: `supabase/migrations/20260516073714_realtime_webhooks.sql`、`apps/edge/src/routes/messages.ts`、`apps/edge/src/lib/unread-state.ts`
- **问题**: 本轮已把高放大的 `user_unread_counts` pg_net fanout 去掉，read ack/unread 状态改由 Worker 主动推 user hub；但 `messages` 的 conv 级变更仍依赖 Postgres webhook 作为兜底，Worker 写入后也会等待 DB webhook 把 canonical row 推回客户端。
- **影响**: SSE/WS 已靠 message id + `message_seq` 去重，但消息发布源仍是混合态；后续要做 DO 级房间排序、离线 outbox、recall/update/delete 的精确顺序时，仍可能出现“Worker 已知道结果但 conv hub 等 DB webhook”的延迟和双路径语义漂移。
- **建议**: 下一阶段把所有消息状态变更统一收敛到 Worker/DO 的 `publishMessageChange` primitive：insert/update/delete/recall 都由 Worker 写库后同步发布 conv hub，Postgres `messages` webhook 只保留迁移期兜底，最终关闭。
- **状态**: 待办

### 🟡 PendingCrew Mac 本机 session：成功跑的 stdout + 退出码不回流 UI（卡在 running）
- **发现**: 2026-05-29 · computer-use 实测本机 happy path 时暴露
- **位置**: `apps/pendingcrew/Sources/Mac/LocalRunner/LocalCodingAgentProcess.swift`(actor + readabilityHandler/terminationHandler)、`LocalCodingAgentService.swift`(`MacLocalCodingAgentService.runSession` 把 line handler → AsyncStream，`waitUntilExit` → `exitCode` Task)、`apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift`(`CrewSessionRun.observeStreams`)
- **问题**: 起一个本机 Claude Code session 后，进程**确实跑完并干净退出**（`ps` 确认无残留 claude 子/孙进程；shell 里用完全相同的 argv/env/cwd/stdin 跑 `claude --print --output-format=stream-json --verbose` 2.6–8.7s 出完整 stream-json、exit 0），但 app 右栏**永远停在 `running`、stdout 恒为「(空)」**，6+ 分钟不变。即 stdout 流和 exit code 都没回流到 `CrewSessionRun` 的 `@Published`。
- **关键非对称线索**: **失败路径正常**——`--verbose` 修复前，claude 把参数错误打到 **stderr** 并秒退，app 正确显示 stderr 内容 + 状态 `失败 1`。也就是说 stderr 流 + exit code 在「快速退出」时能回流；但 **stdout** 在「跑几秒成功退出」时不回流，且同一次 run 的 exit code 也收不到（否则状态会从 running 翻成 completed）。代码层面 stdout/stderr 两条桥是对称的（同样的 readabilityHandler、同样的 `cont.yield`、同样的 observe Task），所以更像是 **Process/actor 生命周期或 Pipe EOF/terminationHandler 在「长跑 + 大块 stdout」场景下的竞态/未触发**，而非 stdout 专属的代码 bug。已排除：App Sandbox（无 entitlements、codesign 无 sandbox）、PATH/env（`env -i` 最小 PATH 也能跑通）、stdin 未关闭（代码已 write+close）、孙进程占住 pipe（`ps` 无残留）。
- **影响**: **v1.0 本机 runner 的核心路径目前不可用**——每个成功的本机 Claude Code/Codex session 都会卡在 running、看不到任何输出，用户无法判断任务进展或完成。这是 PendingCrew Mac 最主线的功能。`--verbose` flag 已修（commit 8bc97d72），所以 CLI 调用本身已正确；剩下的就是这条「成功 run 的输出/退出不回流」。
- **根因**: 不在 runner core——写了个不依赖 GUI 的 Swift harness（直接 new `LocalCodingAgentProcess` + `MacLocalCodingAgentService`，同样的 observe 模式）跑 claude，**stdout 实时流 + exit code 全正常、4s 跑完**，证明 process/service/stream 桥都对。真正的 bug 在 SwiftUI 层:`CrewSessionWindowView` 只 `@EnvironmentObject` 持有 `CrewSessionRunner`（`.current` 被赋值时才刷新），却把内层 `CrewSessionRun`(嵌套 ObservableObject)的 `@Published`(stdoutText/status/exitCode)当普通参数读，**没订阅**——经典 nested-ObservableObject 漏订阅。模型一直在更新，view 永不重渲染。
- **修复**: 抽出 `SessionRunContentView { @ObservedObject var run: CrewSessionRun }`，让输出栏 + 状态徽章订阅 run 自己的变化。
- **状态**: 已解决（2026-05-29 · commit 86f678f8。computer-use 实测:stdout 实时流出 stream-json、状态翻成「退出 0」。另已修 `--verbose` 前置 bug commit 8bc97d72。）

### 🟡 iOS PendingBot CrewTabView 是 codex 老 dashboard 风格,未按 spec v2 §11.2 重做(roadmap 漏列单独 task)
- **发现**: 2026-05-28 · user 主动追问"iOS Crew Tab 做了没"时暴露
- **位置**: `apps/pendingbot/Sources/Features/Crew/CrewTabView.swift`(878 行)+ `CrewAPI.swift`(330 行)+ 调用的老 `/v1/crew`(单数)endpoint 链路
- **问题**: 现有 iOS Crew Tab 是 codex 之前实现的 **dashboard 风格**:`@State crews / runnerHosts / sessionsByCrew / linksByCrew / membersByCrew / announcementsByCrew` 字典爆炸,UI 是创建 crew + 起 session + 看 runner host 的"工作台"形态。spec v2 §11.2 明确要求 PendingBot Crew Tab 是**普通群聊 UI grammar**(crew 列表按最近活跃排 + tap 进 crew → 群聊页面 + 消息流 + composer + @人/@session/@captain + session 状态卡 + 子 crew 摘要卡 + "在 PendingCrew 中打开")—— 完全两种东西。T1.3 D agent 只往里塞了个 SubjectPickerSheet(扫码批准 PendingCrew 登录),主体没动。
- **影响**: v1.0 发出去 iOS Crew Tab 是 codex 风格而非 spec v2 §11.2 风格,**用户体验跟 Mac PendingCrew + iPad 不一致**;后续 §9 通信规则(`@session` mailbox / `post_to_crew` tool / 群聊白板)接入也没 client 入口。
- **建议**: v1.0 roadmap 漏列了这个 task,本次补加 **T4.6 iOS PendingBot Crew Tab v2 重做**(roadmap §7 Phase 4,跟通信规则一起做)。重做要点:
  - 删/重写 老 dashboard
  - crew 列表用 `/v1/crews`(F agent ship 的新 endpoint),不是老 `/v1/crew`
  - tap 进 crew → 群聊页(类似 ConversationView 风格,但 crew 上下文)
  - 保留 SubjectPickerSheet(扫码批准 PendingCrew 登录的入口)
  - iPad / Mac 借此机会规划共享(spec v2 §12.1 中栏 = §11.2 crew 群聊,两端同源)
- **状态**: 待办(已加 roadmap T4.6,本次 session spawn sub-agent 做 MVP)

### 🟡 PendingCrew `devicePublicKey` 是 placeholder 字符串,device grant 没真绑设备
- **发现**: 2026-05-28 · feat/subject-login-flow(T1.3 sub-agent 标了 TODO,session cleanup 时正式登记)
- **位置**: `apps/pendingcrew/Sources/Services/PendingCrewAPI.swift`(`createDeviceLoginChallenge` 里的 `devicePublicKey`)
- **问题**: 现在传给 edge 的 `devicePublicKey` 是写死的字符串(类似 `"scaffold-placeholder-key-0123456789abcdef"`),仅满足 edge 端 `z.string().min(16).max(4096)` 长度校验,**没有任何 keypair 在背后**。spec v2 §4.4 暗示的"device-bound grant"(Secure Enclave / Keychain backed P-256 / Ed25519,后续请求要签名)完全没实装。
- **影响**: device grant token 跟物理设备**没有密码学绑定**,**丢了就丢了**;edge 也没办法验证后续请求真的来自原设备。这对一个挂在远程命令通道(Phase 4 跨端遥控 / `peer_device` location)上的客户端是显著的安全洞 —— 偷到 grant 的攻击者可以装作合法设备发指令。
- **建议**: Phase 4 跨端遥控架构动工前必须真做:Secure Enclave / `SecKey` API 起 P-256 keypair,private key 留 Enclave,public key 上行;后续敏感请求加 signed header(`x-pcrew-device-sig`)边端 verify。**写进 spec v2 §4.4 + roadmap T4.5 前置依赖**。
- **状态**: 待办(Phase 4 前置)

### 🟡 三组"新旧字段"双写并存(Phase 2 schema 增量演进的副产品)
- **发现**: 2026-05-28 · feat/crew-core-schema + feat/subject-schema-foundation(T1.1 / T2.x sub-agent 都选择"增量演进而非重写",session cleanup 时合记一条)
- **位置**:
  - `subjects.subject_type`(老 plan)↔ `subjects.kind`(spec v2 §4.1),`20260528083506_subject_v2_schema_alignment.sql` 加 BEFORE trigger 双写
  - `temporary_group_meta.runtime_kind` ('local'/'cloud',老)↔ `runtime_location` ('local_host'/'peer_device'/'fly_machine',spec v2 §8.2),迁移 `20260528105149` 双写
  - `temporary_group_meta.cloud_machine_id`(老)↔ `fly_machine_id`(spec v2 §8.2),同上
- **问题**: 我让 sub-agent 在 T1.1 / T2.1 写 schema 时图省事,选了 "新加列 + trigger 同步" 而不是 "改老列 + 全量回填 + 老 column drop"。triggers 把读写两边都对上,但**两套字段的存在让任何后续改这些字段的人要同时维护两套**,read path 也乱(看 schema.ts 不知道用哪个)。
- **影响**: 每多一个引用这些字段的 code path,都要决定用新名还是老名;混用很容易出现;长期会让 schema 不易理解。已经在 `crews.ts` route 等地方混用了 runtime_kind 跟 runtime_location 两个名字。
- **建议**: 起一轮 hard cutover migration:把所有 read path 切到 spec v2 字段名 → 删 trigger → DROP 老字段。趁 v1 还没发外、用户量为 0 时做最便宜。**v1 launch 前必须完成**,不然 user data 落到老字段就要做 backfill 比现在贵。
- **状态**: 待办(v1 launch 前必须 cutover)

### 🟡 Spec v2 §6.3.1 captain 三种来源跟现有 schema 不一致
- **发现**: 2026-05-28 · feat/crew-core-schema(T2.2 sub-agent 报告)
- **位置**: `docs/superpowers/specs/2026-05-28-pendingbot-pendingcrew-product-design-v2.md` §6.3.1 vs `supabase/migrations/20260527090000_crew_dag_captain_responsibility.sql`(老迁移已实装 `spawned_by_captain` 第四种来源)
- **问题**: spec v2 §6.3.1 列了 captain 三种来源(bot 在群聊发起自动当 / 用户已有 bot / 系统生成),但**老迁移已经实装了第四种** `spawned_by_captain`(captain 主动创建子 crew 时自动成为子的 captain),并配有 `create_child_crew_inheriting_responsibility_for_actor` RPC。T2.2 sub-agent 走了老 RPC,**没修订 spec v2**。
- **影响**: spec 跟现实出现 4 vs 3 来源的轻量不一致;后续 captain 选择 UI 设计、客户端枚举、文档都可能照 spec 漏掉 spawned_by_captain 分支。
- **建议**: 修订 spec v2 §6.3.1 把 captain 来源补到第四种,描述清楚"由当前 crew 的 captain 主动创建子 crew → 子 crew 的 captain 默认 = 父 captain"的语义。
- **状态**: 待办(spec 修订)

### 🟡 PendingBot Mac 端通过 EXCLUDED_SOURCE_FILE_NAMES 跳过 iOS-only 文件,非真正 multiplatform 适配
- **发现**: 2026-05-28 · feat/pendingbot-multiplatform-scaffold + feat/pendingbot-mac-tab-shell
- **位置**: `apps/pendingbot/project.yml`(EXCLUDED 配置)、`apps/pendingbot/Sources/{Components,Features,Models,Networking,Storage}/`(被排除的 iOS-only 子树)
- **问题**: T0.1 commit message 声称 "iOS code 全部用 `#if os(iOS)` 整体包住,Mac 端 build 能跑";实际**没有逐文件加** `#if os(iOS)`,Mac build "成功" 只是因为 swift 编译器在前面 2 个 module-resolution error 就 abort,后面 100+ 个 `import UIKit` 文件根本没参与 Mac 编译。T1.4 sub-agent 发现后改走 `EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]` 在 xcodegen 层把整个 iOS-only 子树从 Mac build 排除,实现等价(Mac 不编译这些文件),但代价是**这些文件在 Mac 端完全不可见**。
- **影响**: Phase 2+ 渐进做 Mac 端业务接入(IM 列表、消息流、Crew Tab 等)时,要逐文件决定是 unwrap 成跨平台还是保持 Mac-excluded。**没有任何 build 验证能告诉你哪些文件还在 iOS-only 子树里**(它们对 Mac build 隐身);容易在做 Mac UI 时反复 surprise:某个想用的 model / service 其实在 excluded 子树里,引用就编译不通。
- **建议**: Phase 2 起,每加一个跨平台 view 要主动检查依赖链 —— 跨平台需要的 model / service / helper 从 excluded 子树挪到 `Sources/Shared/`,或加 `#if os(iOS)` 让平台特定部分隔离,逐步收缩 EXCLUDED 范围。**T0.1 的"整体 #if 包"承诺要么真做(逐文件加),要么把 EXCLUDED 当作长期方案显式记入 spec/roadmap,不能两头吊**。
- **状态**: 待办(Phase 2 起渐进消化)

### 🟡 Supabase advisor 噪音没有 allowlist / ownership 分层
- **发现**: 2026-05-25 · codex/security-architecture-audit
- **位置**: Supabase security/performance advisors、`supabase/migrations`
- **问题**: 当前 advisors 同时报告真实待部署安全问题、service-role-only 表的 `RLS Enabled No Policy`、大量缺索引外键、多条 permissive policy、以及可解释的管理/触发器函数。没有 repo 内 allowlist 和“必须清零 vs 可接受噪音”的分层，导致每次审计都要重新判断哪些是风险、哪些是预期。
- **影响**: 真问题容易被噪音淹没；也会让“部署后 advisors clean”这个安全门槛变得不明确。尤其是 service-role-only 日志/配置表、管理 RPC、subject helper 这几类需要可机器检查的例外。
- **建议**: 建一个 `docs/supabase-advisor-allowlist.md` 或测试 fixture：记录每条可接受 advisor 的理由、owner、复核日期；CI/本地脚本把非 allowlist 的 security warning 当失败，performance warning 至少生成待办清单。
- **状态**: 部分修复（2026-05-25 · 新增 `docs/supabase-advisor-allowlist.json`、`scripts/supabase-advisor-gate.ts`、fixture 测试和 `.github/workflows/security-gates.yml`；安全 advisor gate 默认 fail-closed，只有列明理由的 service-role-only INFO 可通过，未列入的 WARN/ERROR 会阻塞；CI 现在覆盖 gate/allowlist 逻辑不会退化。live 上仍需部署本分支 Supabase 迁移、处理 Auth leaked-password / MFA 设置，并在上线流程中用真实 advisor JSON 跑 `bun run supabase:advisor:gate <advisor-json>`。）

### 🟡 1v1 Realtime 和群语音的 metering / billing 逻辑重复
- **发现**: 2026-05-25 · codex/security-architecture-audit
- **位置**: `apps/edge/src/durable-objects/realtime-meter.ts`、`apps/edge/src/durable-objects/room-voice.ts`、`apps/edge/src/routes/realtime.ts`、`apps/edge/src/routes/group-voice.ts`
- **问题**: 两套语音路径都在组装 realtime session、读取 `response.done` usage、调用 `computeVoiceCost`、广播 `voice_cost`、最终 `enqueueAudit`；但生命周期、参与者语义、计费归属和日志策略分别散在两个 DO / 两套路由里。
- **影响**: 一个路径修了隐私日志、缓存计费或余额中断，另一路可能漏掉；群语音接 bot participant 和 RealtimeKit 双轨成本后，这种重复会直接影响账单一致性和隐私审计。
- **建议**: 抽出共享的 voice metering/billing primitive：usage 归一、cost preview、audit enqueue、log redaction、hangup policy 共用；DO 只保留 transport/room lifecycle 差异。
- **状态**: 部分修复（2026-05-25 · 新增 `apps/edge/src/lib/voice-metering.ts` 和 `voice-metering.test.ts`，两套 DO 共用 realtime usage 拆分、事件脱敏摘要、`voice_cost` live preview 的 markup / 累计 / 广播逻辑、voice audit enqueue 元数据组装；1v1 realtime session 预调用与 post-turn 余额门槛均复用 billing 层 `getBalanceGateState`，避免语音和文字入口漂移；群语音房间级余额中断策略仍需单独设计，不能直接套 1v1 hangup。）

### ✅ JWT 验证只校验签名和形状，未绑定 issuer/audience/role
- **发现**: 2026-05-24 · codex/security-architecture-audit
- **位置**: packages/identity/src/jwt.ts:42、packages/identity/src/schema.ts:8
- **问题**: Edge 端 `jwtVerify` 允许 Supabase JWKS 的非 HS256 签名算法，但没有传 `issuer` / `audience`，payload schema 也只把 `role` 当 optional 字段，不要求 `role = authenticated`。
- **影响**: 目前同项目 JWKS 已经挡住大多数伪造，但认证边界比 Supabase Auth 语义更宽；未来多 audience、服务 token 或 Auth 配置变化时，可能把不该当用户会话的 token 接进 `requireSession()`。
- **建议**: 把 `issuer` 固定为 `${SUPABASE_URL}/auth/v1`，`audience` 固定到期望值，并在 middleware 中要求 `role === 'authenticated'`。
- **状态**: 已修复（2026-05-25 · `packages/identity/src/jwt.ts` 在 `jwtVerify` 层绑定 `issuer = ${SUPABASE_URL}/auth/v1` 与 `audience = authenticated`，payload schema 要求 `role = authenticated`；`identity-jwt.test.ts` 覆盖错误 issuer / audience / role。）

### 🟡 iOS 模型池的 Artificial Analysis 排序是静态快照
- **发现**: 2026-05-24 · codex/bot-model-pool-ui
- **位置**: apps/ios/PendingBot/Components/ModelPicker.swift
- **问题**: 新建机器人模型池按 Artificial Analysis Intelligence Index 排序，但当前实现把一份榜单分数快照写在 iOS 端；Artificial Analysis 免费 API 需要服务端 API key，仓库还没有对应的后端缓存/归因链路。
- **影响**: 榜单会随时间漂移，客户端静态排序会逐步变旧；以后如果用户把“按 AA 排序”理解成实时榜单，这里会产生隐性偏差。
- **建议**: 在 Edge 的 `/v1/models` 聚合里接入服务端缓存的 Artificial Analysis API 数据，返回稳定的 `intelligence_index` 字段，iOS 只消费字段排序和展示归因。
- **状态**: 已解决（codex/artificial-analysis-api：Edge `/v1/models` 接入 Artificial Analysis API + KV 缓存并返回 `artificial_analysis_intelligence_index`，iOS 改为消费服务端字段排序）

### 🟡 RealtimeKit POC 入口绕过了正式群语音 presentation
- **发现**: 2026-05-23 · codex/cf-realtimekit-poc
- **位置**: apps/ios/PendingBot/Features/Message/ConversationView.swift、apps/ios/PendingBot/Features/Call/GroupCallView.swift
- **问题**: 为了在两个模拟器上验证 RealtimeKit 房间，Conversation DEBUG header 临时加了 `RealtimeKit POC` 按钮直接请求 bootstrap 并弹 WebView；正式群语音按钮/active call banner 到 `GroupCallView` 的 presentation 在验证时没有稳定打开。
- **影响**: POC 验证路径和正式用户路径分叉，容易出现“调试入口可用、正式入口不可用”的假阳性；后续接 bot participant 和计费前必须把正式入口的状态机、sheet/fullScreenCover 归一。
- **建议**: 把正式群语音入口收敛到同一个 room state coordinator，由它负责创建/恢复房间、展示通话 UI、挂接 RealtimeKit/OpenAI participant 与计费状态；DEBUG 入口只保留为同一 coordinator 的诊断开关。
- **状态**: 已解决（013d037 之后的 codex/realtimekit-formal-entry，2026-05-23：DEBUG 群语音按钮进入 `GroupCallView` 的 RealtimeKit provider，删除 Conversation header 临时入口）

### 🟡 RealtimeKit 仍未接入 bot participant 和双轨计费
- **发现**: 2026-05-23 · codex/cf-realtimekit-poc
- **位置**: apps/edge/src/routes/group-voice.ts、apps/edge/src/lib/realtimekit.ts
- **问题**: RealtimeKit bootstrap/leave/end 已经接入 `voice_active_calls` 和 `voice_call` conv-channel 生命周期，但 bot runtime 还没有作为 WebRTC participant 入会，RealtimeKit 房间成本也还没有和 OpenAI Realtime usage 一起进入正式计费。
- **影响**: 两个真人可以走 RealtimeKit 调通房间生命周期，但“机器人像真人一样参会”仍缺一个受控 WebRTC client/mixer，且正式 Release 前还缺双轨计费口径；否则容易出现媒体成本不透明或机器人音频绕开 PendingBot 的预算控制。
- **建议**: 下一步把 bot runtime 做成 RealtimeKit participant，由服务端负责混音/输入 OpenAI Realtime、按会话维度汇总 OpenAI usage + RealtimeKit participant/session minutes，再落到现有 `voice_cost`/audit billing 体系。
- **状态**: 部分修复（2026-05-25 · 群语音已接入 headless RealtimeKit bot participant / media container；本轮新增 RealtimeKit audio participant-minute 结算：通话结束写入 `cloudflare_realtimekit_media` 审计行，按真人在场秒数加权 split，同时把 bot participant 秒数计入总媒体成本；价格进入 `billing_config.cloudflare_realtimekit_audio_participant_usd_per_minute` 和 board billing knob。剩余：用真实 RealtimeKit/Cloudflare 账单数据校准价格与 active-session minute 口径。）

### 🟡 跨 provider web search 解析路径未经真实流量验证
- **发现**: 2026-05-22 · feat/web-search-providers
- **位置**: apps/edge/src/llm/{responses,anthropic,gemini}-adapter.ts、apps/edge/src/lib/bot-reply/index.ts
- **问题**: 四条 provider 的搜索词/引用解析都是按当前官方文档「应该长这样」写的 + 单测覆盖了解析逻辑，但没跑过 AI Gateway 的真实响应。三处具体不确定：① OpenAI 用的是 `web_search_preview`，搜索词靠运行时 `web_search_call.action.query`，SDK 4.104.0 没建模 `action`，preview 变体运行时可能根本不带 query（引用走 annotation 不受影响）；② Gemini 把 `google_search` 和 `functionDeclarations` 放在同一个 `tools` 数组，2.x/3.x 支持、老模型会 400 整轮失败；③ annotation 事件名 `response.output_text_annotation.added` 是下划线形式，与 SDK 版本耦合，升级 openai SDK 时可能改成点号形式而静默失配。
- **影响**: 搜索词/引用可能在某些 provider 上仍不显示（降级而非崩溃，OpenAI/Gemini 引用仍能出）；Gemini 老模型若拒绝组合 tools 会让整轮回复失败——这是唯一可能从「不显示」恶化成「报错」的点。
- **建议**: 每条路各发一条真实搜索回合核对 SSE：OpenAI 看搜索词是否出（不出就把 `web_search_preview` 换 `web_search`）；Gemini 确认所用模型支持 search+function 共存（不支持则按模型分档，或搜索turn 不带 function tools）；升级 openai SDK 时回归 annotation 事件名。
- **状态**: 部分修复（2026-05-25 · Gemini native adapter 现在对 `google_search` + `functionDeclarations` 组合不兼容的 400 做单次 search-only 降级，避免老模型把整轮回复打挂；仍需用真实 AI Gateway 流量验证 OpenAI query / Gemini grounding / annotation 事件名。）

### 🟡 Crew Tab 聊天剩余两处刻意取舍（无附件 / 人类气泡同侧）
- **发现**: 2026-05-29 · feat/crew-tab-v2-multiplatform（T4.6 P1）；前两项已于 T4.5（feat/crew-live-push）解决
- **位置**: apps/pendingbot/Sources/Features/Crew/{CrewChatStore,CrewMessageListView,CrewComposerBar,CrewChatModels}.swift
- **问题**: 把 crew 详情页改成群聊 UI（消息流 + composer + @mention + session 状态条 + 子机组卡）时，P1 刻意留了四个洞，T4.5 已补掉前两个：
  1. ~~**轮询，无实时推送**~~ —— **已解决（T4.5）**：crew 就是一个 conversation，`crew_announcements` / `crew_sessions` 行变更现在经既有 `conv:<crewId>` RealtimeHub topic fan-out；`CrewChatStore.start()` 在首次 `load()` 后开 conv-channel，`apply` / `applySession` 按 id upsert（INSERT=新帖、UPDATE=权限状态翻转）。`.refreshable` + 发送后 `reload()` 保留为冷启动/兜底。
  2. ~~**inline 权限卡片缺数据源**~~ —— **已解决（T4.5）**：权限卡数据源就是 `crew_announcements` 里 `message_kind=='permission_request'` 的行（冷加载 `getCrewAnnouncements` + live 帧都带）。`CrewChatAdapter` 把这类行产出权限变体（解 `payload` → `PermissionRequestPayload`、session 标签查 session index），`CrewMessageListView` 按行分支渲染 `PermissionRequestCardView`，批准/拒绝走 `store.decide(...)` → `decidePermissionRequest`，服务端把状态盖回 announcement 再 fan 回来翻转卡片。
  3. **composer 无附件**——复用 `ComposerView` 但传 `showsAttachments: false`，把 "+" 按钮和附件面板整个隐藏（不是留哑 tile）。crew 发送只走 `POST /v1/crews/:crewId/messages` 的纯文本 + mentions。
  4. **人类气泡分不出"我 vs 别人"**——`crew_announcements` 读出来只有 `sender_member_id`，拿不到我的 user_id，所以 `CrewChatAdapter` 把所有 human 帖都渲染到 user（右）侧、用 `display_name` 做气泡上方署名。多人时仍读得出是群聊，但"哪条是我发的"无法高亮。
- **影响**: 剩余两项都是体验降级而非功能缺失/报错。③ crew 里发不了图/文件；④ 我自己的消息和别人的同侧、无"自己"高亮。
- **建议**: 要分"我 vs 别人"需要读侧返回 `sender_user_id` 或在 members 里把 `me` 的 member_id 标出来再比对；附件等 crew upload 通道就绪后把 ComposerView 的 picker 接活。
- **状态**: 部分修复 —— ① live push + ② inline 权限卡已于 T4.5 落地；③ 附件、④ 自我高亮仍未修（待读侧补字段 / crew upload 通道）

### 🟡 客户端(iOS/Mac)从不把用户身份同步给 RevenueCat / PostHog / Sentry — 三个外部服务的 client 侧 identity 全缺

- **发现**: 2026-06-08 · session(查"iOS 注册后 Polar 没对应用户")
- **位置**: `apps/pendingbot/`(整个客户端;grep `revenuecat`/`Purchases`/`posthog`/`sentry` 零命中)、对照 edge 侧已就绪的 `apps/edge/src/routes/billing-webhooks.ts:185`(`ev.app_user_id`)、`apps/edge/src/lib/analytics.ts`(distinctId=subjectId)
- **问题**: 所有外部服务都约定用 `subject_id`(= `auth.users.id`)当外部主键,edge 侧已按此接好;但 **客户端从没把这个 id 告诉这三个服务**:
  1. **RevenueCat** —— iOS 完全没集成 SDK,从不调 `Purchases.configure` / `logIn(subjectId)`。后端 `/v1/billing/revenuecat/webhook` 已经在等 `app_user_id`,可一旦真走 IAP,RevenueCat 不知道这笔购买属于哪个 `subject_id` → **入账对不上人**(直接影响计费正确性)。
  2. **PostHog** —— 客户端无 SDK、无 `identify(subjectId)`;目前只有 edge 侧 `topup_succeeded` 一个事件带 distinctId。注册、会话、产品行为在 client 侧全无埋点。
  3. **Sentry** —— 任何地方(client + edge)都没 `setUser()`;报错事件挂不到具体用户,只有 trace/时间戳。
- **影响**: RevenueCat 这条是 🟡 偏 🔴 的——IAP 上线前不补会导致购买无法归户、对账困难。PostHog/Sentry 两条是观测盲区(无用户维度归因),非阻断。注意这与 kill-switch(`BILLING_ENABLED`/`POSTHOG_ENABLED` 默认关,wrangler.jsonc)是两回事:开关只管 edge 发不发,**客户端 identity 缺失是开关打开也补不上的独立洞**。
- **建议**: ① IAP 上线前必做:iOS 集 RevenueCat SDK,登录成功后 `Purchases.shared.logIn(subjectId)`,登出 `logOut()`;② PostHog iOS SDK + 登录后 `identify(subjectId)`、登出 `reset()`;③ Sentry(client 用 sentry-cocoa,edge 在 worker 入口)登录后 `setUser(id: subjectId)`。三者共用"拿到 session 后取 `auth.users.id` 调一次 identify"的同一时机,可一并接。
- **状态**: 大部分已解决 2026-06-08(feat/client-telemetry-sdks)。新增 `apps/pendingbot/Sources/Networking/Telemetry.swift` 协调器:`PendingBotApp`(iOS+macOS)init 调 `configure()`,`onChange(of: accountStore.current)` 登录 `identify(subjectId)` / 登出 `reset()`,三 SDK 统一用 `subject_id`、不传 PII。PostHog(3.59.3)/Sentry(9.16.1)填真 key(`.remote`),iOS+Mac 编译双绿 + 模拟器启动冒烟通过。**剩余两条尾巴**:(a) RevenueCat 走 `Purchases.isConfigured` gate、`revenueCatKey` 暂为空串占位 → SDK 休眠,待 RC 账号开通补 `appl_…` key + 真上 IAP(身份代码已就位);(b) PostHog/Sentry 事件真实投递到 dashboard 仅靠"启动不崩"验证,真机/真登录的端到端归因闭环未做。

## 🟢 不规范

### 🟢 surf_runs / scroll_runs 是 envelope 取代后的遗留死表(仍挂在 realtime publication 上)
- **发现**: 2026-06-07 · chore/edge-read-offload-spec(T2 读卸载梳理)
- **位置**: `supabase/migrations/*`(`surf_runs` / `scroll_runs` 建表 + realtime publication)、`apps/edge/src/db/schema.ts`
- **问题**: surf / scroll 两个 feature 早已被 envelope(来信)取代,edge + iOS 活代码对 `surf_runs` / `scroll_runs` / `surfRun` / `scrollRun` **零引用**,仅 schema 残留。且 `surf_runs` 还挂在 `supabase_realtime` publication 里,白占一个 webhook/复制通道。
- **影响**: 纯死表噪音——拉大 schema、误导后来者以为是活 feature(本次 T2 梳理就一度把它们当 live 列进矩阵)、realtime publication 多一张无用表。无功能危害。
- **建议**: 确认无线上数据依赖后,迁移 drop 两表 + 从 realtime publication 摘除;`db push` 后 regen schema.ts。低优先,可与下次清理迁移合并。
- **状态**: 待办

### 🟢 iOS FriendsTabView 群邀请兜底文案仍是旧分摊口径
- **发现**: 2026-06-04 · fix/billing-tails-email-norm（#226 解耦）
- **位置**: `apps/pendingbot/Sources/Features/Friends/FriendsTabView.swift:827`
- **问题**: `billing_snapshot` 为 null 时兜底显示「接受后会按当前群设置参与机器人 Token 分摊。」——新群钱包模型下该口径已过时。edge 现总填中性 hint（`groupInviteBillingHint`），兜底极少触发，但文案该改。
- **影响**: 极少触发的过时文案，纯一致性。
- **建议**: iOS lane 顺手把兜底串改成中性/新模型口径。
- **状态**: 待办

### 🟢 PendingCrew 双轨 backend(EdgeBackend / LocalBackend)没有单元测试覆盖
- **发现**: 2026-05-29 · T5.2 dual-track routing wiring
- **位置**: `apps/pendingcrew/Sources/Services/PendingCrewBackend.swift`、`apps/pendingcrew/Tests/PendingCrewTests/`、`apps/pendingcrew/project.yml`
- **问题**: `PendingCrewBackend` protocol 有两个实现(EdgeBackend / LocalBackend),关键行为(BYOK 路径下 `attachParent` / 非 `local_host` runtime 抛 `notSupportedInByok`、`listMySubjects` 返回单元素假 subject、AppModel.mode → backend 选择)只通过 Mac 手测验证。`PendingCrewTests` target 是 standalone XCTest bundle,故意只编 `Sources/Mac/LocalRunner` 进去(`TEST_HOST=""` / `BUNDLE_LOADER=""`,见 project.yml 注释 —— scaffold 阶段 app 不签,无法做 host-app injection)。要给 backend 加单测得改 project.yml 把 Sources/Services + Sources/Stores + Sources/Models 也编进 bundle,或者把 backend 抽成独立 SwiftPM module。
- **影响**: BYOK / logged 切换、能力 gating(`supportsCloudRuntime`)的行为契约靠 UI 手验,后续新加 protocol 方法(spec §5.3 提到的 share-change / mailbox / whiteboard 等)很容易漏掉一端没实现就 ship。
- **建议**: 等 PendingCrew app 真正签名(脱离 scaffold 阶段)后,把测试 bundle 改成普通 host-app injection 模式,补 backend 行为快照测试;或者把 PendingCrewBackend + 两个实现拆到 `Packages/PendingCrewBackend/` SwiftPM module,带自己的测试 target。
- **状态**: 待办

### ✅ 模拟器 signup 失败("permission denied for table users") = 模拟器没签名 → Keychain -34018(三轮误诊后定案)
> 标题历经多轮:~~Keychain entitlements~~ → ~~后端 signup bug~~ → ~~supabase-swift anon~~ → **真因:模拟器关签名导致 Keychain -34018**(详见下方"二次纠正"+ 343 条 🔴 的"⭐ 上游真因")。已在 `project.yml` 根治。
- **发现**: 2026-05-29 · v1 QA;2026-05-29 复盘纠正
- **位置**: 误指 `apps/pendingbot/project.yml` / `Resources/PendingBot.entitlements`;实因 `bootstrap_user_id` 等 signup RPC
- **纠正后的真相**: 之前把模拟器邮箱登录失败归因为"sim 不签名 → `keychain-access-groups` 不生效 → `-34018` → session 存不进 Keychain"。**这是误诊**。三条证据推翻它:① `keychain-access-groups` 自 T0.1 脚手架(`4b305f1a`)起就在 entitlements 里,不是新增,无法解释"突然不行";② 关键 tell —— 故障期 **Google 登录正常、只有邮箱登录失败**;若真是 Keychain 问题,两条登录都要存 session 到 Keychain,会**一起挂**,Google 能成功恰恰证明 **sim 的 Keychain 工作正常**;③ 邮箱 OTP 走 `shouldCreateUser=true` 的建号路径,正好踩中当时坏掉的后端 RPC(`bootstrap_user_id` 的 `bot_id` 歧义、`uuidv7` 对 authenticated 无执行权、`is_bot_invitee` 残留),"permission denied for table users / auth session missing" 是后端 bootstrap 失败后拒绝 PATCH,不是 client 存不住 session。
- **影响**: 误诊本身耗了不少时间,也差点逼出"sim 用内存版 AuthLocalStorage"这种没必要的 workaround。模拟器**可以正常登录和测试**(签不签名都行;CLI ad-hoc 签名 entitlements 是空的,但 sim 的 Keychain 默认 access group 不依赖它)。
- **建议**: 模拟器是可信的 auth 测试环境,无需真机兜底。后端 signup bug 已修并部署(见对应迁移)。CLI 不签名构建只用于编译校验;运行时测试直接装 unsigned 或 Xcode GUI 构建都可登录。
- **状态**: 已解决/纠正(2026-05-29 · 根因是后端 signup bug,已修+部署;Keychain 结论作废,留作"别再被表象误导"的记录)
- **二次纠正(2026-06-01)**: 上面"`permission denied for table users` 是后端 bootstrap 失败后拒绝 PATCH"这句**也是误诊**。2026-06-01 同样的报错在选名字步骤复现,这次连 live 钉死了根因——**和后端无关**:① live introspection 实测 `has_table_privilege('authenticated','pendingbot.users','UPDATE')=true`、`users_self_update` RLS 在、唯一会 fire 的 `users_ensure_subject_trg` 是 `SECURITY DEFINER` owned by postgres;② `supabase db query` 直接复现出**一模一样**的 `42501: permission denied for table users`——但只在 `SET ROLE anon` 时;`SET ROLE authenticated + jwt.sub` 时 UPDATE 成功;③ live 上新用户行+subject 都正常建了(bootstrap 健康)。真正根因见下一条 🔴。**教训**:"permission denied for table X" 是**表级 grant**被拒(执行角色没权限),不是 RLS(那会说 "new row violates row-level security policy"),也几乎从不是 bootstrap;遇到先用 `has_table_privilege` + `SET ROLE` 复现钉死执行角色,别再往后端 RPC 上猜。

### 🔴 supabase-swift 写操作在拿不到 token 时**静默降级成 anon**(吞掉鉴权失败)
- **发现**: 2026-06-01 · 新用户选名字保存报 "permission denied for table users"
- **位置**: **全仓所有 `SupabaseStack.shared.from(...).insert/update/delete` 直写都受影响**;机理在 supabase-swift 2.46.0 `SupabaseClient.adapt(request:)`;最先暴露点是 `apps/pendingbot/Sources/Features/Onboarding/ProfileBootstrapView.swift:save()`
- **问题**: PostgREST 客户端初始化时把 `Authorization: Bearer <anonKey>` 设进默认 header;每个请求经 `adapt(request:)` 用 `let token = try? await _getAccessToken()` 取用户 JWT,**`try?` 会把 `auth.session` 的抛错吞成 nil**,nil 时**不覆盖** Authorization → 沿用 anon key 发出。于是当会话取不到 token(过期+刷新在途/刷新失败/瞬时不可用)时,这条写**静默以 `anon` 身份执行**;`anon` 对 `pendingbot.users` 只有 SELECT 没有 UPDATE → `42501 permission denied for table users`。onboarding 的 `users` PATCH 只是最先暴露的点(全新用户第一笔写、且直写 `users` 表),但**任何**直写都可能在 token 抖动时悄悄变 anon 然后被 RLS/grant 挡掉或(更糟)被 anon 的策略静默放行/拒绝,排错时极易误判成"后端/DB 问题"。
- **影响**: 真机上 token 抖动(过期+刷新失败)时,任意客户端直写会静默以 anon 发出 → 被 RLS/grant 挡掉并报误导性的"DB 权限"错。叠加既有的"客户端绕过 edge 直写 `users` 表"这一架构异味(本次 bug 报告里用户自己也点了"不走 edge / 不走 RPC")。注:本轮 onboarding 故障的**实际触发**是签名导致会话存不住(见上一条),不是真机 token 抖动;此条记录的是**独立存在的潜在隐患**。
- **建议(分层)**: ① 单点 mitigation(`save()` 写前 `try await auth.session` + fail-loud)**已评估并 revert** —— 真根因是模拟器签名,单点改动只治 onboarding 一个写、价值有限,为保持本分支聚焦签名根治,不保留。② 系统性(推荐):给所有"需要登录的写"包一层统一 helper(写前确保 token、拿不到就抛而不是降级),或把直写收敛到 edge 端点(显式 Bearer + service-role 落库,彻底消除 anon-fallback,顺带去掉直写 `users` 的异味)。③ 可选:给 `SupabaseStack` 配 `auth.accessToken` 自定义闭包改成"拿不到就 throw",从源头堵掉静默降级。
- **状态**: **未修**(代码层无改动;单点 mitigation 已 revert)。本轮 onboarding 故障由签名根因解决(见上一条 ✅)。本条作为独立潜在隐患记录,系统性收敛(helper / 收敛到 edge)待排期。
- **⭐ 上游真因(2026-06-01 当天继续挖出,这才是病根)**: "token 拿不到"在**模拟器上不是偶发抖动,是必现**——因为 `auth.session` 取不到 token 的根本原因是 **Keychain -34018**:模拟器装机后保存会话写 Keychain 直接失败,会话根本存不住。而 Keychain -34018 的根因是 **`project.yml` 之前对模拟器关了签名**(`CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]=NO`)→ ad-hoc 构建 → 没有 `keychain-access-groups`(该 entitlement 需要 team 前缀,ad-hoc 没有)→ app 没有任何 keychain access group → 所有 Keychain 操作 -34018。**模拟器实测**:`supabase db query` 复现出一模一样的 `42501`(只在 anon 角色);模拟器日志确证 `failed to persist DB passphrase to Keychain: -34018` + `aps-environment` 缺失,都是没签名的征兆。**生产/TestFlight 不受影响**(真机用真 profile 签名,有 team 前缀,Keychain 正常,会话存得住)——live 里 `bootstrapped=1` 的真实用户就是证据。这个病根被**反复误诊过多轮**(Keychain entitlements → 后端 bootstrap → supabase-swift anon),每轮都治了表象。
- **根治**: `project.yml` 改成模拟器也用 dev team 签名(`fix/signup-bootstrap-patch` 已提交)。**注意**:headless / 无登录 Apple ID 的 CLI 构建仍会回落 ad-hoc(xcodebuild 自动签名需要交互式证书访问),所以**模拟器跑 onboarding happy-path 必须用 Xcode GUI(已登录 Apple ID)构建**,纯命令行装的包验证不了登录态写。`supabase-swift 静默降级 anon`(下一条 🔴)本身仍是真实隐患(真机若遇 token 抖动同样会静默 anon),代码层未做改动、系统性收敛待排期。

### 🟢 iOS 工程缺少测试 target，语音诊断只能靠构建兜底
- **发现**: 2026-05-23 · codex/fix-group-voice-diagnostics
- **位置**: apps/ios/PendingBot.xcodeproj、apps/ios/PendingBot/Features/Call/CallDiagnostics.swift
- **问题**: 当前 iOS 工程只有应用 target，没有单元测试 target；WebRTC 统计差分、群语音诊断合并这类纯逻辑只能靠人工复现和 `xcodebuild build` 验证，无法先写一个失败用例锁住“新 RTP 轨道首次出现不能污染丢包率”这类回归。
- **影响**: 群语音、多轨道、重协商等边界条件容易被编译通过但行为错误的改动重新引入。
- **建议**: 给 iOS 工程补一个轻量 XCTest target，把诊断聚合逻辑抽到不依赖 WebRTC/SwiftUI 的小类型后覆盖轨道新增、轨道移除、负 delta、缓冲阈值等用例。
- **状态**: 已解决（codex/security-architecture-audit：新增 `PendingBotTests` XCTest target，并把语音诊断格式化、质量分级、网络/媒体瓶颈判断抽到 `CallDiagnosticsLogic`，用单测覆盖边界阈值和 bot 媒体瓶颈优先级）

### 🟢 OpenRouter 搜索 chip 无搜索词、引用不内联 [N]
- **发现**: 2026-05-22 · feat/web-search-providers
- **位置**: apps/edge/src/lib/bot-reply/index.ts（OpenRouter annotations 解析处）
- **问题**: OpenRouter 服务端搜索不回传查询串，只给 `annotations`，所以合成的搜索 chip 没有「搜索词」；且原生 provider（OpenAI/Anthropic/Gemini/OpenRouter）的模型不会写我们约定的 `[N]` 标记，引用只进结果列表、不在气泡正文内联。与 Exa MCP 路径（有搜索词 + 内联 [N]）体验不一致。
- **影响**: 体验降级而非功能缺失——引用列表正常显示、可点。属于 provider 能力差异，非自挖的坑。
- **建议**: 可选增强——按 annotation 的 start/end_index 把 [N] 注回正文文本；OpenRouter 的搜索词无解（provider 不暴露）。
- **状态**: 不修（provider 限制 / 体验可接受）

---

## 2026-05-29 v1 sprint summary

本节为本轮（Phase 1–7）冲刺收尾的汇总。冲刺范围：在 `claude/blissful-albattani-a8a732` 分支上推进 v1 双轨架构（PendingBot IM 多端 + PendingCrew 本地 coding agent + billing-v2 双写），共 **34 commits**，由 ~13 个并行 sub-agent worktree 汇出。

### 已落地（commit hash）

**Phase 1 — billing-v2 双写底座** (merge `worktree-wf_bb2bdb07-141-3`)
- `4a9f93da` v2 dual-write — LLM + web-tool usage_events alongside v1 debit
- `71b69a02` v2 voice (RealtimeKit media) + sandbox usage_events
- `2dc06dbe` v2 cron — pack expiry sweep + group-pool reconciliation
- `cbb4fb3f` v2 settleUsage CAS-loss retry + cover main paths
- `3aef07e8` merge

**Phase 2 — PendingBot Mac multiplat T0.1 P0** (merge `worktree-wf_bb2bdb07-141-5`)
- `388f24fd` `#if os(iOS)` 替代 EXCLUDED_SOURCE_FILE_NAMES 大锅排除
- `4eff9d8e` Mac "我" tab 接入 AccountStore 真实账号信息
- `d6ed2808` 记录剩余缺口
- `6df88dbb` merge

**Phase 3 — 群账号 / 权限 / 三端壳** (merges `…-7`, `…-8`, `feat/mac-3col-shell`)
- `207d5203` edge T1.2 — `/v1/group-subjects/*` 群权限矩阵路由
- `cc080ac1` merge T1.2
- `7ff0c2a6` merge T1.3
- `f2dbebfb` crew(mac) identity footer + sign-out
- `c174f734` mac 三栏 NavigationSplitView 根壳
- `5e132703` merge mac-3col-shell

**Phase 5 — T4.5 跨设备控制设计** (merge `worktree-wf_bb2bdb07-141-16`)
- `ceba5619` docs(t4.5) cross-device session control as-built design
- `0780685f` merge

**Phase 6 — PendingCrew 本地 runner + Session 面板** (merges `…-18`, `…-19`, `…-20`)
- `5f731002` Swift 6 captured-var warnings 静化
- `2c7b7887` LocalRunner 接 model slug
- `a5ffe5c3` `/v1/models` client + backend `listModels()`
- `6d944513` GitInspector helper（分支选择器）
- `29699690` 完整 session-create panel（spec v2 §12.2）
- `280d5b7b` T3.4 first-launch disclosure modal
- `00746ca9` GitWorktreeService for T3.3 worktree option
- `bbd97ae4` T3.3 three-layer working directory in session sheet
- `4ca47a98`, `564693f7`, `e7bb267b` merges

**Phase 7 — PendingCrew 未登录 BYOK 双轨路由** (merges `…-22`, `…-23`)
- `ee28d676` reset CrewStore on backend mode change
- `8e0eac32` docs(tech-debt) PendingCrew 后端单测缺口
- `42d58047` BYOK 本地 captain template store
- `f78d61bf` BYOK CreateCrewSheet captain pool picker + template editor
- `c69ba418` merge T5.1
- `692b661f` merge T5.2

### 仍延期（需人工或后续 session）

#### 🔴 必须人工介入

- 🟡 **多 session 共享 DB 的迁移协调摩擦（不是漂移，是正常并行开发）** (2026-06-03 厘清)。一度以为远端有 4 条"幽灵迁移"(`20260602043820 pnc_ledger / 051354 metabase_readonly_role / 121205 group_pool_polar_rehome / 150732 group_pledges`)——后查清它们是**别的在飞分支的真实文件**(`chore/billing-dashboard-specs` / `feat/billing-p2-llm-gate` / `chore/retire-billing-v2` 等 billing/dashboard 线),那些 session 已经从各自分支 `db push` 到共享 prod、但还没合 main,所以 main + 我的分支都没这几个文件。**这是单 prod DB + 多分支各自 push 的固有摩擦**:谁 push 了未合 main 的迁移，别人本地就"缺"它，`db push` 会因 "Remote migration versions not found in local" 拒绝，直到把缺的文件带进来(从 sibling worktree 拷)或等其合 main。**对 T4.5 交互迁移的处置**:已把它从 `20260602145934` 改名到 `20260603032138_crew_interaction_requests.sql`(最新时间戳，避免它夹在 billing 那几条中间造成乱序);带齐 sibling 文件后 dry-run 干净(只推我这一条)。**✅ 已于 2026-06-03 用户在场授权后 `db push` 应用**（只推了 `20260603032138`；read-only 复核 `permission_requests.request_kind/reply_text` 列 + `create_interaction_request/answer_interaction_request` RPC 都已在 DB 上）。**对称摩擦**:我应用后，别的在飞 session 本地会"缺"这条 → 他们下次 `db push` 会被同样的 "not found in local" 拦，需带进本文件或等其合 main。schema.ts **故意没 regen**——并行期 regen 会把别 session 的 billing 表一起 dump 进我的 schema.ts(污染),且 `crew-interactions.ts` 走 untypedRpc 本就不需要 regen 才 typecheck 绿;regen + 收口 untypedRpc 留到合 main 时。
- **#185 IAP 服务端 webhook** — App Store Server Notifications V2 真实签名校验、refund/REVOKE 处理；当前只有 stub。需要 Apple Developer 后台配置 + 真实 sandbox 测试，必须人工。
- **#186 Lemon Squeezy refund 完整路径** — webhook 已落 issuePack 入账，但 refund/dispute 反向冲销在 v2 ledger 上还没串通；需要联调 LS test mode。
- **#188 Board 后台 — 计费 v2 管理面板** — `de4a62c2` 起了 admin grant/claw-back RPC + 简单 board UI，但仍缺：pack 列表/手动作废、refund 列表、用户 wallet 详情视图、批量 grant。需要 Board 端 UI 设计 + RPC 扩展。
- **#189 iOS wallet v2 完整 UI** — `5c63ce76` 只落了 preview 入口（PNC packs view），缺购买流（IAP product picker）、refund 历史、share-index 详情、群池贡献 UI。需要设计师定稿后再做。
- **#190 v1 计费完全退役** — `551296e9` 边缘 cutover 已让 v2 authoritative，但 v1 表 (`wallets`, `wallet_ledger`) 还在 schema 里；30 天观察期后需要一次清理迁移 + 删除 dead code 路径。

#### 🟡 后续 session 即可

- ~~**T3.2 Codex runner**~~ **（2026-06-02 已解决，#202）** — codex 契约已调研（codex-cli 0.133.0 `codex exec --help`）：argv 补 `--json`（JSONL 事件流，对标 Claude `--output-format=stream-json`）+ `-m/--model` 透传；launch / env 白名单 / discovery 早就是 kind-无关的复用层，不需要单独抽象。argv 测试覆盖 codex `--json` + 双 runner model 透传，11/11 绿。**上层 JSONL 事件解析层也已落地（#203，2026-06-02）**：`RunnerEventParser`（`apps/pendingcrew/Sources/Mac/LocalRunner/RunnerEventParser.swift`）把两种 schema flatten 成统一 `RunnerEvent`，接进 `CrewSessionRun.events` + session 窗口「转写」tab；fixtures 取自实跑 claude-cli / codex-cli 0.133.0，9 测试绿。Phase 3 本机 runner 闭环真实缺口已清零（剩 T5.3 真机 E2E QA，另列）。
- **T4.5 完整实现** — ~~`ceba5619` 只落了设计文档，实际代码一行没动~~ **（2026-06-01 对账更正：此说法已过时）**。服务端 P0 已落地：`c7b2cd2d` ship 了 `SessionProxyDO`（`apps/edge/src/durable-objects/session-proxy.ts` 534 行）+ `session.command`/`session.state` ws 协议 + 路由 + 单测 + wrangler 绑定。**仍缺客户端侧**：iOS/Mac 无任何 SessionProxy 订阅代码、PendingCrew runner 不发布到 DO（手机→Mac 推命令、Mac session 镜像未接）。当前是"服务端打底好、客户端未接"的半截桥，不是"一行没动"。
- **T4.5 runner WS 遥控命令应用 — cancel + send_prompt 已接通，permission 未** — runner-side 实时层（`SessionProxyClient` actor，connect→subscribe→边跑边推 `session.state`，退避重连 + ping）。**`cancel`** → `cancel()`，端到端。**`send_prompt` 已接通**（`<this branch>`）：`handleRemoteInbound` 取 payload `{text}` → `enqueueFollowUp` → `CrewSessionRun` 在当前回合退出时（`turnDidExit`）drain 队列，起 `claude --resume <agentSessionId> --print --output-format=stream-json` 续跑回合把 steering prompt 经 stdin 喂进去，复用 agent 上下文 + 缓存前缀（实测 cache_read 42422/create 494）。机制四连实验全绿（见 `docs/crew-runner-steering.md`）。**permission 这块已重新定性（2026-06-02，见 spec §10 重写 + `docs/superpowers/plans/2026-06-02-crew-interaction-human-in-loop.md`）**：原"逐动作 manual-mode 暂停/批准"作废——session 跑 auto/bypass，不做逐动作门禁；要的是**交互**（computer-use 授权/问问题/要判断），经 `--mcp-config` 注入的 `ask_human` MCP 工具阻塞 → captain 自决/沿 DAG 溯源到真人。`SessionProxyClient` 现有的 `sendPermissionDecision` 出口先留着（将来交互卡回复可复用），但 manual-mode 暂停那套不做了。**两个需要盯的点**：① **lifecycle 变更**——`finish()`→`finalize()`，现在**队列 drain 完才 finalize**（关 server row + WS）；无 steering 时队列空、`turnDidExit`→`finalize` 与原 one-shot 字节一致，但**有 steering 时 server session 会跨多回合保持 running 到 drain 完**，这条改了 T4.5 runner-chain 真机验过的"首回合退出即 completed"语义，需真机复验。② send_prompt 只能对**活着的**session 生效（finalize/cancel 后拒绝）；快任务窗口窄。③ 仅 Claude（Codex resume 返回 nil → fail loud）。**hook-注入的 ambient steering 通道已建**（`<this branch>`）：`SteeringChannel`（LocalRunner）造一个**仓库外**托管目录（app caches）放 `settings.json`（注册 `UserPromptSubmit` hook）+ 纯 stdout `hook.sh`（cat steering 便签，无 jq 依赖）；`LocalCodingAgentLaunchSpec.claudeSettingsPath` → `--settings <path>` 挂到首回合 + 每个 resume 回合；viewer 的 `set_steering`（payload `{text}`，空=清除）经 `CrewSessionRun.setSteeringNote` 写便签；`RemoteSessionsView` composer 发送按钮的菜单出「设为/清除常驻便签」。session 结束 teardown 托管目录。headless 四点全绿（注入无读、live 重读、尾部不破缓存、`--settings` 让工作目录零 `.claude` 污染）。**需真机复验的点**：① `--settings` 挂到了 logged 首回合（验证过的 launch 命令变了，跟 lifecycle 改一样要真机过）；② 用户的 crew 工作目录若自带 `.claude/settings.json` + 自己的 hooks，与我们 `--settings` 的合并行为没在真实 repo 验过（spike 是空目录）。
- **T4.5 Mac viewer 实时层已接，viewer→runner 发命令 UI 未建** — `7b71fb21`：`RemoteSessionsView`（PendingCrew Mac viewer）在 3s HTTP 轮询的持久转写之上叠了**实时层** —— 选中 session 开 `SessionProxyClient(role:.viewer)`，消费 `states` 流（`SessionStateSnapshot`，对账 runner 的 `SessionState.dict()` fan-out），顶部 banner 实时显示 status/lastEvent/eventCount。轮询保留为兜底（WS 连不上就退回原行为）。**viewer 发命令已部分接通**（`<this branch>`）：`SessionProxyViewerOutbound`（session.command / permission.decision）+ `SessionProxyClient.sendCommand/sendPermissionDecision` + `RemoteSessionsView` 的「停止」工具栏按钮发 `cancel`；runner 侧已 apply cancel，所以 viewer→runner 停止是端到端闭环。**viewer 发命令已基本接通**：`RemoteSessionsView` 现有「停止」（cancel）+ **steering composer**（输入框 + ⌘↩ 发 `send_prompt`，payload `{text}`），runner 两条都 apply，所以 watch（banner）→ steer（composer）→ stop（toolbar）在 PendingCrew 单 app 双窗即可端到端演示。**仍缺**：permission 卡片 approve/reject 走 `sendPermissionDecision`（出口已在，差 manual-mode UI + runner 侧解阻塞）。iOS PendingBot viewer 是另一条并行线（那边还在 HTTP 轮询）。
- **T4.5 authenticated E2E 未真机验** — 已验：codec + viewer 解码（21 SessionProxy 测试）+ `makeConnectRequest` wss/ws 升级 + auth header + role query + inbound 路由 + macOS app 编译 + **生产路由活性**（`wss://api.pendingname.com/v1/sessions/<uuid>/proxy/connect` 无 bearer → 401，证明 client 拼的 path 在 prod 命中 handler）。**未验**：带真实 device-grant 的完整 WS 往返（runner 连上推 `session.state` → Mac viewer banner 实时显示 → 之后 viewer 发命令）。需登录账号 + 真实 session 行；mint `pdg_` token 要走 iOS 扫码 approve，headless 起不了，留作 T5.3 真机 QA 的一部分。**注**：现在 runner + Mac viewer 两端代码都在，真机验时可在**同一台 Mac 两个窗口**（一个起 session 当 runner，一个开 RemoteSessionsView 当 viewer）直接看实时 fan-out，不必两台设备。
- **T4.5 交互（ask_human）——"agent 问人"半边已代码全通，"人答 + captain 溯源"半边未建** — spec §10 + plan `2026-06-02-crew-interaction-human-in-loop.md`。已落（`<this branch>`）：① **P1** CLI 权限档进 argv（`AgentPermissionMode`；顺手修了 runner 不传 `--permission-mode`→headless `default` 卡死的隐患，默认 `auto`）；② **edge 数据面**——迁移 `20260603032138`（`permission_requests` 加 `request_kind`/`reply_text`/status `answered` + RPC `create_interaction_request`/`answer_interaction_request`）+ 路由 `crew-interactions.ts`（runner 发起 / long-poll / 人答）；③ **MCP server** `ask-human-mcp.cjs`（POST→long-poll→返回回复，mock-edge 实跑验过）+ `InteractionChannel` 写 mcp.json + `--mcp-config` 进首/resume 回合；④ **prompt §10**（zh+en）改成 ask_human。机制全验：claude `auto` 自动放行 MCP 工具、`--mcp-config` 阻塞工具走通、`.cjs` 进 bundle。**未建/未验**：① **迁移没 apply + schema.ts 没 regen**（`crew-interactions.ts` 走 untypedRpc 才 typecheck 绿；落地前从主 worktree `db push`+`types:db`+收口）；② **人答的 UI**——卡片已由 RPC 发到 crew 群聊（direct-to-human），但**渲染 + 回复入口**没建（自然落点是 iOS PendingBot 交互卡=T4.3 卡片扩展，属并行 session 域；或 Mac 加个答复面板）；③ **captain 三角判断 + 沿 DAG 层层溯源**（spec §10.3-10.5）没做——现在是直发责任主体；④ 真实 edge auth 的端到端（要登录 + 迁移 apply）。**砍掉**：自建逐动作审批门禁 / Agent SDK `--permission-prompt-tool`（CLI 不存在）。
- ~~🔴 **`get_crew_whiteboard` 在 service-role 下 `RAISE 'auth required'`**~~ **（2026-06-03 已修，G1）**。根因：RPC 体内 `caller_id := auth.uid(); IF caller_id IS NULL THEN RAISE 'auth required'`，但 edge 一律用 **service-role client** 调它（auth.uid()=NULL）→ 必 500。这是 crew 上下文注入（白板→session，T4.1/T4.2 核心通道）真跑就炸的潜伏雷（同 `client_message_id` 类）。**修法**：`GET /v1/crews/:crewId/messages`（中栏）+ `GET /v1/sessions/:id/inbox`（runner）两处都改成**直接读 `crew_announcements` 表**（访问门禁在路由层已做），不再调该 RPC。已部署（`9f4234eb`）。RPC 没删（仍带 guard，将来 authenticated 调用方可用）。
- 🟡 **白板→session 注入闭环（G1-G3）只编译/端点 live，没真机跑过** (2026-06-03)。runner（`CrewSessionRun.runCrewContextPoll`）每 4s 拉 `/inbox`，把白板近况 + 未读 mailbox 渲染成 `<crew-whiteboard>` 块写进 `SteeringChannel` 的 crew-context slot（UserPromptSubmit hook 每轮 tail 注入，缓存安全），注入后 mark-delivered。**未验**：① agent 真跑时确实读到该块并按相关性行动（prompt 工程对不对、会不会被当成"任务"误执行——digest 里加了"这是参考不是任务"的提示，但没真测）；② 4s 轮询 + mark-delivered 的时序（同一条消息会不会在 mark 前重复注入一两轮）；③ 仅 logged Claude（Codex 无 steering channel → 不注入,BYOK 同）。归 T5.3 真机 QA。
- 🟡 **右栏「持续对话」回合完成后不续上下文（resume-after-complete 缺口）** (2026-06-03)。三栏重排后右栏 = composer-first 常驻 session（`CrewSessionWindowView`，spec §9 落地）：第一条消息零配置起 session，运行中再发 = `enqueueFollowUp` 走 `--resume` 续回合（保上下文 + 缓存前缀）。**但** claude `-p` 单回合跑完、队列空 → `finalize`（status=completed）。此后再发消息 `send()` 判 `status != .running` → **起一个全新 agent**（fresh context，丢历史）。所以「像 Claude Desktop 一直聊」只在**一个回合进行中持续发**时成立；agent 跑完闲下来后下一条消息会另起炉灶。真·持续对话要改 runner lifecycle：闲置不 finalize、下条消息 `--resume` 复活同一 agent session（`agentSessionId` 已存着，`startResumeTurn` 也在，差「completed 后还能 resume」这一段 + server row 不立即关）。属右栏体验的后续打磨，非阻塞。Codex 同理且更弱（resume 返回 nil）。
  - **（2026-06-02）iOS PendingBot 只读 viewer 已落地并真机验通（#204）** — `RemoteSessionsView.swift`（session 列表→push 转写，3s 轮询）+ `getCrewSessionEvents` / `CrewSessionLogEvent`，入口是 `CrewDetailV2View` 右上角 terminal 按钮（sheet）。镜像 Mac `RemoteSessionsView`（`acf9db29`）。**编译过 + 用户用骆店账号在 iOS 上打开 viewer 看到 test2 渲染（2026-06-02 验通）**。
  - **（2026-06-02）iOS viewer 实时层 + cancel 遥控已落地（#204 第二刀，编译绿）** — `SessionProxyClient.swift` + `SessionProxyProtocol.swift`（viewer-only 镜像 Mac `feat/t45-ws-transport` 的 SessionProxyClient）：viewer 连 `GET /v1/sessions/:sid/proxy/connect?role=viewer`（用 Supabase JWT，token 每次 reconnect 取 fresh），收 `session.state` → transcript 顶部实时 banner，工具栏「停止」按钮发 `session.command{kind:cancel}`。**仅 BUILD SUCCEEDED，端到端两设备 QA 未做**：要 Mac PendingCrew（带 `feat/t45-ws-transport` 的 runner 发布）起一个 **running** session 实时推 state，iOS 同账号 viewer 看实时 banner + 点停止能真的取消。wire 格式对齐 edge + Mac 已验证侧（Mac viewer 已验过发 cancel/收 state，`40870183`），实时层是 best-effort 装饰（连不上回退已验证的只读轮询）。**剩**：① 两设备 E2E QA（活 session）② permission.request/decision over WS（iOS 现走 HTTP T4.3 卡片，WS 实时通道未接）。
  - **（2026-06-02）PendingBot macOS 端 viewer 也落地（#204 第三刀，编译绿）** — PendingBot 是 iOS+macOS multiplatform 工程；把 viewer 所需的纯数据/网络/展示层抽成跨平台（`CrewSessionAPI.swift` / `SessionProxyClient` / `SessionProxyProtocol` / `CrewSessionPresentation.swift` 去掉 `#if os(iOS)`），新增 macOS UI `Sources/Mac/Views/MacRemoteSessionsView.swift`（Mac 三列 detail：crew 列表→session 列表→实时转写+cancel），接进 `MacRootView` 的 Crew tab。**iOS + macOS BUILD SUCCEEDED**。三端 viewer 齐：iPhone（已真机验只读）+ iPad（随 iOS universal，同代码，布局打磨待做）+ Mac（编译绿，**待登录骆店在 Mac app 真机看 test2 渲染**）。**copy-paste/DRY 注记**：Mac viewer UI 是 iOS `RemoteSessionsView` 的平台适配（HSplitView vs NavigationStack），逻辑重复但 SwiftUI 布局差异大，未强行抽共享 ViewModel；纯数据/网络/展示已抽共享。Mac 端 crew 其它业务（创建/群聊/详情）仍是 iOS-only，Mac 仅接了 viewer 这一刀。
- **T5.3 PendingCrew E2E QA** — BYOK 路径和 cloud 路径的端到端测试（创建 crew → 派单 → 收到结果 → 计费记账）从未真机跑通；只有编译过 + 单测覆盖。需要人工 QA pass。

### 部分/骨架级、需要补完

- **PendingBot 完整原生 Mac 版 — 2026-06-02 夜间进展(#212)** — 用户明确要完整原生 SwiftUI macOS(非 Catalyst)。架构:逻辑/数据/网络跨平台共享,UI 原生重画。夜间一口气接了 4 块,均两端 BUILD SUCCEEDED + 合 main:登录(MacWelcomeView+MacRootGate,Email OTP+Turnstile,**用户真机验通**)、机组 viewer(MacRemoteSessionsView)、消息(MacMessagesView + 跨平台 ChatDataSource,会话列表+1:1/群文字聊天+流式发送)、好友(MacFriendsColumn + FriendsDataSource,机器人+人类好友只读列表)。
  - **关键验证缺口(用户醒后必看)**:**Mac 真实 UI 渲染没截图核对**——agent 截不了 Mac 桌面(computer-use 掉线、screencapture 无屏幕权限)。已做的替代验证:① 所有 Supabase 查询的列名/FK/role 值用 live DB introspection 核对(messages.role 仅 user/bot、conversations_bot_id_fkey、user_unread_counts 列、user_bot_contacts FK 抄 iOS 已验证查询)② 命令行跑 Mac app binary 8s,stderr 无崩溃/无 401/无未捕获异常 ③ iOS 范本装模拟器截图确认跨平台抽取没退化。**但每个 tab 在 Mac 上实际渲染长啥样、点击交互对不对、流式聊天收发是否正常,需用户在 Mac app 逐 tab 真机过一遍**。
  - **各模块第一版简化(均记此)**:消息——无 Realtime(3s 轮询+发后 reload)、无附件/图片/语音、无 @提及、无群组 peer 解析、时间戳列刻意不 select(规避 Decodable 歧义);好友——只读,无点击进会话/头像图片(ServerImage iOS-only)/加好友/备注/排序;机组——仅 viewer,无创建/群聊/详情。
  - **DRY 注记**:iOS 的会话列表/消息加载逻辑内联在 `MessageTabView`/`ConversationView`(UIKit 耦合的 View),没法直接复用,所以 Mac 新建了 `ChatDataSource`/`FriendsDataSource` 跨平台 service 复刻同样的 Supabase 查询——查询逻辑与 iOS 有重复。未来可让 iOS 也迁到这两个 service 去重(改 iOS 范本有回归风险,夜间没动)。
  - **未做(夜间因复杂度+无法真机验时序而留)**:来信 tab(EnvelopeAPI:realtime-hub WebSocket + EnvelopeRun/Turn + thinking trace,最复杂)、机组完整(创建 crew 是写操作会污染 prod、群聊)、跨 tab 连贯交互(好友点击进会话需 ensure-conversation + SwiftUI 跨 tab selection 状态机,夜间无法验时序)、Realtime 推送(三端 Mac 现全轮询)、头像图片。


- **PendingCrew 后端单元测试** — `8e0eac32` 已记录：`apps/pendingcrew-server` 几乎没有单测覆盖，BYOK 路径切换、CrewStore reset、template store 三处都是裸代码。建议后续 session 补 vitest。
- **群权限矩阵 client 端消费** — `207d5203` edge 给了 `/v1/group-subjects/*` 路由，iOS / Mac 客户端还没真正消费；目前权限判定仍走旧 client-side 规则。
- **Mac 三栏壳的实际内容** — `c174f734` 是结构脚手架；middle column 的会话列表 + detail column 的消息流都还是 placeholder，等 IM 主路径打通后填。
- **First-launch disclosure modal 文案** — `280d5b7b` 走通了流程，正式文案待法务/产品定稿。
- **billing-v2 settleUsage CAS-loss retry** — `cbb4fb3f` 实现了重试，但极端高并发下的退避策略未压测；30 天观察期内若看到大量重试再优化。（注:billing-v2 settleUsage 已于 #209 整体退役删除,本条历史留痕。）

- 🟡 **计费 P2 throttle 档"降级"未实装（LLM 路径）** — `gateUsage`(`apps/edge/src/billing/usage-gate.ts`)已正确分出 4 档阈值(exhausted 硬停 / low / throttle / sufficient),`<5 PNC = throttle` 也正确返回,但 **throttle 时的"降级"动作没做**:计划里写的 OpenRouter `cost_quality_tradeoff=max` 经官方文档核实(<https://openrouter.ai/docs/guides/routing/routers/auto-router>)**只对 `model: "openrouter/auto"` 生效,且是 `plugins:[{id:"auto-router",cost_quality_tradeoff:10}]` 的 plugin 配置,不是顶层 `=max`**;本仓库 router 是纯 passthrough(把调用方 model slug 原样发),不走 auto-router,所以该参数对正常 slug 是 no-op。要真正"降级"得在 throttle 时(a)临时切到 `openrouter/auto`+plugin、或(b)切便宜模型 pin,并(c)关工具——这要把 threshold 信号穿过 `runChatTurn`/各 runner(memory/envelope/title/group)到 completion 构造处,跨多文件接线,本任务(Phase C)未做。**当前 throttle 等同 low(放行不降级)**,只是不会硬停。
- 🟡 **计费 P2 low 档"余额低"提醒未注入** — 阈值 low(<50 PNC)gate 正确放行,但"在下一条回复里注入余额低提醒(24h 去抖)"这个 UX 从未实装(billing-v2.ts 注释里只写了意图)。需要在回复渲染层加一个 threshold 信号通道 + 去抖。gate 层已就绪(`gateUsage` 返回 `thresholdState`),缺消费方。

- ✅/🟡 **计费 P2 群成本分摊(share-index)已重挂到 Polar/WalletDO**(2026-06-02,用户拍板"用 v2 共享池方法") — 计划 `docs/superpowers/plans/2026-06-02-group-wallet-polar-rehome.md`。已落:`billing/share-index.ts`(纯数学)+ 迁移 `apply_group_pool_spend`/`apply_group_contribution`/`apply_group_refund` 原子 RPC + `billing/group-wallet.ts`(contribute/refund/dissolve)+ 群消费在 router/群语音/sandbox 扣费后衰减 share_index + 端点 `/topup`(改 contribute)`/leave`(自退款)`/dissolve`。typecheck 0 + 523 测试。**剩余 🟡 尾巴(未做,见下三条)**:链式退款、漂移报警、`/leave` 不删 membership 行。
  - ✅ **链式退款覆盖群注资**(2026-06-02 完成,#210):`billing/group-wallet.ts clawbackFromGroups` —— Apple/Polar 退款先从用户各群 active 份额按 share_now 冲减(`apply_partial_withdraw` 缩份额+池 + `reduceCredits` 群 Polar,不返还用户)、再退个人剩余,平台只自担"已被群花掉"的部分。Polar `order.refunded` + RC `CANCELLATION` 两路接入。堵住"注资进群→退购买款→群留额度"漏洞。
  - ✅ **群池镜像漂移报警**(2026-06-02 完成,#210):`WalletDO.checkGroupPoolDrift` 在 alarm 对账时比对 `group_pools.total_remaining` vs Polar 群余额,偏差 > 1 PNC `console.warn`(不自动改写)。
  - ✅ **`/leave` 一步退群**(2026-06-02 完成,#210):退份额 + 清认缴(setPledge 0)+ service 直删成员行;群主拒退(须先转让/解散)。
  - ✅ **群 bot 异步回复前置 gate**(2026-06-02 完成,#210):`lib/group-dispatch.ts dispatchGroupTurn` 开头按群池+认缴聚合 `gateConversation`,exhausted 直接 `no_balance` 不发起 bot 回合(读失败 fail-open)。

- ✅ **billing-v2 退役完成(#209,2026-06-02)** — 删 16 文件:`billing-v2.ts`(settleUsage/packs)、`billing-v2-{group,pack,lemon,iap,iap-verify,refund,expiry}.ts`、pack 过期 cron;去掉 `/lemonsqueezy/webhook`·`/iap/*` 路由;`room-voice` OwnerRef→WalletOwner;清孤儿 env/cron。保留 `pnc_ledger` + `group_pools/contributions/pledges`。旧 packs/ledger 表留冷备。

- ✅ **`routes/me.ts /wallet/v2` 余额改读 WalletDO(2026-06-02)** — 余额/阈值走 `wallet.gate`,账本读 `pnc_ledger`,不再读已退役 packs 求和。

> ── 以下为 dashboard 栈接线(feat/dashboard-wiring)的待办 ──
#### 🟡 PostHog 行为事件 — 缺 server 端 seam 的事件（dashboard 栈 block 1）

边缘 PostHog 接线（`feat/dashboard-wiring`）已覆盖有服务端落点的事件：`message_sent` / `group_created` / `group_joined`(invitation+invite_link) / `voice_call_started`(1v1+group) / `voice_call_ended`(group) / `topup_succeeded`(iap+lemon webhook，`created:true` 时)。统一走 `lib/track.ts` 的 `trackEvent(c,...)`（fire-and-forget，无 PII）。**以下 spec 列出的事件在当前架构没有 edge 落点，未接，必须从别处补**（别当成"已全覆盖"）：

- **`signed_up`** — 用户/subject 创建是 Supabase signup 触发器（`me.ts:256` 注释提及），edge 无 signup handler。→ 由 iOS PostHog SDK 在登录/首启时 `identify` + 发，或加 DB 触发器→PostHog（P4，spec 的客户端侧）。
- **`bot_created`** — `routes/bots.ts` **没有 POST/create**，建 bot 是客户端直写 Supabase（仅 PATCH/GET/invite-links 在 edge）。→ 同上，由 iOS SDK 发，或 bots 表 AFTER INSERT 触发器。
- **`voice_call_ended`（1v1）** — 1v1 通话结束在 `RealtimeMeterDO`（计量 DO）里异步发生，route `/realtime/.../end` 是 no-op，edge 路由层无落点。→ 需要在 DO finalize 时发（DO 内 `capture(env,...)` 可用），未做。
- **群注资 / 认缴（`group_topped_up` / `group_subject_created`）** — `routes/group-subjects.ts` 有 `POST /:id/topup` 等落点，但该文件正被另一 session 改造（task #220-221 群钱包重构），为避免抢同一文件**本轮未接**；待群钱包改造落定后补 `trackEvent`。事件名已在 `AnalyticsEvent` 常量预留。
- **`topup_succeeded` 数据源随计费迁移** — 当前接在 billing-v2 iap/lemon webhook（仍是现行入账路径）。billing 引擎若迁到 **Polar**（见 memory `project_billing_outsourcing`），事件源要跟着搬到 Polar webhook，别留在退役路径上。



### 🟢 Grafana BI 依赖 `bi_ro` 只读角色 — ✅ 已解决（migration 20260602051354 建角色 + 20260604143012 正名 bi_ro）
- **发现**: 2026-06-03 · feat/dashboard-wiring
- **位置**: infra/grafana/（datasource provisioning 指向 `bi_ro`）
- **问题**: dashboard stack 第 5 块（Grafana 营收/钱包 BI）的数据源用 SELECT-only 角色 `bi_ro`，但本 worktree 里没有任何 `*metabase_readonly_role*` migration——角色不存在则数据源连不上。属于「依赖一个未落库的前置」。
- **影响**: Grafana 面板全部依赖此角色；未建角色前所有 dashboard 都是空的/连接失败。不影响主程序运行。
- **建议**: 补一条 migration 建 `bi_ro` 角色 + `GRANT USAGE ON SCHEMA pendingbot` + `GRANT SELECT` on（至少）`topups, billing_ledger, subject_wallets, subjects, group_member_billing, conversations, audit_log, users, bots, group_join_requests`；或手工 SQL 建角色。建好后在 Grafana Cloud 填 datasource 密码 + 确认 Supabase 网络放行（pooler 公网可达或配 PDC）。
- **状态**: 待办（前置依赖，需用户落库角色 + 配 datasource）

### 🟡 admin 控制台（apps/admin）依赖的 edge admin 端点尚不存在 —— dataProvider 指向"意图路径"，调用即 404
> **2026-06-08 重定位（`feat/board-console`，spec `docs/superpowers/specs/2026-06-08-board-console-cms-design.md`）**：本条记的"补一整套 `/v1/admin/*` 运营端点"方向已**作废**。重新定调:控制台从「运营仪表盘」纠正为「**内容/预设/配置管理台**」(board CMS)。下面 11 条里的 1-3(用户/Bots/会话浏览)归 **PostHog**、4-9(计费/钱包/账号)归 **Polar/RevenueCat**、10-11(人工协助/权限审批)归 **PendingCrew**(独立开源应用),**都不在中央后台建**。已落地:`/v1/board/preset-bots` 全 CRUD(requireAdmin + admin_audit before/after,经通用 `boardResource` 工厂),前端换 Ant Design、退役 8 个旧运营页。**仍待做(各自后续计划)**:P2 预设会话/群+预设来信(需建 `preset_letters` 表)、P3 tool 管理、P4 KV 配置类(模型目录/pricing/i18n/place_names)。下方原始清单仅作历史留档。
- **发现**: 2026-06-03 · feat/dashboard-wiring（dashboard stack block 4）
- **位置**: `apps/admin/src/providers/resource-map.ts`（`RESOURCE_ROUTES` + `ADMIN_ACTION_ENDPOINTS`，逐条标了 `exists:false`）、`apps/admin/src/providers/data-provider.ts`、`apps/edge/src/index.ts`（v1 路由挂载处，**当前无任何 `/v1/admin/*`**）
- **问题**: 新建的 Refine admin 控制台按 spec 要求"读写都过 edge、绝不直连 Postgres、前端不持 service-role key"，所以 dataProvider 把每个资源映射到 edge REST 路由。但**edge 目前没有 admin 路由面**：`users.is_admin` 字段在 DB 里存在，`@pendingbot/identity` 也导出了 `requireAdmin(...)`，但**全仓没有任何地方 mount 或使用它**。控制台为了不埋"假装能用"的 stub，把这些资源指向**意图中的** edge 路径并在代码里 `exists:false` 标注 + 页面渲染告警横条；调用当前会 404。
- **影响**: 控制台骨架可编译、可登录（Supabase Auth → JWT），但除下面两条已存在的 route 外，所有 admin 读/写页面都打不通真实数据，直到 edge 补齐这些端点。属于"先把前端接好、等后端落地"的刻意取舍，不是无声 stub。
- **已存在、控制台已复用的 edge 面（仅这两条）**:
  - `GET /v1/human-help-requests?status=...`（**requester-scoped**，按 `requested_user_id = caller` 过滤）+ `POST /v1/human-help-requests/:id/decision {decision: accepted|declined}`
  - `POST /v1/permission-requests/:id/decide {decision: approve|reject}`
- **控制台需要、但 edge 尚不存在的端点（完整清单，全部待办）**:
  1. `GET /v1/admin/users`（list）+ `GET /v1/admin/users/:id`（show）—— 用户清单（id/handle/created_at/subject），跨用户、需 is_admin。
  2. `GET /v1/admin/bots` + `/:id` —— bot 清单（visibility/model/owner）。现有 `/v1/bots` 是用户态，非 admin 列表。
  3. `GET /v1/admin/conversations` + `/:id` —— 会话清单/详情。
  4. `GET /v1/admin/billing/ledger` —— 计费台账读。**注意 spec 写的 `pnc_ledger` 视图在 schema 里不存在**；真实来源是 `pendingbot.billing_ledger` 表（+ `subject_wallets` 取每主体余额）。要么建 `pnc_ledger` 视图，要么端点直接读 `billing_ledger`。
  5. `GET /v1/admin/billing/group-pool` —— 群池/分摊读。**schema 里没有 pool/pledge 视图**；最接近的源表是 `group_billing_config` + `group_member_billing`，需要端点聚合或建视图。
  6. `POST /v1/admin/billing/wallet/grant` —— 钱包发放额度（写 `subject_wallets`/`billing_ledger` + `admin_audit`）。
  7. `POST /v1/admin/billing/wallet/clawback` —— 钱包回收（负 delta）。
  8. `POST /v1/admin/billing/ledger/adjust` —— 直接台账调整（entry_type=adjustment 等）。
  9. `POST /v1/admin/users/account-op` —— 账户操作（freeze/unfreeze/delete）。
  10. `GET /v1/admin/permission-requests`（list）—— 权限审批**列表**（decide 动作已存在，但没有 admin 列表读）。
  11. `GET /v1/admin/human-help-requests`（list）—— **admin-wide** 人工协助队列（现有那条只看 caller 自己被点名的，不是全局队列）。
- **建议**: 新建 `apps/edge/src/routes/admin.ts`，挂在 `/v1/admin`，第一道中间件 `requireSession()` 后接 `requireAdmin(c => SELECT is_admin FROM pendingbot.users WHERE id=c.var.userId)`，所有读用 `serviceClient` 跨用户查、所有写进 `admin_audit`（actor_id/before/after/ip/user_agent 已有列）。读端点返回 `{ items: [...] }`（控制台 dataProvider 已按此 normalize）。建端点时同步把 `resource-map.ts` 对应条目翻成 `exists:true`，并把本条状态推进。计费两个端点落地前先决定 `pnc_ledger` 视图建不建（spec 名 vs 实表名的口径要统一）。
- **状态**: 已重定位为 board CMS（见顶部 2026-06-08 note）。P0 框架 + P1 预设机器人已落地并双审/全量验证（edge 540 vitest + typecheck 绿、admin build 绿）；P2–P4 待后续计划。原始"补全 /v1/admin/* 运营面"方向作废。


- 🟡 **旧 per-conversation 分摊模型"连根拔"未完(invite 流耦合 + 物理 drop 待协调)** — `feat/ios-wallet-group`(2026-06-03,基于 `chore/retire-billing-v2`)。群消费结算早已切到责任 subject 的实缴池+认缴(`settleGroupSpend`),用户拍板 iOS+edge 连根拔旧 per-conversation `group_member_billing` 分摊。**本拍已做**:删 `lib/group-billing.ts`+测试(死)、删 `groups.ts` 的 `/billing|/cap|/participates` 三路由。**未做(耦合群邀请流 + iOS,独立一摊)**:(a) `groups.ts:groupBillingInviteSnapshot` 仍读 `group_member_billing` 生成邀请预览"分摊"文案,两处调用(创建群邀请 / 邀请预览)嵌进 invite 响应,iOS `FriendsTabView` 消费 `mode_label/invitee_participates/payer_count_after` —— 新模型无 per-conversation "participates" 概念,该快照前提已不成立,需解耦/移除并改 iOS 邀请预览 UI;(b) 接受邀请 handler 仍写 `group_member_billing`(seeding)+ 用 `group_member_invitations.invitee_participates`;(c) 物理 drop 迁移:`group_member_billing` 表 + `group_set_billing/cap/participates` RPC + `group_member_invitations.billing_snapshot`/`invitee_participates` 列。**(c) 必须在 `chore/retire-billing-v2` 部署、且 (a)(b) 解耦后再 apply**(生产 main 当前仍 live 在旧模型上,提前 drop 会 500)。建议作为独立 task 整体收口,别塞进钱包 UI 这一拍。

- 🟡 **iOS 群钱包/个人钱包 UI 依赖的 edge 端点只在 `chore/retire-billing-v2`,未合 main** — `feat/ios-wallet-group` 基于 `chore/retire-billing-v2`(75 commits ahead of main)。新加的 `GET /v1/group-subjects/:id/wallet` + 已有的 `/pledge`/`/withdraw`/`/leave`/`/dissolve` + `/wallet/v2`(micros+null ledger)都在该分支,**main 上没有**。iOS 改动编译不依赖 edge,但**运行期端点 404 直到该 billing 分支部署**。合并/部署排序:iOS 钱包 UI 必须随/在 billing 分支之后上线,不能单独先合 main。本 feat 分支应并入 `chore/retire-billing-v2`(或与之同批合 main),不走独立合 main。

- 🟢 **群部分取出 `/withdraw` 流式回合诚实小角** — spec §5:流式回合最终成本要回合结束才精确,若有人正流式中途取走,极端下池子在末笔扣款落地时可能短一点点;overdraft 缓冲 + 新回合过门禁兜着,预发布可忽略。记此备查。

- 🟡 **billing-v2 / v1 退役后的 DB 孤儿全清单(表 + RPC + 触发器)** — 摸查于 2026-06-03(`feat/billing-obs-killswitch`)。新计费只读 `pnc_ledger / group_pools / group_contributions / group_pledges / subjects / group_subject_members`(+ `billing_config` 的 markup/threshold),余额真相在 WalletDO→Polar。以下是退役 billing-v2 + provider 转向后**线上库仍在、但新模型不读**的工件,按"能否直接 drop"分层。**记录不自动删**(数据销毁性;且部分在生产 main 仍 live,须等 `chore/retire-billing-v2` 部署后才能 drop)。

  **A. 纯孤儿(无任何活代码路径,可随 #226 一并 drop):**
  - 表:`billing_ledger`、`group_billing_config`、`group_billing_custom_shares`、`ledger_entries`、`packs`、`topups`、`refund_events`(退款现走 `pnc_ledger`)
  - RPC:`billing_admin_grant`、`billing_credit`、`billing_debit`(仅被死函数 `lib/billing.ts:billingDebit` 调,无活调用方)、`billing_debit_subject`(仅被死函数 `debitSubject` 调)、`billing_issue_codes`、`billing_v2_admin_adjust`、`group_set_billing`、`grp_topup_wallet`
  - 触发器/触发函数:`on_user_billing_signup` + `billing_signup_bonus()`/`billing_signup_bonus_trigger()`(写 `packs`,新模型不读 → 详见 #244)

  **B. 半死(代码仍碰,但模型已废 → 属 #226 收口,drop 前须先解耦):**
  - `group_member_billing` 表 + `group_member_billing_freeze_trg`/`_group_member_billing_freeze_trigger()` —— `routes/groups.ts:67/403` 仍在群邀请/加入流里 SELECT/INSERT
  - `subject_wallets` 表 + `subject_wallets_sync_updated_at_trg`/`tg_subject_wallets_sync_updated_at()` —— `lib/billing.ts:getSubjectBalance` 仍被 `routes/me.ts` 调(很可能展示陈旧值,真相已是 WalletDO/Polar)

  **C. 活着但很可能还在充旧钱包模型(同 signup bonus 的"孤儿入账"病,需决策/重建,非纯删):**
  - `billing_redeem` RPC + `redemption_codes` 表 —— 兑换码功能经 `routes/me.ts` 活调,但兑换大概率仍写 billing-v2/`subject_wallets` 而非 Polar credit。要么重建到 Polar(注册送同款,见 #244),要么暂时下线。**别当纯孤儿删**。

  **死 edge 代码(随 drop 一起清):** `lib/billing.ts` 的 `billingDebit`/`debitSubject`/`getSubjectBalance` + `balance-cache.ts`(v1 KV 余额缓存)+ 相关 `getBalanceGateState` 旧 1v1 gate 路径。

  **建议**:把 A 段整体并入 #226 的物理 drop 迁移(同一 `chore/` 批次);B 段先做 #226 的 invite 流/me.ts 解耦再 drop;C 段与 #244 一起拍板(送不送 / 兑换走不走 Polar)。drop 顺序硬约束:`chore/retire-billing-v2` 必须先部署到生产,否则提前 drop 会让线上旧路径 500。
  **状态**:待办(已登记,等 #226/#244 推进时按 A/B/C 分层落)

- ✅ **billing-v2/v1 孤儿 A 段已 drop(2026-06-03 部署)** — 上条「全清单」的 **A 段**(表 billing_ledger/group_billing_config/group_billing_custom_shares/ledger_entries/packs/topups/refund_events + 8 孤儿 RPC + on_user_billing_signup 触发器)已随迁移 `20260603112148_drop_billing_v2_orphans` apply 到生产(先部署新 edge 代码再 drop,无 500)。**C 段**(兑换/送)已重建到 Polar:`billing_redeem` 退化为只校验(迁移 20260603111613),送(35 PNC)/兑换入账走 `lib/billing-grant.ts` 的 ensureCustomer+grantCredits,均受 BILLING_ENABLED 门控。**残留**:ensureCustomer 的 409(已存在客户)吞掉分支未经 sandbox 实测(P0 spike 已验证全新客户的 create+grant+balance;409 支 dormant,billing 关时不触发)——启用计费前用 token 跑一次 spike 坐实即可。**B 段**(subject_wallets / group_member_billing + invite 流 + iOS)仍是 #226。

- 🟢 **死代码全项目扫描(2026-06-04)— 安全区已清,Swift 区待对应 session 清** — `feat/billing-obs-killswitch`。用 workflow fan-out 8 region 扫了全仓死代码(60 项)。
  **已清理(edge/supabase/packages 安全区,15 项,typecheck+vitest 守门,484 测试绿)**:删 `lib/balance-cache.ts` 整模块 + `getThreshold`/`_resetThresholdCache`/threshold 缓存簇 + `billingDebit`/`billingDebitSubject`(已在退役批) + `gateUsage`/`GateResult`(throw 版前身) + `decayShareIndex` + `isNativeAdapterStyle` + `_resetCatalogCache` + `_resetWebToolPriceCache` + `SessionUser`(identity) + 6 个废 IAP/LemonSqueezy ApiErrorCode + crews.ts 的 `ApiErrorCode` re-export + index.ts/http-error.ts 过时注释 + 死脚本 `dev:web`(无 apps/web)。
  **安全区暂留(review,价值低/需判断,未删)**:`models.ts` 4 个 LMArena* 过度 export + `crews.ts:accessibleSubjectIds` 过度 export(去 `export` 关键字即可,低价值,crews.ts 属 crew session territory 故未动);`identity/jwt.ts:ALLOWED_JWT_ALGS` 过度 export;`sandbox.ts:deleteSandbox`(0 调用但注释称"会话拆除时调"——**误导注释**,可能是未接的 future teardown,建议要么接上要么删注释);`supabase` 的 `v_audit_daily`/`v_audit_monthly` 视图(edge 0 引用,可能留给 BI,删需迁移);`createPolarClient`/`PNC_EVENT_NAME` 是**假阳**(被同文件 polarFromEnv 内部用,勿删)。
  **✅ 已查清(非 bug,已删)**:`persona-cache.ts` 的 `deleteCachedChatMemo`/`deleteCachedBotNote` 当时疑似"缓存从不失效"。追查确认**不是 bug**:chatMemo/botNote 只由 `memory.ts` 的 `refreshChatMemo`(:496)/`refreshBotNote`(:344)写,且这俩 refresher 改完 DB 后**立即 write-through**(`putCachedChatMemo`/`putCachedBotNote`)——缓存始终新鲜,无需 delete 式失效。这俩 delete helper 是当初连着 put/get 顺手写的多余件,已删除。

- 🟡 **iOS/macOS/crew Swift 死代码清单(22 项)— 交接给 pendingbot / pendingcrew session(本 lane 不动)** — 同一次扫描的 Swift 区。Swift 无廉价 unused 检测,以下均 rg 证据(符号全仓仅定义),**删前 owner session 必须 xcodebuild 验证**(可能有 storyboard/动态引用)。多数像被取代的旧面:
  - **旧 billing-v1 iOS 钱包面(疑被 WalletV2View 取代)**:`Features/Me/WalletView.swift:WalletView`、`Networking/BillingService.swift`(fetchBalance/fetchLog/redeem/fetchSummary/applySilentUpdate + Balance/LogEntry/LogPage/Summary/RedeemResponse 等嵌套类型)——若 UI 已切到 WalletV2View/GroupWalletView,整个 BillingService + WalletView 可能整体死。**高价值核查**。
  - **BigScreen 实验面**:`Shared/PendingBotBigScreenApp.swift`(PendingBotBigScreenAppView / PendingBotCrewWorkspaceView)+ `Shared/PendingBotSharedModels.swift` 一大批 `PendingBotCrew*` / `PendingBotBigScreenTab` 类型(疑 BigScreen 原型残留)。
  - **其它 0 引用**:`Features/Me/AccountsView.swift:AccountsView`、`Components/TabTitle.swift:TabTitle`、`Mac/Views/MacEnvelopeView.swift:MacEnvelopeDetail`、`Models/APIModels.swift` 的 `MeProfile`/`AiPick`、`pendingcrew .../LocalRunnerPlaceholder.swift:LocalRunnerModule`。
  - **过时常量**:`Features/Me/WalletV2View.swift` 的 `channelLabel` 还留 `iap_ios`/`iap_macos`/`lemon_squeezy` 分支(渠道已转 Polar/RevenueCat)。
  - **构建产物入库**:`apps/ios/build/**`(.xcarchive/.ipa)疑被 git 跟踪——应 gitignore + 移除。
  建议各 session 在自己分支用 Xcode 的 unused 检查/编译告警逐个核掉,别由计费 lane 跨改。

- 🟡 **Mac 三种登录已接通+编译过,但 Apple/Google 真实登录回合未验(邮箱 OTP 已可信)** — `feat/mac-login-align`(2026-06-04,#253/#212)。Mac `MacWelcomeView` 重画对齐 iOS,三种登录代码都接上:邮箱 OTP 走跨平台 `EmailSignIn`(**已可信**,与 iOS 同一条路);Apple 走原生 `ASAuthorizationController`(NSWindow anchor),Google 走 GoogleSignIn-iOS 的 macOS target(`signIn(withPresenting: NSWindow)`)。iOS+macOS 双端 `xcodebuild` 均 BUILD SUCCEEDED,但**Apple/Google 在 Mac 上的真实 sign-in 回合没跑过**(本 session TCC 屏幕录制权限被拒,连截图都做不了,更没做真登录)。两个**外部配置依赖**会决定它们能否真的成功,启用前必须坐实:
  - **Google macOS OAuth client**:`Info.plist` 的 `GIDClientID`(`842392349572-…apps.googleusercontent.com`)+ reversed URL scheme 是当初按 **iOS 型** OAuth client 配的。Google 原生 macOS 登录要求 client 的平台/bundle 匹配,iOS 型 client 在 macOS 上**可能**报 redirect_uri_mismatch / invalid_client。需在 Google Cloud Console 给 `com.pendingname.pendingbot` 加/确认一个 **macOS 型** OAuth client(或确认现有 client 接受 macOS bundle),并把其 client id 填进 Supabase Authorized Client IDs。**没验证过 = 可能一点就挂**。
  - **Sign in with Apple**:entitlement(`com.apple.developer.applesignin`)已在共享 `PendingBot.entitlements`,EU 库 `/auth/v1/settings` 实测 apple enabled(见 progress 2026-06-04 Phase 4)。Mac App ID 需带 SIWA capability(自动签名通常带);真机/真账号点一次确认即可。
  **验证清单(启用 Mac 端 Apple/Google 前必跑)**:① Mac GUI 构建(非 headless,否则签名回落 ad-hoc → Keychain -34018,session 存不住,和反复误诊的那个坑同源)② 真点 Apple → 成功落 supabase session ③ 真点 Google → 同上(先确认 macOS OAuth client)。**在坐实前别对外声称 Mac 三种登录可用**——当前只到"编译过 + 邮箱 OTP 同路可信"。

- 🟡 **新钱包(WalletV2View / MacWalletView)无兑换码入口** — `feat/mac-login-align`(2026-06-04,#253)。删死的 v1 `WalletView` 时连带删了它独有的兑换码 UI(`BillingService.redeem`)。新钱包 `WalletV2View`(iOS)/`MacWalletView`(Mac)都**没有**兑换入口。后端 `billing_redeem` 已退化为只校验、送/兑换入账走 `lib/billing-grant.ts`(见 billing 退役条目),即后端仍能兑换,但**两端 App 都没有让用户输入兑换码的地方**了。删除本身不算回归(v1 WalletView 早已零引用、不可达),但"用户如何兑换码"是个产品缺口:要么在新钱包加兑换入口(iOS+Mac),要么确认兑换只走别的渠道(如深链/网页)。待用户定。

- 🟡 **Mac 加好友/建管机器人原生重画落地,但裁掉了 iOS 的若干高级面 + 无扫码** — `feat/mac-login-align`(2026-06-04,#212)。`Sources/Mac/Views/MacBotManagement.swift` 新增 macOS 原生 `MacAddFriendSheet`/`MacAddBotSheet`/`MacCreateBotSheet`/`MacManageBotSheet`/`MacModelPickerSheet`,逻辑全复用跨平台 SupabaseStack/APIClient/AccountStore/ModelCatalog,沿用同一 RLS。双端 BUILD SUCCEEDED。**有意未对齐 iOS 的部分(缺口)**:
  - **建机器人只支持单模型**:iOS `CreateBotSheet` 的 step1 是 `ArenaModelPoolEditor`(价格区间池 / 多模型竞技场,iOS-only),Mac 没移植——Mac 建的 bot 一律单模型。建/管里都没有 arena 入口。要补需把 arena 池编辑器抽成跨平台或 Mac 重画一版。
  - **管机器人裁掉多项 iOS 子面**:iOS `ManageBotSheet` 还有 语音通话 toggle、分段气泡(output_mode,走 PATCH /v1/bots 拍 KV 缓存)、机器人时区 picker、被邀请人管理(InviteListEditor / InviteContactPickerSheet)、分享机器人(BotSharePage 邀请链接/二维码)、以及 BotConfigView(主/识图模型、联网搜索、写信设置、自动回看、技能)。Mac 第一版**只做** 改名/模型/可见性升级/slug/删除。其余 Mac 端均缺。
  - **加好友/加机器人无扫码**:Mac 无摄像头,`MacAddFriendSheet` 只做输入号码/隐私号路径;`MacAddBotSheet` 只是邀请制说明页——iOS 的 QR 扫码 + universal-link 兑换 invite token 流(resolve/redeem /v1/bot-invites)在 Mac 没接。后续可补「粘贴邀请链接」入口走同一 resolve/redeem(BotInviteAPI 已跨平台)。
  - **无头像选择器**:建/管机器人都没头像上传(iOS 走 iOS-only 图片选择器),Mac 仅 emoji 占位。可后续用 NSOpenPanel 接。
  - **MacBotSlugRule 是 iOS `BotSlugRule` 的手抄副本**(后者在 `#if os(iOS)` 里不可见)。两处规则需手动保持同步;服务端 slug 约束才是真源。
  **均为真机/真账号才能端到端验**:写操作(建/改/删 bot、发好友申请)本 session 只编译校验,未跑真实回合。

- 🟡 **Mac 聊天/会话列表已接 cache-first(复用 iOS LocalDatabase),但"把编排抽成共享 store 两端共用"仍待 iOS 真机回归** — `feat/mac-login-align`(2026-06-05,#212)。Mac `MacChatView`(消息)+ `MacConversationListColumn`(会话列表)现在镜像 iOS 的 cache-first:打开先从跨平台 `LocalDatabase` 读缓存秒开 → 拉服务端 → 用 iOS 同款 `replaceMessages`(单事务 / cmid-aware upsert)+ `upsertConversations` 写回。编排落在跨平台 `ChatDataSource`(`cachedConversations`/`cachedMessages` 读缓存,`listConversations`/`loadMessages` 写回),复用 `MessagesFetch`/`ConversationFetch`/`LocalDatabase`,**没有新建 Mac-only 缓存表**。双端 BUILD SUCCEEDED。**缺口 / follow-up**:
  - **未跑真机回归**:cache-first 的"先缓存秒开 → 网络覆盖 → 写回"在本 session 只编译校验,**没在真实登录态 / 真机上跑过**(秒开是否真即时、写回与 Realtime 刷新是否有竞态、离线再开是否仍有内容、replaceMessages 删-插事务中途无空窗——均未观测)。需用户在场做一次。
  - **编排仍是两套(iOS 在 `ConversationView+Loading`/`MessageTabView` 里内联,Mac 在 `ChatDataSource` 里镜像)**:本 session **刻意未动 iOS shipping 代码**(避免无真机回归时改已验证的 iOS View)。把两端的 cache-first 编排抽成一个**完全共享的 store**(读+网络+diff/merge+写回一处,两端只接 UI)是正经的下一步,但那是重构 iOS 已验证路径,**必须等用户在场做 iOS 真机回归**再动。当前镜像有结构性重复:cache 写回的 row 映射、error 抑制策略、sender 解析在 iOS 与 Mac 各写了一遍,column/policy 改了要两处同步。
  - **未读数 cached 首屏为 0**:`cachedConversations` 缓存行不带 unread(iOS 的未读真源是 server-truth unread store / `user_unread_counts`,不在 conversations 表),所以纯缓存首屏的红点要等网络刷新才出。可接受(和 preview/排序一拍 settle),但和 iOS 完全一致需把未读也落进某个 Mac 可读的缓存通道。
  - **缓存消息无附件**:`LocalDatabase.messages` 没有附件列,cached 行是纯文字,图片/文件 chip 等 `loadMessages` 网络往返解析——与 iOS 缓存 hydrate(`attachments: nil`)一致,非 Mac 独有缺口。

- 🟡 **本地 Swift 单测 / 交互式二进制 smoke 在"超长 session"末段被宿主 PTY 耗尽卡住 —— 验证方法学缺口,非代码缺陷** — `feat/session-crew-comms`(2026-06-08,#274)。`xcodebuild test`(macOS)报 `Pseudo Terminal Setup Error / IDEPseudoTerminalDomain ErrorCode 7 Errno 6 (Device not configured)`。根因经只读诊断坐实:`kern.tty.ptmx_max=511`,而托管本 agent 的宿主进程(`Claude` app,本次 PID 1321)在长 session 里**泄漏 ptmx master fd**,单进程占满 **510/511**,xctest runner 分不到新 PTY → 启动失败;同源地,直接 `--mcp-serve` 跑**阻塞读 stdin** 的真二进制也卡(harness 后台化下 stdin 不绑文件 EOF + PTY 退化)。**不能** kill 宿主(=断 session),**不擅自** `sudo sysctl -w kern.tty.ptmx_max=…`(改系统设置需用户授权)。**当前 workaround**:自包含 Foundation 模块(`LocalApprovalStore`/`LocalWhiteboardStore`/`McpServer` 等)用 `swiftc <真实源文件> + 断言 main` 编 CLI driver 直接跑(不读 stdin、不需 PTY),step ① 已 21 断言全绿;XCTest 文件保留为 Xcode GUI / CI(PTY 充足)下的 canonical 验证。**待用户在场时**:在新鲜 session(或重启宿主 app 释放 ptmx fd)下跑一次完整 `xcodebuild test` 收口,或评估给宿主 app 修 PTY fd 泄漏。**影响**:长 session 末段无法用 xctest 自验 Swift,只能 swiftc-driver 兜底——验证仍真实,但不是 canonical runner。

- 🟡 **Mac 附件:无相机;composer 文本框是简化 SwiftUI 孪生(无硬件 Return-as-send / 无键盘帧跟踪)** — `feat/tri-platform-ui`(2026-06-08)。把 `ComposerView`/`ChatActionSheet`/`ConversationView+Attachments` 去 fence 跨平台:相册(PhotosPicker,macOS 13+)+ 文件上传两端共用,图片编码加了 `PlatformImage.jpegData(quality:)`(iOS UIImage.jpegData / macOS NSBitmapImageRep)+ CoreGraphics 降采样。**有意 iOS-only 的缺口**:
  - **相机**:`CameraPicker`(UIImagePickerController)+ ChatActionSheet 的"拍照"tile + `ingestCameraImage(UIImage)` 全 `#if os(iOS)`。Mac 无摄像头,合理;但若以后要 Mac 端"从 Continuity Camera / 截图"取图,需另接(非本 task 范畴)。
  - **composer 文本输入**:iOS 的 `ComposerTextField`(UITextView 子类)做了硬件 Return-as-send、Shift/⌥+Return 换行、IME marked-text 防误发、6 行封顶 + 键盘帧逐帧跟踪(inputAccessoryView)。macOS 孪生只是一个 `TextField(axis:.vertical).lineLimit(1...6)` + `.onSubmit`,**没有** IME 防误发细节、没有键盘帧跟踪(Mac 不需要)。功能可用但不是逐特性对齐;若 Mac 端要更精细的输入行为需再做。
  - **宿主未接**:`ComposerView` 本身已跨平台编译,但它在 iOS 经 `ChatComposerAccessory`(inputAccessoryView,仍 `#if os(iOS)`)挂载;Mac 用 `.safeAreaInset` 挂 composer 是 ConversationView task 的事,本 task 未接。`ConversationView+Attachments.swift` 在 macOS 的唯一残留报错是对仍 fenced 的 `ConversationView` 的 cross-ref(extension 找不到类型),属预期。

- 🟡 **Mac ConversationView 跨平台:无语音通话入口 + composer 缺横幅 + Crew/Permission 决定 no-op** — `feat/tri-platform-ui`(2026-06-08)。把主聊天 `ConversationView` + 全部 extension + `SubConversationView` 去 fence 跨平台,Call 切片(CallCenter/CallSession/GroupCallSession/IncomingCallStore/ActiveVoiceCallStore)内部 `#if os(iOS)` 围栏。双端:iOS BUILD SUCCEEDED;macOS 整模块仍因**其它未迁切片**(FriendsTabView/LetterComposeSheet 的 `.navigationBar`/`.tabBar`/`.topBarLeading/Trailing` 不可用 + Crew/Contacts API)bail,但 Message 切片自身 macOS 0 error。**有意 iOS-only 的缺口**:
  - **无语音通话入口**:header 的 phone/群语音按钮、pre-chat 致电按钮、`activeCallBanner`(进行中通话条)、CallKit 冷/热启动 auto-join(`consumePendingAutoJoinIfMatches` + IncomingCallStore `.onChange`)在 macOS 全缺。Mac 聊天功能完整但不能发起/接听语音。要补需先把整个 Call 切片跨平台。
  - **macOS composer 只挂裸输入行,无横幅**:iOS 经 `ChatComposerAccessory`(inputAccessoryView,仍 iOS-only)把 composer + freeze/continue/@-mention 三类横幅挂在键盘上;macOS 走 `.safeAreaInset(.bottom) { macComposer }` 直接渲染跨平台 `ComposerView`,**没有移植** 冻结提示 / 续聊确认 / @-提及候选这三个横幅。Mac 端这些交互(群冻结提示、跨 bot 续聊决定、群内 @-提及补全)暂时不可见。要补需把 ChatComposerAccessory 的横幅区抽成跨平台,或在 macComposer 里重画。
  - **Crew/Permission 决定在 macOS 是 no-op**:`decideCrewProposal` / `decidePermissionRequest` 依赖 `APIClient.CrewProposalDecision` / `.PermissionRequestDecision` 嵌套类型 + decide 端点,都在仍 iOS-only 的 Crew 切片(`Features/Crew/CrewAPI.swift` 整文件 `#if os(iOS)`)。卡片视图(CrewProposalCardView/PermissionRequestCardView)已跨平台会渲染,但 macOS 点批准/拒绝是空实现(给了 no-op stub)。Crew 切片迁移后需把这两个决定方法解 fence。
  - **均未真机/真账号回归**:本 task 只编译校验(iOS sim build + macOS error 扫描),没在真实登录态跑过聊天回合 / 语音 / 决定卡片。

- 🟡 **macOS 全模块编译打通(milestone),但 3 处功能在 Mac 上是 placeholder / no-op** — `feat/tri-platform-ui`(2026-06-08)。收尾最后一批 macOS 编译 blocker:加了 `ToolbarItemPlacement.platformLeading/platformTrailing`(iOS topBar* / macOS cancellation+primary);解锁 `ContactsAPI`、`GroupAvatar`、`RelativeMessageTime`(含 `TimeSeparatorPill`)、`SkillsView`、`BotCapabilitiesView`(全是纯 Foundation/SwiftUI,只用已有跨平台 shim);修 `BotManagement` 的 `glassEffect` `#available` 漏了 `macOS 26.0`。**双端 BUILD SUCCEEDED**。**有意 iOS-only 的 Mac 缺口**:
  - **二维码名片**:`MyQRBusinessCard`(UIKit 图像渲染 + PHPhotoLibrary 存图 + UIPasteboard)仍 iOS-only,`MyQRSheet` 在 macOS 显示「二维码名片暂不支持 Mac」占位。Mac 用户看不到自己的加好友二维码。要补需把 QR 渲染抽成 `PlatformImage`/CoreImage 跨平台版。
  - ✅ **群设置(已解决,`feat/tri-platform-ui`,2026-06-09,双端 BUILD SUCCEEDED)**:整个 Group slice(`GroupSettingsView`/`GroupWalletView`/`GroupQRCard`/`GroupJoinView`/`JoinRequestsInboxView`)已去 `#if os(iOS)` fence,机械替换 shim(`inlineNavTitle`/`platform{Leading,Trailing}`/`platformListStyle`/`platformDetents`/`Clipboard.copy`/`platformKeyboard(.number)` 新增、`QRCode.image` + `Image(platformImage:)`),相机 `QRScannerView` 仍 `#if os(iOS)`(Mac 走邀请链接)。ConversationView 群设置 navigationDestination 占位已换真实 `GroupSettingsView(conversationId:)`,Mac 进群后可改成员/昵称/免打扰/退群。顺手修 `GroupQRCard` 的 `glassEffect` `#available` 漏 `macOS 26.0`。
  - **推送活跃会话标记**:`PushService`(UIKit/PushKit/UserNotifications)iOS-only;ConversationView 的 `.onAppear`/`.onDisappear` 里 `PushService.shared.activeConversationId` 读写 + 相机 `ingestCameraImage` 的 `.onChange(of: cameraImage)` 都 `#if os(iOS)` 围栏。Mac 无推送前台 banner 抑制(无所谓,Mac 没接推送)/无相机(合理)。
  均未真机回归 —— 本 task 只 iOS sim build + macOS build 双绿,没在真实登录态跑过。
- ✅ **[已修 2026-06-12 #285] `boardResource` DB 错误一律 500 无法区分 409** — `dbError()` 映射 PG `23505`(unique)/`23503`(fk)→ 409 `conflict` 带冲突列 detail,其余仍 500。下方原条目留档:
- 🟡 **`boardResource` 把所有 DB 错误一律压成 500 `database_error`,无法区分 409 conflict** — `feat/board-console`(2026-06-08)。`apps/edge/src/lib/board-resource.ts` 的 CRUD 工厂在 list/get/create/update/delete 各处都是 `if (error) return jsonError(c, 500, 'database_error', …)`,把 Postgres 错误码全部抹平。preset-bot 表的 `slug` 唯一约束冲突(以及将来任何唯一/外键约束)会以 500 返回,而非语义正确的 409 `conflict`,前端无法据此提示"slug 已被占用"。P1 只有 preset-bots,管理员手输 slug 撞车概率低,可忍;**P2–P4 换表(尤其有用户可见唯一键的资源)若需向前端暴露唯一冲突,需扩工厂**:按 `error.code === '23505'`(unique_violation)/ `'23503'`(fk_violation)映射到 409 并带上冲突列信息,而不是无脑 500。

- ✅ **[已修 2026-06-12 #285] `boardResource` list 硬编码 `.limit(500)` 静默截断** — 改 `?limit(≤500)/?offset` + `count:'exact'`,返回 `total`/`has_more`,前端 data-provider 已读 total。下方原条目留档:
- 🟡 **`boardResource` list 硬编码 `.limit(500)` 是魔法值且静默截断** — `feat/board-console`(2026-06-08)。`apps/edge/src/lib/board-resource.ts` 的 LIST 路由写死 `.limit(500)`,既是裸魔法数(无命名、无注释来由),又**无 count / has_more 信号**:行数超 500 时直接静默吃掉尾部,前端无从得知列表被截。preset-bots 量小(模板行数十级)不会触顶,当前安全;**P2 换大表(如模型目录、未来用户可见的大集合)前应提为 `opts.listLimit`(显式可配)或加真正的分页**(cursor / offset + `count: 'exact'` 回传总数 / `has_more`),否则换表那刻就埋下"列表只显示前 500"的隐性数据缺失。

- 🔴 **PendingCrew 的 crew 组织/DAG 还建在 edge 上,违背「本地为家」定调** — `feat/crew-session-inspector`(2026-06-13,用户指出)。接合 v2(`2026-06-10` spec)定死:PendingCrew 结合云端**只有两件** —— ① 跨端遥控;② bot/人类账号经 edge 信箱作为成员加入 crew。**其余一律本地**。但现状里 crew DAG / 责任分账还是 edge-first 旧设计:`LocalBackend.attachParent` 直接抛 `notSupportedInByok`,DAG 只能在登录态 + edge crew 上做;edge 侧 `crews.ts` 还留着 `create_crew_with_captain` / `attach-parent` RPC / crew 详情带 parents/children/shares 等一整套。这是早期 edge-first 设计没跟着 local-first 重构搬回本地的残留(用户原话「之前模型瞎弄的」)。**本次已开始纠偏**:DAG 折叠树改纯本地实现(`LocalCrew` 加 parentCrewIds + `LocalCrewStore.attachParent` + 本地树 UI,不碰 edge)。**尾巴**:edge 侧那套 crew-org 代码(RPC/路由/Swift EdgeBackend.attachParent)需系统排查——哪些是「遥控/信箱」必需保留、哪些是纯组织模型残留该退役;别再往 edge crew-org 上加东西。需要一次专门的「edge crew 代码按本地为家收口」审计。**✅ 2026-06-16 部分收口**（审计 R1，merge `7852a687`）：edge bot-reply 的 **captain 编排面**（start_crew/start_session/create_child_crew/recruit_temp_bot 工具 + captain persona 注入 + crew-comms 唤醒 + crew-proposal decide）已全退役（`captain_bot_id` 字段保留——客户端建 crew 的活路径）。**剩**：crew DAG / 责任分账的本地化（`EdgeBackend.attachParent`、crews.ts 的 `attach-parent` / parents-children-shares 一整套）仍是 edge-first，待续。

- 🟡 **PendingCrew session inspector + 聊天右侧栏 只编译验证,GUI 冒烟待用户** — `feat/crew-session-inspector`(2026-06-13)。重置到 main(三端共享 UI 迁移后)重落 inspector + QQ Mac 右侧栏(待审批上/成员下)。macOS BUILD SUCCEEDED,但点 session 头像弹 inspector / 「+」多开 / 待审批就地答 / 成员行选中 等交互**未在 GUI 跑过**(headless 跑不出);备份分支 `backup/crew-inspector-prerebase` 留旧实现。改动全 `#if os(macOS)`,iOS/iPad 未单独 build。

- 🟡 **inspector 拖到最大宽度时聊天栏被挤破(用户暂缓)** — `feat/crew-session-inspector`(2026-06-13,用户指出后决定先放)。inspector 首帧被切的**根因已根治**:中栏 detail 的 `navigationSplitViewColumnWidth(ideal:560)` 太贪,present 时霸占整个容器宽不给 inspector 让位 → 去掉 detail 的**所有**宽度约束(任何 navigationSplitViewColumnWidth / `.frame(minWidth:)` 都会让它重新不让位、复现被切),让它当 NavigationSplitView 天然弹性填充栏,inspector 一开即正常(用户已确认)。**残留尾巴**:inspector divider 拖到最左(inspector=max 560)时聊天栏被挤过窄而破,且用户实测**即使 sidebar 收起也破**(不止"三栏塞不下窗口",detail/聊天内容在某窄宽下自身溢出)。受限:detail 不能加任何宽度下限(会回退主 bug),没法用列约束卡拖动上限;`.inspectorColumnWidth` 的 max 是静态值,降它会连"有空间时也不能拖宽"一起牺牲。**待办**:要么让 CrewChatView 内容能优雅压缩到很窄不溢出,要么找不约束 detail、又能随可用宽度动态封顶 inspector 的法子。诊断法:GeometryReader + 遍历 `NSSplitView.arrangedSubviews` frame 落盘。

- 🟢 **PendingCrew 里 "BYOK" 已是「本地模式」的过时别名** — `feat/reset-local-data`(2026-06-15)。死的 provider-key 脚手架(BYOKConfig / 三个 keychain account / AppModel.byokConfig / LocalSetupView 三个 SecureField / credential `case byok`)已删(零消费/零调用)。**但"本地模式"自身的标识符仍带 BYOK 命名**:`PendingCrewBackendError.notSupportedInByok`(三处真 throw)、合成 subject id `local-byok`、合成发言者 id `local-byok-user`、machine `kind:"byok"`、`PendingCrew (BYOK)` 显示名,以及大量把 BYOK 当"本地模式"用的注释。这些是**活的代码**,语义已从"自带 key"漂移成"驱动本机 CLI"。**不简单 rename 的原因**:`local-byok` / `local-byok-user` 已写进本地 JSON 存档(local-crews.json / 白板),改名会让现有本地数据成孤儿、破坏 `CrewSenderResolver` 的"自己气泡"识别 —— 需配数据迁移。延后;记录以免后人误以为"BYOK 还活着"。正名时:统一改 `local`/`localMode` 语义 + 给持久化 id 做一次迁移(老 id 读时 map 到新 id)。**附带 litter**:删掉读 `byok-anthropic/openai/gemini` 三个 keychain account 的代码后,老 dev 安装上若曾填过 key,这三项会成孤儿(无人再清)—— 纯 pre-launch dev litter,无功能影响,正名时顺手清即可。

- 🟡 **Mac 侧栏「其它机器组」内容在本机看不到 —— 缺遥控投影** — `feat/sidebar-by-machine`(2026-06-15)。侧栏改成按 machine 分组(本机置顶 + 账号其它机器,登录后真注册本机 + 真拉 `GET /v1/machines`)。**有意缺口**:本机 crew 本地优先(用户明确否决「登录即上云」),每台机器对自己的 crew 本地为家、**不镜像进 edge**,所以从这台 Mac 看「其它机器组」时拿不到它们的 crew 内容 → 组内只显示一行「遥控查看（稍后）」,不伪造列表。要在一台设备上看/控另一台机器的 crew(尤其 iPad→本机),是**遥控投影**的活,属 [#242 遥控 v1](task)(task_request 走 relay,代码落、E2E 未验)。本次只做到「机器可被寻址 + 真注册/真清单 + 按机器分组」。遥控投影落地后,把"其它机器组"的空提示换成实拉到的 crew(edge `GET /v1/crews` 已带 `machineId`,投影侧按机器分桶即可)。
  - **附带**:`CreateCrewSheet` 的预选 machineId 参数没做(spec 列了但本机「+」默认就是本机、无影响)——等其它机器组要带「+」(遥控建 crew)时再补这个参数。

- 🟢 **PendingCrew test bundle 的 standalone @testable import 依赖 app 先 build** — `feat/sidebar-by-machine`(2026-06-15,实现期发现)。`PendingCrewTests` 是无 host-app 的 standalone bundle(`project.yml`:把一批纯 Foundation 源码直接编进 bundle),但其中 6 个 Codex 测试文件(`CodexProtocolTests` 等)用 `@testable import PendingCrew`。后果:**clean DerivedData 下首跑 `xcodebuild test` 会先因这些文件找不到 `PendingCrew` 模块而编译失败**,必须先 build 一次 app target 产出 `.swiftmodule` 后再跑 test 才绿(本次 MachineGroupingTests 首跑即踩此坑,build app 后即过)。新加的纯逻辑测试(如 MachineGroupingTests)**不要**用 `@testable import`、改走"源码直接编进 bundle"那条路即可绕开。根治需统一 test bundle 策略(要么全 host-app injection、要么全 compile-in),属既有结构债,非本次引入。

- 🟡 **事件驱动唤醒(Phase 4b)已落代码但当前 app 状态下不实际跑** — `feat/crew-comms-rework`(2026-06-15)。新加 `CrewRealtimeClient`(连 hub `/v1/realtime-hub/conv/:crewId`)+ `CrewMailboxWaker`(收 `.changed`→拉 `getSessionInbox`→空闲则注入唤醒→mark-delivered)+ 纯决策 `CrewMailboxWakeLogic`。唯一接线点是 `CrewSessionWindowView.runQueuedSession`(真 server link 的登录态路径),而它整条 `autoClaimLoop` 被 `edgeQueueBindingReady = false` 门住(本地 crew id 在 edge 没对应行,等接合 v2 block-3 信箱重建本地↔edge 绑定才翻开)。**后果**:手动起的 session 现状恒 `serverLink = nil`(`startSession` L642 写死),不走 waker;唯一会 attach waker 的 `runQueuedSession` 又不被调。所以**唤醒链路目前全程 dormant**,只有 block-3 绑定 + `edgeQueueBindingReady` 翻 true 后才活。这是预期中间态(与既有 crew-org local-first 收口/edge 绑定那条 🔴 同源),记此以免后人以为「Phase 4b 接好就能用」。**E2E 尾巴**:两个 live session 的 @→唤醒(hub 帧真到、idle 真判、注入真进 claude PTY / codex turn、mark-delivered 真消费)**未验证** —— 只到「编译 + 纯逻辑单测 + 双 build/test 绿」。block-3 绑定落地后需补一次真账号双 session E2E。另:claude 的 `isBusy` 恒 false(PTY 无 turn-state),依赖 claude 自身输入排队把 mid-turn 注入当下一条 prompt —— 这个假设也待真机确认。

- ✅ ~~**群聊「回复某条消息」的 `reply_to` 字段 edge 端尚未接收 —— Swift 已发但被 zod silently strip**~~ **（已闭合 #377,commit `b0128b5d`/`8d8aaa12`）**：edge `CrewMessageBody` 现已收 `reply_to` 并落 `attachments` jsonb 的 `in_reply_to`,`mapMessageToEntry` 统一透出;中栏气泡经 `CrewReplyReferenceResolver` 从已加载 entries 本地解析渲染被回复引用条。以下为历史背景。 — `feat/crew-comms-rework`(2026-06-15,Phase 6 实现期发现)。任务前提说"edge `/v1/crews/:id/messages` 已支持 `reply_to`",但实查 `apps/edge/src/routes/crew-comms.ts` 的 `CrewMessageBody`(L244)**没有** `reply_to`/`replyTo` 键,zod 会把它 strip 掉(对齐 codex 协议那条"凭印象写的字段"的坑)。本次按"不动 edge"约束处理:① Swift 链路(`PendingCrewBackend.postCrewMessage` + `EdgeBackend`/`LocalBackend` + `PendingCrewAPI`)已全部加 `replyToId` 参数,API body 前向兼容地带上 `reply_to`(edge 现在 strip,补 schema 后自动生效);② **回复真正生效的部分**是「自动 @ 原发送者」,走 `mentions`(edge 已支持)所以两端都管用 —— 人回复某条 session/人类消息时,原发送者会被定向 @ 到;③ LocalBackend 把 `reply_to` 记进本地白板 `LocalWhiteboardMessage.inReplyTo`(已落库,但中栏气泡**暂未渲染**被回复引用)。**尾巴**:(a) edge `CrewMessageBody` 需补 `reply_to` zod 字段 + 落库(`messages` 行或 `crew_announcements.payload`),否则登录态 crew 的 reply 引用不持久化;(b) 中栏气泡渲染"回复了 X 的某条"引用(本地 `inReplyTo` / edge 字段都需要 UI),本次只做了 composer 顶部的回复横幅,未做时间线里被回复条的视觉关联。属跨 edge+客户端的活,本 task(只动 pendingcrew)范围外。

## 2026-06-15 旧心智模型审计 — 新增条目

> 全量发现见 `docs/stale-model-audit-2026-06-15.md`(9 路并行 subagent 考古,52 条)。此处只登记**此前未记债**的活跃项;已记项(多账号隔离「客户端多账号本地隔离只靠登出擦库」、voice PND 单位「通话内 voice_cost 实时预览还在用 v1 PND markup」、v1 billing 冷备「v1 billing 表 + 死函数在 cutover 后留作冷备」、BYOK 命名漂移、edge crew-org 收口 🔴「PendingCrew 的 crew 组织/DAG 还建在 edge 上」、`recruit_temp_bot` 无消费方)在审计报告里引用对应条目。

- 🔴 **相机扫码加群结构性失效(D2 后旧群号码与邀请链接并存)** — 新 `/g/<token>` 群二维码 scanner(`MessageTabView.swift:1466-1529` `handle(value:)`)不识别(只认 `/b/`+`/c/`)→ 扫码加群走不通,落旧 `POST /v1/groups/join`(`groups.ts:680`,`group_join_request_create(p_handle_value)`,不记 invited_by)或被当加好友。`decisions.md` D2 现状核实只标了 universal-link presenter 未接,**漏了相机扫码不识别**。必须先补 scanner 的 `GroupShareLink` 分支再退旧 join 路径,否则退了扫码加群完全失效。详见审计 R2。

- 🔴 **`/v1/me/balance` + `getBalance()` 读 billing-v1 僵尸列** — `me.ts:168-182` + `billing.ts:95-110` 读 `users.balance_credits`(WalletDO/Polar 切后无写入方,冻结在 `20260529141318_billing_v2_cutover` 时刻);iOS 已不调(`BillingService.swift:3-7` 注释 WalletView 已删)。#209「me.ts 改读 WalletDO」漏了 /balance 这条。删端点 + `getBalance` + `balance_credits`/`lifetime_*_credits` 列(随 Y7 cleanup 迁移)。详见审计 R3。

- 🔴 **4 处内联 const prompt 漏迁 Langfuse(违反 no_hardcoded_prompts)** — `lookback-runner.ts:36` `LOOKBACK_INSTRUCTION`(**就在 #247 那次提交里被落下**)、`vision.ts:184` `SUMMARY_PROMPT`、`group-bot-intro.ts:80` `systemPrompt`、`builder.ts:177/180` `BUBBLE/SINGLE_INSTRUCTIONS`(borderline)。#247 真源切 Langfuse(`prompt-loader.ts` 已 fail-loud 无 fallback)但漏迁这几处,仍是内联 const 发给 LLM。抽进 Langfuse + `PROMPT_NAMES`。详见审计 R4。

- 🟡 **WelcomeView 两模式选择 + LocalSetupView 死壳(双端不可达 + 反事实文案)** — 2026-06-10 拆双轨后 macOS `AppModel.isConfigured` 恒 true → 直进 authenticatedRoot,`WelcomeView` 两模式分支永不渲染,`enterLocalMode`/`localModeSelected`/`LocalSetupView` 全死;文案「一次选定后本版不可切换」是 06-10 前旧心智。删 macOS 分支 + LocalSetupView,或留作未来「显式选模式」入口(需确认)。详见审计 Y1。

- 🟡 **`runtime_location` 派生列被当事实源在侧栏每行渲染 location tag(与 #369 冲突)** — `CrewDAGTreeView.swift:137,151-160` `locationTag` 仍每行贴「本机」标,但 #369 已定「侧栏按 machine 组织、去掉每行 location tag」(crew 已视觉嵌在所属 machine 组下)。既有「crew machine 收口 — runtime_location 降为派生镜像列」条记了派生列但没点出此渲染残留。详见审计 Y2。

- 🟡 **审批 store 仍裸轮询(白板已事件化,审批没跟上)** — `CrewCenterView.swift:23`(`captainTick` 2s)+ `SessionApprovalCardsView.swift:24`(`tick` 1.5s)轮询 `LocalApprovalStore`;crew-comms-rework P5 白板已改 `whiteboardChanges` 跨进程目录监听 publisher,同套监听本可覆盖 `LocalApprovalStore`(`<dir>/<crewId>.approvals.json` 同目录)。非紧急(廉价文件读)。详见审计 Y3。

- 🟢 **DB 3 个 dead-but-not-dropped 对象** — ① `usage_events` 表(billing-v2 孤儿,同批 `packs`/`ledger_entries`/`refund_events` 已 `20260603112148` drop 唯它漏,无 INSERT/SELECT);② `ai_picks` 表(`0001_init.sql:502`,自 init 从未接代码,**疑似胎死需确认有无未来计划**);③ `temporary_group_meta.cloud_machine_id` 列(二次被取代→fly→machine_id,0614 drop peer/fly 时漏带)。合一条 cleanup 迁移。**注**:`progress.md:406`「packs/ledger 留冷备」措辞与现状不符(packs/ledger 已删,真正留下的是 usage_events)。详见审计 Y7。

- 🟢 **两条 user-facing 文案承诺已删功能** — `BotManagement.swift:151,1454` footer 仍写「…盲评后能在『我 → 模型竞技场榜单』看到偏好」,A/B 盲评 UI + MeTab 榜单已随盲盒转型连根删。改盲盒话术。详见审计 G1。

- 🟢 **`seed-public-skills.mjs:77,79` 用 legacy env `SUPABASE_SERVICE_ROLE_KEY`** — 补进「Supabase legacy anon/service_role key 仍在项目里启用」那条的遗留消费者清单(原条目漏列此脚本,停用 legacy key 时会被漏)。改 `SUPABASE_SECRET_KEY`(同权)。

- 🟢 **`GroupCallTransport.swift` 6 行空占位死文件 + 失实「必须保留」注释** — 注释称 pbxproj 仍引用故不能删,实为 `project.yml` 目录 glob 自动收录,删文件 + `xcodegen` 即可。详见审计 G2。

- (注释/命名/spec 引用漂移 G3–G16 共十余处不单列,随对应代码改动捎带清,清单见审计报告;含 captain 编排 spec 注释、BYOK 命名、codex「待实现」、freeze 横幅注释、slug 旧注释、board 门禁注释、WorldRouter 命名、`decisions.md` R1、`users.is_admin` 疑似 dead 列)

> **处置状态(2026-06-16,`chore/stale-model-audit`,26 commit / 5 次合 main,main `48ea5179`,✅ 全线收口)**:审计全部处置完成 —— R1(edge bot-captain 编排全退役)/R2/R3/R1.4/G1/G2/Y1/Y2/Y3/G4–G15 + **R4**(5 个内联 prompt 迁 Langfuse + seed prod)/ **Y4**(语音 PNC 单位)/ **Y7**(DB cleanup db push:usage_events/cloud_machine_id/4 个余额列/is_admin+2 RLS+审计触发器)/ **G16**(is_admin)/ **ai_picks** + **balance_updated_at** drop。edge typecheck 0 + 616 vitest + 三端 build + 部署 prod(`70230cdc`)+ 冒烟零 500 全绿。`captain_bot_id` 经核**保留**(客户端建 crew 活路径,非残留)。**唯剩端到端真验尾巴**(pre-launch 无真流量):captain 退役群聊回复 / R4 getPrompt / Y4 voice 待真触发。

- ✅ ~~**PendingCrew Mac inspector 首帧列宽被切**~~ **（已根治 2026-06-17,commit `033b7e15`,computer-use GUI 实测通过）** — 用户连问两次根因、要"别再回来",故没停在 window-nudge(治标)上,做了结构性根治：**把 session 终端从 `.inspector` 整个搬出,放进 detail 列里的 `HSplitView`(底层 NSSplitView)确定性分栏** —— 列宽首帧即确定性协商,整类"展开左侧被切、要手拖 divider"消失,以后再改终端内容/列宽也不重演;中间那版 `InspectorFirstFrameRelayout` ±1 窗宽 nudge 已删。**GUI 实测**(最窄 minWidth 窗口):开 inspector → 进终端模式,左侧头像竖条+内容首帧即完整、无需手拖;拖 divider 重排正常。**总教训**:SwiftUI `.inspector` 对"宽度敏感的常驻内容"本就不可靠(present 当帧只测一次内容宽、之后不重测);这种场景别用 `.inspector`,用 `HSplitView`/`NSSplitView`/三栏 NavigationSplitView 等确定性分栏。**根因留档**:回归触发是 `fix/crew-captain-terminal`(2026-06-15 晚把 inspector min/ideal 300/400→360/480 喂 11pt 紧凑字体 TUI 的列数,顶过了"detail 弹性 + 终端低抗压缩"那套隐式平衡仅有的 ~60pt 窄余量);更早那次"detail 去贪婪列宽"根治是真的、只是一直骑在窄余量上不稳。`MacRootView` 旧注释曾谎称 `CrewSessionWindowView.resyncInspectorDivider` 兜底,该函数从未存在。
