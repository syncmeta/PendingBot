# 产品 / 设计决策登记 (Decision Log)

记录**拍过板的产品/设计决策**,防止"记得设计过、代码里却找不到"的反复丢失。这是四账本里"决策"维度的家(task=做没做 · roadmap=计划 · tech-debt=风险 · progress=状态 · **decisions=拍过的板**)。

每条格式:决策内容 · 日期 · 背景/为什么 · **现状核实**(代码里是否已对齐;🔍=待核实,✅=已核实在,❌=确认缺失)。拍板后写一条;落地后更新现状核实。

---

## D1 · Bot 邀请模型 = 好友可邀 + 链接关联邀请者 + 透明留痕
- **日期**: 2026-06-01
- **决策**:
  - bot **纯邀请制**,slug **不是**加入路径(`public_open` 已删)。
  - **任何「bot 的好友」**(在 `user_bot_contacts` 有该 bot 的人)都能签发邀请链接。不做"被授权的人"这种额外委派。
  - 链接 = **邀请者签发的、可复用凭证**(默认 7 天有效、可手动撤销),像微信群邀请二维码 / 网盘分享链接。持链接者有权加入。
  - **关联到邀请者**:兑换时记 `invited_by = 邀请者`。
  - **好友列表对所有好友透明**:任何好友能看到该 bot 还有哪些好友、以及**每个好友是谁拉进来的**。
