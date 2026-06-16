# 旧心智模型全项目审计 (Stale Mental Model Audit)

**日期**: 2026-06-15 · **分支**: `chore/stale-model-audit` · **方法**: 9 路并行 subagent 考古,各 own 一个已废弃决策方向,带核实过的 ground truth + 「先验证再下结论」铁律(防止被旧注释/旧 spec 带跑)。

> **触发**: 用户指出 `feat/captain-orchestration`(给 edge bot-reply 的 captain 挂 `post_to_crew`/`request_permission`)是按旧心智做的——captain 在技术接口上不特殊、审批归 claude code/codex(session)、captain 不需要 bot-reply 专用工具。顺藤摸瓜,对整个项目做一次「哪些设计/逻辑还按已废弃决策实现」的系统审计。

## 执行摘要

总计 **52 条发现**(🔴 9 · 🟡 13 · 🟢 18 + 12 条「反向核实=干净/有意保留」)。两个维度(**群语音**、**DB 迁移账本**)被确认是**最干净**的转向(几乎零残留)。残留高度集中在 **edge crew captain 编排子系统**(整体建立在 2026-06-10 已作废的「edge-bot captain」心智上)。

**最关键的 5 条**(建议优先处置):

1. 🔴 **edge 仍会唤醒 edge-bot captain 跑 bot-reply 群回合** —— `crew-comms.ts:564` 收到 crew 白板消息后 `dispatchGroupTurn` 唤醒 `captain_bot_id`,与「captain 唯一形态=本地 session」直接冲突。这是 #241(已宣告作废)的活代码。
2. 🔴 **相机扫码加群结构性失效** —— 新 `/g/<token>` 群二维码相机扫不识别(scanner 只认旧 `/c/`),落到旧 `/v1/groups/join` 共享码路径或被当成加好友。用户可见 bug。
3. 🔴 **`/v1/me/balance` 返回 billing-v1 僵尸余额** —— 端点 + `getBalance()` 仍读 `users.balance_credits`(WalletDO/Polar 切换后无写入方,冻结在 cutover 时刻),iOS 已不调但端点活着返回过期值。
4. 🔴 **4 处内联 const prompt 违反 no_hardcoded_prompts** —— #247 迁 Langfuse 时漏迁,其中 `LOOKBACK_INSTRUCTION` 就在 #247 那次提交里被落下。
5. 🟡 **`start_crew` 仍把提议 bot 写成 `captain_bot_id`** —— 这正是 🔴#1 的唤醒目标来源;captain 字段在新模型下的归属需产品决策。

---

## 处置进度(2026-06-16,`chore/stale-model-audit`,6 commit 验证全绿)

- ✅ **R1.1/R1.2/R1.3/R5 — edge bot-当-captain 编排面全退役**(`7852a687`,净 -1341 行,typecheck 0 + 623 vitest)。用户拍板「全退役 edge captain + start_crew」。删 start_crew/start_session/create_child_crew/recruit_temp_bot 工具 + captain persona 注入(bot-reply+builder) + crew-comms 唤醒 + crew-proposal/decide 端点 + 相关 prompt-name/错误码。
  - **边界澄清(更正原审计)**:`captain_bot_id` 字段 + `create_crew_with_captain` RPC + `POST /v1/crews` **保留** —— 调研发现它们是**客户端主动建 crew 的活路径**(`system_generated` 分支建一个 captain bot 作 crew 的 captain 身份,iPad 客户端拿 `captainBotId` 显示 captain card / 接 composer),**非 bot-reply 残留**。原文「captain_bot_id 字段停用待 drop」更正为:**不能裸 drop**(破坏 iPad 建 crew)。若要让 crew 彻底不带 captain bot 身份,是更大的客户端联动改造 → 记 tech-debt 待定。