- **背景**: #121-128 原实现是 slug-as-public-identity(陌生人按 slug 直查),与邀请制 RLS 正面冲突、ship 即坏(见 tech-debt 🔴 bot 分享 RLS)。本决策把它返工成 invite-token 模型。
- **落地方向**: 新表 `bot_invite_links(token, bot_id, inviter_user_id, expires_at, revoked_at)`;service-role 预览/兑换端点(RLS 不放宽);客户端外壳复用、内核换 token。slug 保留当展示 @名。
- **现状核实**: ✅ **已实现 + 端到端验证(2026-06-01)**。DB(#191)+ Edge(#192/#193,已部署 prod worker)+ iOS 全返工(#194,签名构建装模拟器实测)。收件人路径真机验证链:universal link `/b/<token>` → 加机器人页 → resolve 预览(真 bot +「由 X 邀请你加入」)→ 添加 → redeem → 进聊天;DB 确认 `user_bot_contacts.added_via='invite_link'` + `invited_by` 留痕。无效 token 显示「邀请链接无效」。**残留(低风险,未单独视觉验)**:发件签发页(BotSharePage,创建者可进公开 bot 管理→分享验);CreateBotSheet slug 栏旧文案(#123)。

## D2 · 群加入码 = 每人一码、各自关联到本人(邀请者)
- **日期**: 2026-06-01
- **决策**: 群加入码也走"关联邀请者"模型,但形态是**每个群成员看到的是关联到自己的那份码**——使用时当"群的码"用(扫了就进这个群),但每个人的码不同,从而留痕"谁是被谁拉进来的"。
- **背景**: 现状群 handle 是单一共享码,任何人拿到就能请求加入,不记是谁分享的,与 D1 的 bot 邀请哲学不一致。统一成同一套"邀请关联到人"。
- **现状核实**（2026-06-01）:
  - **后端 ✅ 已落地**（迁移 `20260601082502`,push live + edge typecheck 绿）：`group_invite_links` per-inviter token 表 + `conversation_participants.invited_by` / `group_join_requests.invited_by` + RPC create/list/revoke/resolve/redeem;`group_join_request_decide` 批准时把 invited_by 落到成员行。Edge `/v1/groups/:id/invite-links` + `/v1/group-invites/:token`。RLS 不放宽。
  - **iOS 🟡 核心已编译验证**(2026-06-01,`4e5a58a7`,BUILD SUCCEEDED)：GroupInviteAPI client + `GroupShareLink`(/g/ token codec)+ GroupJoinView 改 token resolve/redeem(扫码 → 预览群信息 +「由 X 邀请」→ 加入,记 invited_by)+ GroupQRCard 改签发 per-inviter 群邀请链接 + QR(任何成员可签发)。**残留**:① /g/ universal-link 的 MessageTabView/TabRoot presenter 接线(扫码路径已通,深链点击未接);② simulator 视觉验证(结构同已端到端验证的 D1,低风险);③ 旧 `group_join_handles` 共享码 iOS 已不用作主分享,可后续清。

## D3 · 头像 / 昵称可见性 = 只走两条受限路径,不全局公开
- **日期**: 2026-06-01
- **决策**: 头像和昵称**不全局公开**。只有两个合法暴露场景,各自从不同来源拿对方信息+凭证:
  1. **加好友时** —— 需要看到对方头像+昵称(走 handle 查询路径)。
  2. **群聊里** —— 能看到非好友群成员的头像+昵称(走群成员路径)。
  - 除这两处外没有需要公开的地方,**就不公开**。
- **背景**: 现状 `attachments` RLS 让头像行(含 `r2_key`、文件名)对所有登录用户可读,和 Worker 下载口径不一致、可能泄露 r2_key。决策明确"头像不是全局公开资源",据此收紧 RLS 到这两条路径 + 闭合 metadata 泄露。
- **现状核实**（2026-06-01 亲验 + 部分落地）:
  - **Part 1（关 metadata 泄露）— ✅ 已落地**：迁移 `20260601080625` 删掉 `attachments_self_read` 的全局头像分支(原对任意 authenticated 暴露 r2_key,无合法消费者)。已 push live。
  - **Part 2（给两条场景服务头像字节）— ✅ 已落地**（2026-06-01,`53de193f`）：用户拍板"加好友和群成员都要能看头像"。设计选定 **id-as-capability**:`/v1/uploads/:id`(`apps/edge/src/routes/upload.ts`)加头像例外 —— 任意登录用户凭(不可枚举、只能从合法处拿到的)头像 attachment id 可取**头像图片字节**。同时覆盖加好友(lookup 给的 id)和群成员(成员列表给的 id)两场景。**只服务图片字节**;metadata(r2_key 等)仍由 part1 RLS 挡住;聊天附件仍消息引用 gated。这是标准头像模型。
    - 小遗留:`users.avatar_path` 上的查找未建索引(头像有 1yr immutable 缓存,每客户端每头像查一次,pre-launch 量级可接受);未来量大可加索引。

## D4 · Crew captain 来源 = 4 种(spec 补齐)
- **日期**: 2026-06-01
- **决策**: spec §6.3.1 从 3 种改为 **4 种**,补上代码已实装的 `spawned_by_captain`(父 crew 的 captain 主动创建子 crew → 子 crew captain 默认 = 父 captain)。
- **背景**: spec 写 3 种,迁移 `20260527090000` + `create_child_crew_inheriting_responsibility_*` RPC 已实装第 4 种,spec 没同步(tech-debt 🟡 已记)。决策是对齐到代码(4 种),不是删代码。
- **现状核实**: ⚠️ **已部分过时(2026-06-19 降级)** —— 当前活的建 crew RPC(`create_crew_with_captain`,迁移 `20260614123750`)只接受 **2 种** `captain_source`(`reuse_bot` / `system_generated`),客户端实际只用 `system_generated`;`spawned_by_captain` / `create_child_crew` 继承那套只在 legacy `/v1/crew`(单数)路由和旧迁移注释里残留。引用本决策前先核到这一层。权威现状见 handbook `pendingcrew/concepts/captain.md` + `shared/evolution/pivots.md` §4。

## D5 · PendingBot 三端 UI = 共享视觉组件层 + 大屏多列壳,iPhone 视觉不变
- **日期**: 2026-06-01
- **决策**: 三端 UI"较为统一"且**不改动 iPhone 现有视觉设计**。做法分三层:
  1. **视觉设计语言**(Theme 配色 / 气泡样式 / 字体 / 头像 / 图标 / 间距 / 交互手感)—— 三端**完全统一、原封保留**。抽成一套**三端共享的 SwiftUI 组件层**,让 iPhone 自己也用这套(所以"统一"=字面意义上同一套代码)。
  2. **布局骨架** —— 按平台适配,**不算改设计**:iPhone 保持底部 `TabView` 单列;**iPad/Mac 用 `NavigationSplitView` 多列**(会话列表 + 聊天流并排)。用户已拍板大屏走多列、复用同一套视觉。
  3. **个别 UIKit-only 控件**(键盘附件栏 `ChatComposerAccessory` / 相机相册 `UIImagePickerController`)—— Mac 上无对应,必须 AppKit 重写,**视觉尽量贴近但底层不同**(这是唯一会有差异的地方)。
- **关键纪律(让"不改 iPhone 设计"真的成立)**: 把现有 iOS 视觉视图重构成"共享 SwiftUI core + 薄 iOS 桥"时,是**结构重构、不是视觉改动**;每次重构后**必须在 iOS 真机/模拟器视觉回归确认无变化**,否则共享化容易顺手改了 iPhone 的样子。
- **背景**: 用户希望三端 UI 较统一且不动现有设计。Crew Tab v2 已验证此路子(SwiftUI-only 三端共享)。工作量见 tech-debt / 本轮 Mac 估算(~70–108 人日,砍 Mac 语音可压到 ~70)。
- **现状核实**: ❌ 未实施(规划)。Mac 三栏壳在、"我"+"好友"tab 已接;iPad 现状是 iOS UI 加大(只 Crew tab 三端共享)。落地路径:P1 抽 Foundation/共享组件 → P2 Components 跨平台 → P3 Message(最重)→ P4 其他 tab。

## D6 · 「删代码看不见自己让什么失去了最后一个引用」—— 这个盲区要有一道自己的检查

- **日期**: 2026-08-25(机长拍板)
- **决策**:
  1. 仓库常驻一道**孤儿界面检测**(`scripts/check-orphan-views.mjs` + `.github/workflows/orphan-views.yml`),回答一个此前没有任何机制在问的问题:**有没有界面失去了最后一个入口。**
  2. **当下只报告、不拦人**;报告写进 CI 的 job summary,并且打「本次 N 个 / 基线 M 个」的**对比**,不是只打一个当前数字。
  3. **存量 11 个的处置权在作者**,豁免清单 `scripts/orphan-view-allowlist.tsv` **保持空的**,等作者表态后再把 `--gate`(阻塞)换上来。
- **背景 —— 这一条是本决策的全部理由,删掉这道检查之前必须先读完它**:

  > **删代码时,你看得见"我删了什么",看不见"我让什么失去了最后一个引用"。**

  最初的读法是「有人顺手清掉了不该清的东西」,带着找责任的味道。**这个读法被数字推翻了**(下表用 `check-orphan-views.mjs --ref <提交>` 逐个提交量出来,同一把尺子):

  | 提交 | 那天做的事 | 孤儿数 | 这一笔**造出来**的孤儿 |
  |---|---|---|---|
  | `92912e00^`(06-09 收编前) | — | 34 | — |
  | `73faafbe`(2026-06-09) | Mac 平行实现收编成共享 surface,删 `MacRemoteSessionsView`(310 行) | 13 → **16** | `BrandAvatar`、`MacGroupWalletView`、`MacAmountFormSheet` |
  | `095dfc2b`(2026-06-15) | 删 PendingBot crew 死代码 | 12 → **5** | `GroupWalletView`、`AmountFormSheet` |

  **这两笔提交本身都是对的,而且都是净收益很大的好提交** —— `73faafbe` 当天把孤儿从 34 压到 13,`095dfc2b` 从 12 压到 5。**没有人做错事。** 五个孤儿里,群钱包那套是作者**三个月后**靠「我记得有过这个东西」翻出来的;`BrandAvatar` 则是两个半月里**没有任何人、任何账本提过一次**。

  之所以谁都没发现,是因为**那一行根本不在 diff 里**:编译器不问、测试不问、CI 不问、review 也不问 —— 它们看的都是"改了什么",而这件事的形状是"某处**没有**改变,但它的意义变了"。

  **回溯验过:这五个孤儿,检测器在它们被造出来那一天就会点名。** 这是量出来的,不是设想。

- **为什么要把这段写进决策账,而不只写进技术债**: **这道闸将来一定会有人嫌它烦。** 一道闸只要没有"它为什么存在"的记录,两个月后就会被当噪音摘掉 —— 而摘掉它的人不会知道自己正在关掉的是那个让五个界面消失了三个月的唯一一只眼睛。
- **想改它 / 摘掉它的正确方式(给一条合法路径,否则只会被人默默删掉)**:
  - 觉得某个孤儿的报警是错的 → 那是**判据 bug**,补一条自测样本再改判据(`scripts/test-check-orphan-views.mjs`,合成样本正反都有)。
  - 觉得某个孤儿现在不该处理 → 往 `orphan-view-allowlist.tsv` 加一行,**带理由和复查日期**。
  - 觉得整道闸都不该存在 → 先回答一个问题:**下一次有人删掉某个界面的最后一个入口时,谁会知道?** 答得上来再摘。
- **三条附带的设计,都刻意如此,别顺手改掉**:
  1. **「总数不变但名单换了」也要两头点名** —— 死一个、活一个正好互相抵消,只盯总数会漏掉。
  2. **基线只能人显式更新**(`bun run orphans:baseline` + 一笔说明为什么变的提交)—— **自动跟着涨的基线等于没有基线**。
  3. **自测拦人、扫描不拦** —— 检测器自己坏了却没人知道,比它报错更糟:**一个坏掉的检查会一直绿,看起来正好像"没有孤儿"。**(这和本仓库另外两句是同一件事的三个面:「一道只在坏事发生时才响的闸必然是在猜」「一次性的证明和一条持续的保证,在 exit 0 上长得一模一样」。)
- **明知的盲点,不补,是决定不是遗漏**: 图的节点是**文件**不是符号,所以"活文件里死掉的那一个界面"抓不到。降到符号粒度抓的是**另一类**问题,而这次真实发生的五个全是整文件/整簇失去入口,现判据全抓得到。**留着盲点,等它真咬人一次再补,不为假想的问题提前加复杂度。**
- **现状核实**: ✅ **已落地(2026-08-25)** —— 合并提交 `f86218bf`(分支 `chore/orphan-view-gate`,6 笔)。检测器 + 自测 + 非阻塞 workflow + 基线(11)+ 空豁免清单均在树上;`bun run orphans` / `orphans:test` / `orphans:baseline` 三个入口已挂进 `package.json`。**未 push。** 存量 11 个待作者表态。详细风险条目见 [`tech-debt.md`](tech-debt.md) 🟡「删掉旧消费方,把专为它造的东西留下」。

## D7 · worker 破例持有一把 OpenRouter key —— 只拉模型清单,绝不发推理

- **日期**: 2026-08-25(作者拍板「治本」,机长划边界)
- **决策**:
  1. worker 可以持有一把 **OpenRouter API key**(`OPENROUTER_CATALOG_KEY`),**用途唯一**:调 `GET /api/v1/models/user` 拉「本账号真调得通的模型清单」。
  2. **推理路径一个字不动** —— 仍然全部走 Cloudflare AI Gateway,provider 凭证由网关代持(Unified Billing / BYOK)。**这把 key 永远不出现在任何推理请求上。**
  3. **没有 key 时回落到公开清单是允许的,但必须大声**:每一条退化路径都打 `[model-catalog-unfiltered]`,写明这次用的是未过滤的清单、池子里可能有调不通的模型。**静默回落 = 把 Todo #15 原样埋回去。**

- **背景(为什么值得破例)**: 模型池一直是从 OpenRouter **不带钥匙**的 `GET /api/v1/models` 拉的 —— 那是整个平台的菜单(2026-08-25 实测 419 个),**跟本账号够不够得着无关**。账号的隐私 / 数据政策(默认就不允许「可能拿请求数据训练」的线路)要到**真正发请求那一刻**才生效。于是池子机器人开局可能抽到一个本账号永远调不通的模型 → OpenRouter 404 → 用户侧直接失败(Todo #15,Rosales)。
  带认证的 `/api/v1/models/user` 官方描述是「按 user provider preferences、privacy settings、guardrails 过滤后的清单」—— **只有它能在抽签之前把废签剔掉**。没有第二条路:那个「逐个查模型有哪些线路」的公开接口不返回数据政策,从公开数据推不出来。

- **这**部分**回退了哪个决定,以及回退到什么程度**: 2026-05 的 AI Gateway 切换定的是「provider 密钥不放 worker env,统一存在网关」(见 `docs/deploy.md` 的 AI Gateway cutover 一节,当时明确删掉了 worker 的 `OPENROUTER_API_KEY`)。**那条对推理仍然全额有效**;本决策只在「读目录」这一个只读用途上开一个口子。
  **将来有人在 worker env 里看到一把 provider key,先来看这一条** —— 它是拍过板的例外,不是事故;但如果发现它被用在推理上,那就是事故。

- **代价与取舍**:
  - 多一处需要轮换的凭证(只读用途,泄露的最坏后果是别人能拿它发推理烧我们的额度 —— 所以仍然是**真正的密钥**,按密钥对待)。
  - 池子会变小(那些「只有训练线路」的模型不再进池)。**这是刻意的**:作者选择不放开 OpenRouter 的训练权限开关,即不拿「对话内容可能被上游用于训练」去换「可选模型更多」。
  - 目录 filter 只在有 key 时生效,所以**这不是唯一防线** —— 抽到打不通的模型时自动重抽(同一批改动)仍然在,两层都留着。

- **现状核实(2026-08-25)**: ⏳ **代码已落地,key 尚未配置** —— 切换逻辑、回落、截断红闸和 8 条测试都在(`apps/edge/src/routes/models.ts`),但生产还没设 `OPENROUTER_CATALOG_KEY`,所以线上此刻走的仍是**未过滤的公开清单**(日志里会有 `[model-catalog-unfiltered] {"reason":"no_catalog_key"}`)。
  ⚠️ **还有一件没验的,配 key 时必须先做**:`/models/user` 官方文档说它是**分页**的,而这份实现是在**没有 key、没见过真实返回**的情况下写的 —— 只读了第一页。目前靠一道红闸兜着(拿到的清单少于公开清单一半就当截断、回落并记一笔),**但那是保险,不是验证**。key 到手后第一件事:把真实返回打出来看一眼,该补翻页就补。

---

## 反向核实记录(确认"没丢"的设计,留作证据)

### R1 · 责任主体快照 —— ✅ 已确认实装,未丢失
- **核实日期**: 2026-06-01
- **担心**: 用户记得"计费按责任主体记快照"反复确认过,怀疑设计丢失。
- ⚠️ **2026-06-15 更新(承载物件已迁移)**: 本条引用的 `billing-v2.ts`/`settleUsage`/`ledger_entries` **均已退役** —— billing-v2 死代码已 #209 删、`ledger_entries`/`packs`/`refund_events` 已 `20260603112148` drop(只剩 `usage_events` 漏 drop 成孤儿,见 tech-debt Y7)。责任主体快照模型**本身仍在**,但承载物件已换成 `pnc_ledger` + WalletDO + Polar 的 owner 维度。下面是历史核实记录,按失效路径找证据会扑空。
- **核实结论(历史,2026-06-01)**: **在的。** `usage_events`([20260529124601:104](supabase/migrations/20260529124601_billing_v2_schema.sql:104))和 `ledger_entries` 都有 `owner_user_id` / `owner_subject_id` 列 + `usage_events_owner_exactly_one` CHECK 约束,落账即钉死 owner;`settleUsage(owner: OwnerRef)`(billing-v2.ts:51,已删)显式传 user/subject 并写入。群语音 RealtimeKit 媒体路径正确解析 `responsible_subject_id` 传入。
- **~~真实剩余小项(非丢失)~~ → 已不成立(2026-06-15 审计核实)**: 原记「语音 turn 模型 token 走 v1 audit、settle 时才解析 subject,与其他路径不一致」。经审计核对 `router.ts:348-540`:**文本 turn 与语音 turn 现在走完全相同的 `enqueueAudit → persistAuditMessage → resolveBillingSubjectId` 路径**,都在 settle 时解析 subject 并走 `wallet.debit`/`settleGroupSpend`(PNC micros,voice 用 `voice_tokens` category)。「settle 时解析 subject」是**全路径统一行为**,不再是语音独有的不一致。此小项闭合。
- **教训**: 这条最初是 agent 读 voice v1 audit 老路径的误报被直接上报导致的虚惊。**agent 发现必须先验证再当结论用。**