- ✅ **R1.4** post_to_crew/request_permission bot-reply 死工具(`39a3948b`)。
- ✅ **R2** 相机扫 /g/ 群码走 per-inviter(`cd31e9f6`,iOS build 绿)。
- ✅ **R3** /v1/me/balance 僵尸端点(`9be5497d`)。
- ✅ **G1** 盲评/竞技场榜单失效文案(`6c21722a`)· ✅ **G2** GroupCallTransport.swift 死文件(`15a1950b`)。
- ✅ **R6**(session-world-model captain 渲染):随 `captain_bot_id` 保留而**保留**(它渲染 crew 的 captain 身份,不再是残留)。

- ✅ **Y1/Y2/Y3 + G4–G15 长尾**(`3b1389a1`/`04006cc9`/`d1e06b07`/`0ae8b77a` pendingcrew + `d3d0ea65`/`973fd616` edge + ios 注释 commit):Y1 WelcomeView 双模式死壳 + LocalSetupView 删、Y2 侧栏 DAG location tag 删(对齐 #369)、Y3 审批 store 去轮询(接目录监听 publisher,与 whiteboardChanges 同模式)、G11 crew-interactions untypedRpc 收口 typed、G4/G5/G6/G7/G8/G9/G10/G12 注释命名漂移。**三端 build 全绿**(Mac + iPad + iOS)+ edge typecheck 0 + 623 vitest。
  - Y2/G13 留尾:`CrewDetailInspector`/`CrewListView`(iPad 平铺)的 location label 保留(#369 冗余理由不适用单行详情/平铺);`RuntimeLocation` enum + fly/peer 占位因此保留。G4 仅改反事实文案,`local-byok` 标识符不动(需数据迁移)。

- ✅ **R4 / Y4 / Y7 / G16 全部处置完成**(merge `4e74e093`):**R4** 5 个 prompt 迁 Langfuse(seed prod 5 个 production 版本 + 部署 worker `70230cdc` + name 匹配核实)· **Y4** 语音预览改 `usdToPncMicros`(PNC micros、no markup,与扣费同口径;edge+iOS,删 markup 函数族 getMarkup/usdToPnd/...)· **Y7** DB cleanup **已 db push prod**(drop `usage_events`/`cloud_machine_id`/3 余额列/`is_admin`+2 RLS+审计触发器,重建 `users_ensure_subject_trg` 移出 3 列)· **G16** `is_admin` 随 Y7 清。edge typecheck 0 + 616 vitest + iOS build + 部署冒烟(零 500)全绿。

**DB 清理全部完成**:① **`ai_picks`** 表已 drop(迁移 `20260616040829`,用户 2026-06-16 明确授权)· ② **`balance_updated_at`** 已 drop(迁移 `20260616045143`,先重建 `users_ensure_subject_trg` 移出 UPDATE OF 再删;核实唯一函数体引用 `billing_credit` RPC 早在 `20260603112148` 已 DROP CASCADE,无运行时隐患)。**billing-v1 余额列家族(balance_credits / lifetime_topup_credits / lifetime_spent_credits / balance_updated_at)全清**。

> ⚠️ **drop 列核查教训**:`DROP COLUMN` 只被 `UPDATE OF`/view/生成列依赖**阻断**,函数体/触发器 body 里读列**不阻断 drop、却会运行时炸**。本次清 `balance_updated_at` 时撞见 `billing_credit` RPC body 写这些列(幸已 DROP),提醒:drop 列前要 grep 函数体/触发器 body 引用,不只 `UPDATE OF`。
**真验尾巴(pre-launch 无真流量)**:captain 退役 + R4 `getPrompt` + Y4 voice 的端到端需真消息/通话触发,部署冒烟只验了「worker 没炸」的下限。

---

## 🔴 活跃冲突 / 用户可见失效 / 会出错

### R1 · edge crew captain 编排子系统(整体按已作废的 edge-bot captain 心智实现)

**Ground truth**: 2026-06-10「接合 v2」(spec `2026-06-10-pendingcrew-pendingbot-integration-v2.md`)定调「本地为家、edge 是邮差」,**captain 唯一形态 = 本地 session**,edge-bot captain 作废(#241 删、#242 重定义为遥控队列)。captain prompt `crew-captain.zh.md:15` 自己写「权限审批不归你管,系统直接送人类」。用户 2026-06-15:captain 技术接口不特殊,审批是 session 的事。

> 这一整块此前已被 tech-debt 末尾那条 🔴「PendingCrew 的 crew 组织/DAG 还建在 edge 上,违背本地为家」泛泛记录,并点名「需要一次专门的 edge crew 代码收口审计」。**本审计即那次审计的落实**,下面是精确代码清单。

| # | 位置 | 问题 | 现状 |
|---|---|---|---|
| R1.1 | `apps/edge/src/routes/crew-comms.ts:564-576` | crew 白板收消息后 `dispatchGroupTurn({wakeBotIds:[captainId]})` 唤醒 edge-bot captain 跑 bot-reply 回合(#241 活代码)。前面的 `enqueue_session_mailbox`(:550-561,邮差语义)才是对的,问题只在这段额外唤醒 | 🔴 活跃冲突 |
| R1.2 | `apps/edge/src/lib/bot-reply/index.ts:496-519`(注入)+ `llm/builder.ts:140-148`(消费) | `crewCaptainPersona` 注入——假设回复的 edge bot 是 crew captain。每个群回合都跑这次查询,命中即注入机长 persona | 🔴 活跃冲突(prompt 本体走 Langfuse,main 树下 .md 已删) |
| R1.3 | `apps/edge/src/lib/bot-reply/index.ts:816-823`(turnTools)+ `:857-864`(native) | captain 编排工具组挂载 `start_session`/`create_child_crew`/`recruit_temp_bot`;def `tool-defs.ts:518/548/577`;handler `tools/{start-session,create-child-crew,recruit-temp-bot}.ts` | 🔴 活跃冲突(只在 R1.1 唤醒时可达) |
| R1.4 | def `tool-defs.ts:424`(`POST_TO_CREW_TOOL`)/`:614`(`REQUEST_PERMISSION_TOOL`);handler `tools/{post-to-crew,request-permission}.ts`;dispatch `tool-runner.ts:157-159,172-174` | **纯 dead**:两个 def 从没挂到任何 turn,模型永不发出 → handler 永不命中。`feat/captain-orchestration` 想补的就是这个接线,**方向是错的**。活路径在 `crew-comms.ts:981/1134`(session/runner 走 HTTP),不复用这两个 handler | 🔴 dead(删除零风险) |

**处置**: R1.4 纯 dead 可直接删;R1.1/R1.2/R1.3 互相咬合——删 R1.1(captain 唤醒)后,R1.2/R1.3 的 edge captain 工具就彻底无入口,可一并摘。但需先解决 R5(`start_crew` 的 captain 字段归属,产品决策)。

### R2 · 相机扫码加群结构性失效(旧群号共享码 vs D2 邀请链接并存)

- **位置**: edge `routes/groups.ts:680-715`(`POST /v1/groups/join` → `group_join_request_create(p_handle_value)`,不记 invited_by);iOS scanner `MessageTabView.swift:1466-1529`(`handle(value:)` 只认 `/b/` 和 `/c/`,对 `/g/` 不识别);新二维码 `GroupQRCard` 现在生成的是 `/g/<token>`。
- **旧模型**: D2 之前的单一共享群号/QR,任何人扫了就能请求加入。
- **被什么废弃**: `decisions.md` D2(2026-06-01)群加入码改 per-inviter token(`group_invite_links`)。
- **现状**: 🔴 **用户可见 bug**。新链接路径只在「点 universal-link」时触发;相机扫新 `/g/` 群码 → 不被 scanner 识别 → 当成用户 handle 交给加好友流程 → **扫码加群走不通**。旧 `group_join_handles` 共享码路径(无邀请者留痕)仍是手输群号/旧 `/c/` 码的活路径。
- **处置**: scanner `handle(value:)` 增 `GroupShareLink.isGroupShareLink` 分支走 `resolveGroupInvite`/GroupJoinView;确认闭环后退役 `POST /v1/groups/join` + `group_join_request_create(p_handle_value)` + `group_join_handles` 读取。**注意**:D2 现状核实只标了「universal-link presenter 未接」,**没提相机扫码不识别** —— 这条是新发现,且必须先修 scanner 再退旧路径,否则扫码加群完全失效。

### R3 · `/v1/me/balance` + `getBalance()` 读 billing-v1 僵尸列

- **位置**: `routes/me.ts:168-182` + `lib/billing.ts:95-110`(读 `users.balance_credits`/`lifetime_*_credits`)。
- **被什么废弃**: #209「me.ts 余额改读 WalletDO」+ 计费 P2 Polar/WalletDO 切换。`/me/wallet/v2`、`/me/subject` 都已改读 WalletDO,唯独 `/balance` 漏改。
- **现状**: 🔴 端点活着读僵尸列(无运行时写入方,冻结在 `20260529141318_billing_v2_cutover` 时刻);iOS `BillingService.swift:3-7` 注释明确已不调(WalletView 已删)。`redeemCode` 入账已正确改走 Polar+pnc_ledger,不碰 balance_credits。
- **处置**: 删端点 + `getBalance()` + `BalanceInfo`;`balance_credits`/`lifetime_*_credits` 列随 billing-v2 孤儿一起进 cleanup 迁移(见 Y7)。

### R4 · 4 处内联 const prompt 漏迁 Langfuse(违反 no_hardcoded_prompts)

- **位置**: ① `lib/lookback-runner.ts:36` `LOOKBACK_INSTRUCTION`(:105 发给 LLM);② `llm/vision.ts:184` `SUMMARY_PROMPT`(:287);③ `lib/group-bot-intro.ts:80` `systemPrompt`;④ `llm/builder.ts:177/180` `BUBBLE_INSTRUCTIONS`/`SINGLE_INSTRUCTIONS`(borderline,注入 system)。
- **被什么废弃**: memory `no_hardcoded_prompts` + #247(prompt 真源迁 Langfuse,`prompt-loader.ts` 已是「Langfuse single source of truth,无 bundled fallback,fail-loud」)。
- **现状**: 🔴 活跃冲突。`lookback-runner.ts` 的最后一次提交 hash 就是 #247 那次,同次把别的 prompt 搬进 Langfuse 却把这段留在原文件。②③ 早于迁移、从未纳入。**未记 tech-debt**。
- **处置**: ①②③ 抽进 Langfuse + 加 `PROMPT_NAMES`/`PROMPT_DESCRIPTIONS`,调用方改 `getPrompt(...)`;④ 与团队确认是否算「输出模式开关」豁免(倾向也外移)。

### R5 · `start_crew` 把提议 bot 写成 `captain_bot_id`(R1.1 的唤醒来源)

- **位置**: 决议端点 `routes/messages.ts:1438-1447`(`create_crew_with_captain` with `p_captain_source:'reuse_bot', p_captain_bot_id: proposedByBotId`);RPC `20260614123750_crew_machine_id.sql:68,85` 仍接受 `reuse_bot`。
- **现状**: 🟡→🔴(它喂养 R1.1)。`start_crew` 的「提议建 crew + 人类确认」语义**仍成立**(不是 captain 编排),但落地把提议 bot 设为 `captain_bot_id` 并据此被唤醒,与新模型冲突。
- **处置**: **需产品决策** —— captain 字段在新模型下应置空 / 改成「本地 session 启动后回填」/ 还是连 `reuse_bot` 一起退役?保留 `start_crew` 语义,别一刀切删。

### R6 · `session-world-model.ts` 仍把 `captain_bot_id` 当 "Captain bot" 渲染进世界观

- **位置**: `llm/session-world-model.ts:69,141-176`(`if (meta?.captain_bot_id)` → 渲染 `Captain bot: **<name>**`;:168-176 两分支文案相同,疑似未完成编辑残留)。
- **现状**: 🟡 活跃(session/runner 读此文件)。只要 R5 未返工、`captain_bot_id` 非空,就渲染出「某 bot 是 captain」,与「captain=本地 session」矛盾。随 R5 一起对齐。

### R7 · 多账号本地隔离只靠登出擦库(**已记 tech-debt L159,现状未变**)

- `AccountStore.swift:244`(signOut 不清 URLCache)、`:131-132`(observeAuth 不比较 old.id≠new.id)、`LocalDatabase.swift` 读查询全 `fetchAll` 无 account_id WHERE。确认债项仍准确、范围无扩大。处置见 tech-debt L166。

---

## 🟡 旧心智仍在跑,需重构

### Y1 · WelcomeView 两模式选择 + LocalSetupView 死壳(双端不可达,反事实文案)

- **位置**: `Sources/Views/WelcomeView.swift`、`Sources/Mac/Views/LocalSetupView.swift`、`AppModel.swift:29/55/73-80/155-158`(`localModeSelected`/`enterLocalMode`)、`PendingCrewApp.swift:71-118`。
- **被什么废弃**: 2026-06-10 拆双轨;`AppModel.backend` macOS 恒 LocalBackend、`isConfigured` 恒 true。
- **现状**: 🟡 dead(macOS `isConfigured` 恒 true → 直进 authenticatedRoot,两模式分支永不渲染;iOS `localModeSelected` 恒 false)。文案「一次选定不可切换」是 06-10 前的旧心智。**未记债**。
- **处置**: WelcomeView macOS 退化成纯展示或删 macOS 分支;删 `LocalSetupView` + `localModeSelected`/`enterLocalMode` + RootView `.localSetup` 分支。**需确认**:是否保留作未来「显式选模式」入口。

### Y2 · `runtime_location` 派生列被当事实源在侧栏每行渲染 location tag(与 #369 冲突)

- **位置**: `CrewDAGTreeView.swift:137,151-160`(`locationTag` 每行渲染)、`CrewSummary.swift:82-108`(`RuntimeLocation` 枚举);次要 `CrewDetailInspector.swift:73-74`、`CrewListView.swift:71`。
- **被什么废弃**: #335 machine 概念(machine 表才是事实源,runtime_location 降派生镜像列)+ #369「去掉每行 本机/云端 location tag」。
- **现状**: 🟡 活跃冲突。crew 已视觉嵌在所属 machine 组下,行内再贴派生「本机」标签既冗余又把派生列当事实源——正是 #369 想删的,DAG 树这条路径没跟上。**未记债**(L45 记了 runtime_location 派生但没点出此渲染残留)。

### Y3 · 审批 store 仍裸轮询(白板已事件化,审批没跟上)

- **位置**: `CrewCenterView.swift:23`(`captainTick` 2s)、`SessionApprovalCardsView.swift:24`(`tick` 1.5s)轮询 `LocalApprovalStore`。
- **现状**: 🟡 活跃(当前 v1 设计),但与 crew-comms-rework P5「白板去轮询」不对齐——同一套跨进程目录监听 publisher 本可覆盖 `LocalApprovalStore`(也是 `<dir>/<crewId>.approvals.json`)。**未记债**。非紧急(廉价文件读)。

### Y4 · 语音实时成本预览仍 v1 PND+markup 单位(**已记 tech-debt L432**)

- `voice-metering.ts:144-176` `broadcastVoiceCostPreview` 用 `getMarkup`×`usdToPnd` 产 `delta_pnd`,与 PNC 扣费错配。`getMarkup`/`usdToPnd`/`USD_TO_PND`/`DEFAULT_MARKUP` 的**唯一存活运行时消费者**就是它,改完可全删。需 iOS 同步改 `voice_cost` 解码。

### Y5 · `audit_log.cost_credits`/`billing_status` v1-legacy 列每 turn 仍写(有意兼容,无害)

- `router.ts:458`(`cost_credits:0`)/`:415-419,459`(`billing_status`)。代码注释自承「v1-legacy,留 0 防 dashboard 双计」。dashboard 栈迁移后应退役。归 tech-debt L440 冷备那条。

### Y6 · `seed-public-skills.mjs` 用 legacy env `SUPABASE_SERVICE_ROLE_KEY`(**补 tech-debt L90**)

- `scripts/seed-public-skills.mjs:77,79`。全仓唯一引用。tech-debt L93「遗留 legacy 消费者」漏列此脚本,停用 legacy key 时会被漏。改 `SUPABASE_SECRET_KEY` 即可(同权)。

### Y7 · DB dead-but-not-dropped 对象(3 个,纯磁盘噪音)

| 对象 | 位置 | 说明 |
|---|---|---|
| `usage_events` 表 | `20260529124601_billing_v2_schema.sql:104` + schema.ts:3783 | billing-v2 孤儿;同批 `packs`/`ledger_entries`/`refund_events` 已在 `20260603112148` drop,**唯独它漏 drop**。无任何 INSERT/SELECT。**注意**:billing agent 一度以为 `ledger_entries` 还在——经 DB agent 核实那是 schema.ts 注释误导,实际只剩 `usage_events`。`progress.md:406`「packs/ledger 留冷备」描述与现状不符(packs/ledger 已删,真正留下的是 usage_events) |
| `ai_picks` 表 | `0001_init.sql:502` | 自 init 起从未被任何代码引用,疑似胎死。**需人确认**是否有未来计划 |
| `temporary_group_meta.cloud_machine_id` 列 | `20260527090000:10`(`20260528105149:107` 标 DEPRECATED) | 二次被取代(→fly_machine_id→machine_id),0614 drop peer/fly 时漏带它 |

处置: 合并成一条 cleanup 迁移收掉(`ai_picks` 待确认)。

---

## 🟢 注释 / 命名 / 文案漂移(误导后人,本审计正是被这类带跑过)

> 这些不改运行行为,但「旧注释/旧 spec 当现状证据」恰恰是本次审计起因(我一开始被 `spec v2 §9.3/§10` 注释带跑)。优先清 user-facing 的。

- **G1(user-facing,优先)** `BotManagement.swift:151,1454` 两条 footer 文案仍承诺已删的「盲评 → 我→模型竞技场榜单」。A/B 盲评 UI 和 MeTab 榜单都已随盲盒转型删除。改成盲盒话术。
- **G2(可删死文件)** `GroupCallTransport.swift` 是 6 行空占位,注释称「必须保留(pbxproj 仍引用)」——失实:`project.yml` 用目录 glob,删文件后 `xcodegen` 即可。
- **G3 captain 编排 spec 引用** `tool-defs.ts:514/542/571/604`、`start-session.ts:1`、`request-permission.ts:19`、`crew-comms.ts` 多处把已废 §6.3.3/§6.4/§10 当现状引用。随 R1 清理一并清。
- **G4 BYOK 命名漂移**(十余处,**已记 tech-debt 末尾 🟢**) `PendingCrewBackend.notSupportedInByok`、`local-byok`/`local-byok-user`(已写进本地 JSON,改名需数据迁移)、`kind:"byok"`、注释。`CaptainTemplateEditorSheet.swift:78` 文案「要在 BYOK 里有对应 key」是反事实(已无 key 概念),优先级略高。
- **G5 codex「待实现」注释** `CrewSessionRunner.swift:434`(app-server 已实装)。删三字。
- **G6 freeze 横幅注释** `ConversationView.swift:979/1032/2310`、`+Group.swift:17-21`(死代码已清,注释还说有 freeze banner)。
- **G7 ChatDataSource 头注释** 引用已删 `MacMessagesView.swift` + 旧「Mac 独立/iOS inline」分叉叙事(实际两端共享)。
- **G8 slug 旧注释** `BotManagement.swift:2361-2365`(BotSharePage 旧 slug-as-identity)、`GroupQRCard.swift:4-20`(说 `/c/` 实际 `/g/`,正是 R2 根因线索)、`well-known.ts:18-19`(`/b/` 说成 slug-based,实为 invite token)。
- **G9 board 门禁注释** `board.ts:3`、`index.ts:187`、`board-feature-flags.ts:10`、`admin/.../resource-map.ts` 仍写 `requireAdmin`/`requireSession`,实际是 Cloudflare Access(代码已对)。
- **G10 WorldRouter 命名** `billing.ts:18`、`ai-gateway.ts:5`、`token-estimate.ts:5` 注释 + `provider-usage.test.ts:38` 测试名(0 运行时残留)。
- **G11 crew-interactions untypedRpc** `crew-interactions.ts:29,35,39,76,142` 注释「schema.ts 还没 regen」已过时(schema 已含两 RPC),`untypedRpc` 可收口成 typed。
- **G12 CrewSessionWindowView** `:457`「每 2s 重算」/`:847`「next poll」注释(已事件化)。
- **G13 fly/peer/tag 死枚举** `CrewSummary.RuntimeLocation.{peerDevice,flyMachine}`、`Machine.flyMachineId`(恒 nil)、tag 注释。fly/peer 是「云端未来」占位(#178),留着不算错,收 location tag 时一并精简。
- **G14 容器历史对照** `voice-container/src/room.ts:48`「old in-DO 100ms」(正确的设计说明,可留)。
- **G15 decisions.md R1** 引用已删 `billing-v2.ts`/`ledger_entries` 当现状证据;且其结论「语音 settle 解析 subject 不一致」**已不成立**(经 billing agent 核实,现在文本+语音 turn 走完全相同的 `enqueueAudit→resolveBillingSubjectId` 路径,是全路径统一行为)。R1 应标历史 + 修正结论。
- **G16 `users.is_admin` 疑似 dead 列** board 门禁改 `BOARD_ADMIN_EMAILS` 后,该列对 board 已无作用。**需人确认**是否还有别的活跃读取方。

---

## ✅ 反向核实:已确认干净 / 有意保留(防止未来重复审计)

1. **群语音 v2→v3 搬迁**:最干净维度。DO 已纯控制面(grep `mixPcm/downsample/playout` 在 DO 零命中),媒体处理全在 `apps/voice-container`,无两边重复混音,1:1(`RealtimeMeterDO`)与群语音路径彻底隔离。
2. **DB 已 drop 对象 0 处活跃引用**:`model_comparisons`/`group_member_billing`/`subject_wallets`/`peer_device_id`/`fly_machine_id`/`tag`/`public_open`/旧分摊 RPC 在 edge/iOS/schema.ts 里只剩注释,无会 500 的活引用。
3. **OpenMeter 已彻底删除**(非孤儿依赖):package.json 无 `@openmeter/sdk`,0 引用。
4. **lemon/squeezy/iap webhook 已删干净**:`billing-webhooks.ts` 只剩 Polar + RevenueCat。
5. **Stripe 从未直连**:全仓唯一出现是 `billing.ts:11` 一句注释。
6. **provider 路由已对齐**:4-provider AI Gateway Unified Billing 主路径 + OpenRouter fallback;无用户 BYOK(Gemini 经平台自存 key 是受控合法例外,`router.ts:184` 只对 google-ai-studio 赋 byokAlias)。
7. **`.cjs` 删除(#274)已完成**:main tip `git ls-files '*.cjs'` 为空(残留的在别的 stale worktree)。
8. **crew-comms 广播硬写已解开**:`recipient_session_ids` 经 `resolveRecipientSessions`/`resolveOutboundRecipients` 传真实收件人。
9. **rework P5 三定时器已删**(CrewChatView 3s/roster 3s/badge 2s → `whiteboardChanges` 事件)。
10. **crew_sessions claim 队列 + 唤醒链路干净休眠**:`edgeQueueBindingReady=false` + `serverLink=nil` 两道门门住,无半接通死路径(审计要点,确认通过)。
11. **`BackendMode` 枚举已全删**,`AppModel.backend` 恒本地;key 机制实删且 `LocalCodingAgentSpec.swift:54-58` 主动 strip `OPENAI_API_KEY`。
12. **自制 board UI 已整目录删除**(`apps/board` 不存在);后台是 `apps/admin` Refine + Cloudflare Access,无应用内登录/Turnstile 残留,无老计费 board admin 入口。`infra/dashboards/docker-compose.yml`(Metabase+Appsmith)是 spec 明确的「可选 fallback」留档,非残留。
13. **arena 评价框架已连根拔**:`ArenaStanding/Leaderboard/CompareResult/ArenaCompareCard` 全删;保留的 `ArenaModelPoolEditor`(盲盒模型池编辑器)是 spec sanctioned 的命名沿用,不算残留。

---

## 📒 账本漂移(顺手修正)

- **`progress.md` 顶部多个分支标「未合 main」实际已合**:`feat/codex-app-server`、`feat/crew-machine`、`feat/model-blindbox` 等(本 checkout HEAD = main tip 已含)。两个 agent 独立撞见此漂移。已在 progress 顶部对账修正。
- **`progress.md:406`「packs/ledger 留冷备」** 与现状不符(packs/ledger 已 drop,真正留下的是 usage_events)。见 Y7。
- **`decisions.md` R1** 见 G15。

---

## 需用户决策的点(汇总)

1. **R5 / R1 — captain 字段新归属**:`crews.captain_bot_id` 在「captain=本地 session」下应置空 / 本地 session 启动后回填 / 还是连 `start_crew` 的 `reuse_bot` 一起退役?这是动 R1 整块的前置决策。
2. **R1.4 纯 dead code 是否现在删**:`post_to_crew`/`request_permission` 的 bot-reply def+handler+tool-runner 分支,删除零风险。
3. **crew-interactions.ts 整条退役 vs 暂留**:spec §6 说暂留给 `.logged` 复用,但生产者(.cjs)已删、消费端 3 处 UI 成死壳。
4. **DB 三个 dead 对象清理时机**:`usage_events`/`ai_picks`/`cloud_machine_id`(`ai_picks` 还需确认有无未来计划)。pre-launch 单环境,可攒可清。
5. **R3 `/v1/me/balance` 删除前**:确认无旧 TestFlight build 仍在调(pre-launch 应可接受)。
6. **R4 ④ `BUBBLE/SINGLE_INSTRUCTIONS`** 是否算需外移的 prompt(borderline)。
7. **Y1 WelcomeView macOS 分支**:彻底删 vs 留作未来「显式选模式」入口。
8. **G16 `users.is_admin`** 是否还有活跃读取方(疑似 dead 列)。

## 建议处置顺序

1. **先修 user-facing 失效**:R2(扫码加群)、G1(盲评文案)。
2. **零风险 dead code 清理**:R1.4、G2(GroupCallTransport)、R3(/balance,iOS 已不调)。
3. **成块返工(需 R5 决策先行)**:R1.1→R1.3 + R5 + R6 + G3 一起,作为「edge crew-org 按本地为家收口」那条已记 🔴 债的收尾。
4. **prompt 收口**:R4。
5. **DB cleanup 迁移**:Y7 + R3 的 balance 列。
6. **轮询/单位对齐**:Y3、Y4。
7. **注释/命名批量清**:G4–G15(随对应代码改动捎带)。
