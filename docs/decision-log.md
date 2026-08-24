# PendingBot 决策志 —— 问题、解法、决定、理由，以及今天还成不成立

> **这份是「过程账 + 现役核验账」。**
> 姊妹篇 [`retrospective.md`](retrospective.md) 是「结论账」——它回答「你做了什么、现在到哪了」。
> 这一份回答另外两个问题：**当时是怎么走到那个结论的**，以及 **那个结论今天还成不成立**。
> 两份并存，互相链接，不要合并 —— 体裁不同，混在一起两边都会变钝。
>
> **产出日期**：2026-08-22 · 本地 `main` @ `27df42c0`
> **末次复核**：2026-08-24T09:18Z · 本地 `main` @ `a4a6ba31`（两天里 `dda56f41..a4a6ba31` 共 **104** 个提交，其中 **93** 个非合并）。本次只改了会**因时间流逝而变假**的那几条（[§3.1.1](#311-未鉴权写入洞--postgres-的-public-默认从来没人-revoke)、[§6.1](#61--最要紧的一条一批已完成已验证的决策只活在未合并的分支上)），旧读数一律保留、不就地替换。**8-22 之后新产生的决策与踩坑尚未采矿，不在本文内。**
> **主力来源**：3250 条提交里 **1500 条正文超过 300 字**的提交信息（本仓库的提交正文用中文写，且大量直接写明「为什么这么改、为什么不那么改」）。这是**当时写下的**一手记录，比任何事后回忆可靠。
> 其余来源：`docs/tech-debt.md` 的判词、`docs/decisions.md`、`docs/handwrite/` 作者亲笔、`.claude/audit/` 下的只读审计报告、以及回到代码与线上的逐条核实。
>
> 相关：[回顾](retrospective.md) · [产品决策登记](decisions.md) · [技术债](tech-debt.md) · [党纲](handbook/shared/charter.md) · [转向史](handbook/shared/evolution/pivots.md)

---

## 目录

1. [怎么读这份文档](#零怎么读这份文档)
2. [一条方法论：拿真框架盖单独该认的事实](#一一条方法论拿一个真实成立的框架去覆盖一个该单独承认的事实)
3. [**被推翻的决策**](#二被推翻的决策)
4. [决策与踩坑逐条](#三决策与踩坑逐条) — 安全权限 · 身份登录 · 钱 · 供应链 · 三端客户端 · 交付发版 · 工作方式
5. [否定式决策：补证据链 + 逐条复核](#四否定式决策--补上证据链并逐条问今天还成立吗)（36 条里 7 条已被推翻）
6. [决定「不修」——判词就是决策](#五决定不修--判词就是决策)（55 条判词 · 3 条【永远不做】）
7. [只存在于会话里的材料（本次抢救）](#六只存在于会话里没进任何账本的材料本次抢救归档)
8. [这份文档自己的边界](#七这份文档自己的边界)

## 零、怎么读这份文档

每条决策按同一个骨架写，六栏：

| 栏 | 意思 |
|---|---|
| **问题** | 当时碰到的是什么 |
| **试过什么** | 走过的弯路、被排除的路子 —— 这一栏是 `retrospective.md` 里没有的 |
| **什么起了作用** | 真正解决它的那一下 |
| **决定** | 由此定下来的规矩 |
| **理由** | 为什么。原文写得好的地方**直接引原话**，不改写成平淡的转述 |
| **今天还成立吗** | ✅ 成立 / ⚠️ 已变 / ❌ 已被推翻 / 🔍 未验证 |

**最后一栏是这份文档区别于普通回顾的地方。** 它逐条回代码、回线上核过，不照抄旧文档 —— 因为旧文档已经被当场证伪过好几次（见 `retrospective.md` 第九章）。

**纪律：已落地 = 已验证。** 拿不准就写「未验证」，不写「应该」。凡是标 🔍 的，都是我看到了代码但没有跑通、或者没有线上证据的。

标记：
- 【推翻】—— 推翻了此前自己的决定，在[第二章](#二被推翻的决策)有专门条目
- 【否决式】—— 想清楚了才**没做**的事
- 【取舍】—— 明知代价、选择承担

---

## 一、一条方法论：**拿一个真实成立的框架，去覆盖一个该单独承认的事实**

放在最前面，因为它比任何一条具体决策都更耐用 —— 具体决策会过期，这条不会。

### 病灶长什么样

**每一句单独看都不假，但合起来盖住了一个该单独说出口的事实。**

推论：**框架越真，盖得越严实。** 因为每一句都经得起查，自查抓不住 —— 只有**不吃那个框架红利的人**才拦得下来。

四个真发生过的实例：

| 那个真框架 | 被它盖住的事实 | 本次核实 |
|---|---|---|
| 「已签名已公证的产物在手」 | main 领先若干个未验收提交 | 🔍 群聊记录，未独立复核 |
| 「这是早期预览」 | 这块压根没接通 | 🔍 群聊记录，未独立复核 |
| 「在开源边界之外」 | 这个 `nil` 是当 bug 挖出来的 | 🔍 群聊记录，未独立复核 |
| **「匿名可执行的是 0 个」** | **登录用户可执行的有 72 个** | ✅ 已核实（下方） |

第四条差一点就成功了 —— 它作为一句陈述**完全正确**：`upsert_self_machine` 修完之后，anon 确实一个都调不了。而 72 这个数字来自一次独立的人工审计（`.claude/audit/definer-authenticated-triage.md`，72 个函数逐个读函数体，判出第 3 档 4 条）。全过程见[§3.1.1](#311-未鉴权写入洞--postgres-的-public-默认从来没人-revoke)。

> 前三条我只有群聊里的转述，**没有回到当时的提交或线上去核**，所以按这份文档自己的纪律标 🔍。第四条是这轮亲手核过的，它一条就够撑住这个论点。

### 变种：**新时刻污染旧事实**（2026-08-22 新增，由 PendingBot·机长 21-1 提出并自陈）

前面四例都是「真框架盖住真事实」。这一例形状不同，而且更隐蔽 —— **没有框架，只有排版**：

> **一条新鲜的时间戳和一条陈旧的结论放在同一段里，读的人会默认它们同龄。**

实例就发生在这份文档的写作过程中，来源是本文的委托方本人：他在一条消息里先贴了一张 **09:50:33Z 现跑**的 TestFlight 构建表，紧接着下一段写了一条**前一天 21:43Z** 查的外部组结论，没给后者自己的时间戳。我按那个新鲜时刻理解了整段，于是在上一版文档里凭空造出一个「84 秒内翻转」的谜团。**每一句都是真的，并排放在一起就产生了假信息。**

**为什么写的人察觉不到**：在他脑子里那两件事本来就分得清 —— 一个是今天现跑的，一个是昨晚查的。**时间戳的外溢只发生在读的人那一侧。**

**所以规则是**：**时间戳只属于它标注的那一条事实，绝不外溢。** 同一段里有两个不同时刻的观测，就得各带各的时刻，哪怕看起来啰嗦。

📌 **这一例署名保留，不匿名化 —— 这是他本人的要求，理由是：「一个只收录别人错误的方法论清单，说服力要打折。」** 本文认同：上面那四例的来源同样是这个项目自己。

### 自检法

**把框架先摘掉，只念那个事实本身，看还敢不敢下同样的结论。**

一句话版本：**框架的作用是决定怎么处理，不是决定要不要承认。**

摘掉框架之后，合法的结论只有两种形状：

- **「不在本次交付内」** → 事实**原样保留**在账本里，一个字不改，只是这次不处理
- **「已处理 / 已定性」** → 真的做了点什么

**没有「因为不归这次管，所以从账本里划掉」这一种。**

### 它在这个项目里已经长成了机器闸门

这条不是纯口号 —— 2026-08-21 的 definer 闸门里，它被翻译成了一条可执行规则（`3719812d`，分支 `fix/definer-execute-revoke`）：

> 黄色维度不因自身理由阻断，**但也不静默放过**：必须登记书面理由 + 过期时间，而且**登记过的条目每次跑仍然打印 WARN**。
> 原文：**"Someone wrote down why" is not "it was dealt with".**

四条真发现登记时，每条理由的第一句都写死成 `REAL FINDING, not cleared`，并挂 2026-09-21 过期，到期重新拦截。**「登记进 allowlist ≠ 判定为安全」**被写进了机器，不再依赖谁记得。

---

## 二、被推翻的决策

**一个项目的判断力体现在它改过什么，不只在它坚持了什么。**

`retrospective.md` 把这件事压成了一句「当天 / 次日自我推翻至少六次」。它值得展开 —— 因为每一次推翻背后都有一条明确的理由，而那些理由比被推翻的决定本身更耐用。

### 2.1 开源 → 闭源 → 开源（跨度 79 天，翻了两次）

这是幅度最大的一次，也是唯一一次**决定先于说法、说法事后追认**的。

| 时间 | 动作 | 证据 |
|---|---|---|
| 项目之初 | 仓库带 MIT LICENSE + `README_EN.md` + 完整对外框架（badge / 贡献指南 / 双语） | 见 `b2bcaeda` 的删除清单 |
| **2026-06-04** | **一次提交删掉三样**：`LICENSE`（-21 行）、`README_EN.md`（-116 行）、README 的对外框架（-140/+35） | `b2bcaeda` |
| 2026-06-20 | handbook 写下「PendingBot 这一半**不开源**」「PendingBot 是闭源商业产品」 | `d35e6806` / `4d47072f`，`handbook/pendingbot/vision.md:77`、`handbook/pendingcrew/vision.md:43` |
| **2026-08-21** | README 换回对外版、**LICENSE 原样恢复**（「内容原样取回, 未改一个字」） | `72c31852` |
| **2026-08-21/22** | `github.com/syncmeta/PendingBot` **建库并公开** | `gh repo view`：`visibility: PUBLIC` · `license: MIT` · 建于 `2026-08-21T07:44:08Z` · 最后推送 `2026-08-22T09:16:01Z` |

- **今天还成立吗**：❌ **「不开源」已被彻底推翻，且已落地。** 仓库现在是公开的、MIT 的。核实手段：`gh repo view syncmeta/PendingBot --json isPrivate,visibility,licenseInfo`。
- **值得单独指出的一点 —— 顺序**：`b2bcaeda`（6-04）的正文里**一个字都没提「因为我们决定不开源了」**，它写的是「去掉开源对外框架，改成私有产品的内部说明」，理由栏全部落在「修正过时事实」上。**真正的定性是 16 天之后（6-20）才写进 handbook 的。**
  换句话说：**动作在前，理由在后。** 后来读 handbook 的人会以为「先定了不开源，才删的 LICENSE」，实际顺序是反的。
  > ⚠️ 这一条修正了此前流传的说法：「handbook 那句是三周之后（6-26）写的」。实际是 **6-20**（`d35e6806`），间隔 16 天不是三周。`git log -S` 可复现。
- **推翻的理由**：目前只在提交里看到执行，**没有在任何账本里看到「为什么翻回来」的书面理由**。这是这份文档发现的一个真实缺口 —— 一次幅度这么大的转向，理由只存在于会话里。🔍

### 2.2 「自动检测账本漂移」建了当天就撤（`c93f1113` → `915429a9`，2026-06-26）

- **问题**：三本账（期望 / 现状 / task）之间会漂移，想让机器盯着。
- **做了什么**：同日建了 `scripts/reconcile-check.ts` + 单测 + `reconcile-allowlist.json` + lefthook 门 + `reconcile:check` 脚本。
- **当天撤回**。删得干干净净，连 `reconciliation.md` 里那条自相矛盾的「fail-loud 断言」bullet 一起删。
- **理由（原话）**：用户「**不要这个东西——不需要保持现状和期望的强一致和监控漂移**」。撤回提交自己补了判据：handbook 白纸黑字写着 `reconciliation.md`「不自动检测 drift——差靠人读两本」、`cockpit.md`「驾驶舱不替人判 drift、不重解析文档」，**「同日建的自动断言 + lefthook 门正是自动检测+强一致，违背定调」**。
- **为什么这条值得记**：这不是「方案不好用」，是**「它违反了我们自己刚立的边界」**。项目里少见的、以自定纪律为唯一理由的撤回。
- **今天还成立吗**：✅ 撤回成立且被守住了。11 天后（`48601a07`，2026-07-07）roadmap spec 里残留的同一条断言又被追着撤了一次 —— 说明这条定调后来还在起作用。
- **标记**：【推翻】【否决式】

### 2.3 语音走 AI Gateway —— 两次上、两次撤，第三次才带着诊断成功

- **问题**：想让语音的 token 用量也落进 AI Gateway 的可观测面板。
- **试过什么**：2026-05-17 一天之内两次上线、两次 revert（`d3a4c344` 撤 `85518aa5`、`33826c25` 撤 `ca1c2bc9`），两条 revert 的正文都是机器生成的一行 `This reverts commit …` —— **没有记任何理由**。
- **什么起了作用**：同日第三次 `584310de`，这次正文把话说全了：把 sideband 走网关的 OpenAI passthrough，**并明写代价**——「The OpenAI key is sent inline as Authorization — that pins the sideband to OpenAI's own billing (BYOK-style), NOT Unified Billing」，而且**主动标出没验的那一项**：「**Unverified**: whether the gateway forwards the `?call_id=` query param to the upstream. Needs a live voice-call test at cutover — if it doesn't, revert to the api.openai.com branch」。
- **决定**：先加诊断 / 先写清未验项，再试第二次。
- **理由**：前两次是盲改盲撤，三条提交没留下任何可复用的信息；第三次带着「这条成立、那条未验、不成立就退回哪个分支」的完整交代，一次就定案。
- **今天还成立吗**：⚠️ 语音这条链路本身 **线上从未接通过一次**（`realtime_sessions` 0 行，见 `retrospective.md` §7②），所以那句 `Unverified` **至今仍是 Unverified**。方法论成立，被验证的对象不存在。
- **标记**：【推翻】【取舍】

### 2.4 Gemini 走 `/v1` → 撤回 `/v1beta`（`3be13e40`，2026-05-21）

- **问题**：先前把 Gemini 从 `/v1beta` 改到 `/v1`，理由是「v1 是正式版」。改完 403。
- **试过什么**：把 403 归因到自己的代码。
- **什么起了作用**：**拿 curl 直接打网关探真相**。探出来两件事：① `/v1beta` + `cf-aig-authorization` 返回 200，`systemInstruction` + `functionDeclarations` 都收；`/v1` 两个字段都拒（`Unknown name … Cannot find field`）——**这两个字段只存在于 v1beta 的 proto 里**。② **此前那个 403 根本不是代码问题，是网关侧 Unified Billing 的配置问题。**
- **决定**：退回 `/v1beta`，但**保留那次改动里修正过的注释**。
- **理由**：「更新的版本号 = 更好」是个直觉，不是事实；API 的能力面不随版本号单调。
- **今天还成立吗**：🔍 未验证 —— 我没有回去查当前 Gemini 腿走的是哪个路径。
- **标记**：【推翻】

### 2.5 后台美化 → 全部撤回，回到 Refine 原样（`d05e5b06`，2026-06-13）

- **问题**：自制 board 观感不好，做了一轮 UI 打磨（绿主题 / 图标分组侧栏 / 品牌 Title / 首页仪表盘）。
- **决定**：整轮撤掉，`App.tsx` 回到 `RefineThemes.Blue` + 默认 Title + index 直跳列表，删 dashboard / board-title，退掉 `@ant-design/icons` 依赖。**board 的 7 个资源 CRUD 功能一行没动。**
- **理由**：正文只写了「用户偏好」四个字。但放在项目脉络里看得懂 —— 它和「后台不做运营仪表盘 / 不自建 VPS / 身份唯一走 Cloudflare Access」是同一条线：**后台是工具不是产品，投入到它的观感上就是错配。**
- **今天还成立吗**：⚠️ 部分作废 —— 自制 board 后来整体被删（`retrospective.md` 记为史上第四大删除，-7927 行），改用 Refine + CF Access。**被撤回的那轮打磨，最终连它打磨的对象一起没了。**
- **标记**：【推翻】

### 2.6 账面上还没翻、但事实上已经翻掉的：`decisions.md` 的现状栏

不是主动推翻，是**账本没跟上**，效果一样 —— 引用它会得到错的结论。

| 条目 | 账面写的 | 实际 |
|---|---|---|
| D5（三端 UI 共享组件层） | 「❌ 未实施(规划)」 | 2026-06-09 已合 main，71 个提交 |
| D4（crew captain 来源 4 种） | 4 种 | 当前活的 RPC 只接受 2 种（该条自己在 6-19 打了降级注） |
| R1（责任主体快照） | 引用 `billing-v2.ts` / `settleUsage` / `ledger_entries` | 三者**均已退役**，按那些路径找代码会扑空（模型本身还在，承载物件换成 `pnc_ledger` + WalletDO + Polar） |

D4 和 R1 各自都在文件里补了「⚠️ 已过时」的警告 —— 这是好的做法。**D5 没有**，所以它是三条里唯一还会真的骗到人的。

---

## 三、决策与踩坑逐条

按主题分组，不按时间 —— 同一个判断往往横跨几个月才收口。
每条末尾的**今天**一栏是本次逐条回核的结果，不是照抄旧文档。

### 3.1 安全与权限

#### 3.1.1 未鉴权写入洞 —— Postgres 的 PUBLIC 默认，从来没人 revoke
`e9348ad9` `535842ff` `6e8c4076` `66615284` `3719812d` `dbd1f919` · 2026-08-20 → 08-21 · 【推翻】

- **问题**：`pendingbot.upsert_self_machine` 是 SECURITY DEFINER（以库主身份跑、绕过一切 RLS），EXECUTE 却对 **PUBLIC** 开放，而且函数体里**没有任何调用者身份校验**。任何人不用登录就能伪造任意用户的机器记录、覆写别人机器的名字、把别人的机器刷成在线、无限灌行。
- **试过**：把它当成一次手滑。不是 —— 真正的病因是**建函数的迁移只写了 `GRANT ... TO service_role`，没写 `REVOKE ... FROM PUBLIC`**，于是继承了 Postgres 的默认放行。**同一个病 2026-05 修过一批，8 月又长一个。** 缺的不是细心，是一道机器检查。
- **起作用的**：本地端到端实证（anon POST 修前 200、修后 401）→ 人拍板 → `db push` 到生产 → **线上实测前后状态码 409 → 401、零写入**。不是「应该好了」。
- **决定**：① 修洞的迁移（revoke + 函数体自校验）；② **两个维度的 CI 闸门**；③ 对全部 72 个 `authenticated` 可执行的 definer 函数做逐个人工判档。
- **理由**：闸门第二维度的提交正文把话说得最清楚 ——
  > Dimension 1 (anon/PUBLIC may EXECUTE) only changes the ticket price from "free" to "register an account". If the body then takes an id and never asks whether the caller owns it, any logged-in user can aim it at anyone else.
- **一个方法论级的副产品**：闸门规则第一版是「函数体里没出现 `auth.uid()` 就报黄」，**在这个库上会点名 16 个，其中只有 4 个是真的 —— 75% 噪音**。提交正文的判断是：`a gate people learn to ignore`。改成**传递解析调用图**（一个函数可以不自己念 `auth.uid()`，而是委托给 `_assert_group_role` / `subject_has_user_access` 这类守卫）之后，返回**恰好 4 个**，与另一次独立人工审计（`.claude/audit/definer-authenticated-triage.md`，72 个逐个读函数体）的第 3 档**完全一致**。两种独立方法，同样四个。
- **今天**：✅ **洞已在生产修掉（有线上前后对照），代码也已于 2026-08-22 合进 `main`**（`dda56f41`）。核实：`git ls-tree -r main` 能看到 `supabase/migrations/20260820073931_revoke_public_execute_upsert_self_machine.sql`，`.github/workflows/security-gates.yml` 现有三个 job（advisor + `definer-execute-gate-fixtures` + `definer-execute-gate-ledger`）。
  > ⚠️ **本文上一版这条写的是「至今没有合进 main」，那在写的时候是对的（2026-08-22T09:47Z），合并发生在之后。** 保留这句，因为它正是本文自己反复强调的那件事：**结论会过期，所以每条都得带查询时刻。**
- **合并时还多长出一条防线，值得单记**（`02ffb7b3`）：那份黄色 allowlist 是**机器读的**，所以它会随任何公开快照一起出门 —— 而它原来的理由栏写着每条洞泄露什么、一行修法是什么，**等于一份「4 个未修读权限洞 + 修法」的说明书**。改法有两层，且都是机器挡不是约定：
  1. 理由改成**指针**（类别 + `confirmed real and NOT cleared` + 指向私有登记册），细节留在 `tech-debt.md`。fixture 测试**强制**每条理由必须指向私有登记册，并拒绝匹配「revoke 配方 / 零调用方 / 死代码 / `auth.uid()` 片段 / 文件:行号」这些操作性模式 —— 两条断言都用「把详细理由偷渡回去」现造样本考过。
  2. 新增 `docs/public-snapshot-exclude.txt` + `scripts/check-public-snapshot.sh`：一份**永不发布**的路径清单 + 校验器（当前列着 `tech-debt.md`、`.claude/audit`、`progress.md`、`docs/handwrite`）。
  原文一句话概括了动机：**`so that stops depending on someone noticing at snapshot time`** —— 和闸门那句 `"Someone wrote down why" is not "it was dealt with"` 是同一条纪律的两次应用。
- **另外四条真发现没有被清掉，是被登记着的**：`resolve_crew_responsibility_shares`（唯一直接返回数据行的，能拿到整个 crew 的责任分账结构 + 顺着 `crew_parent_links` 带出上级组织）、`are_mutual_friends`、`is_bot_invitee`、`user_has_conv_with_bot`。**四条全是读、没有一条能写**，且受 UUID 不可枚举限制。每条登记的理由第一句都被写死成 `REAL FINDING, not cleared`，2026-09-21 过期后重新拦截。

#### 定义 RLS 的谓词必须绕开 RLS
`8b2c64be` `2839e972` · 2026-05-02/03 · 【否决式】

- **问题**：`is_participant()` 查 `conversation_participants` 时又触发该表自己的策略 → stack depth exceeded；`bots` 与 `bot_invites` 的策略互相 `EXISTS` → infinite recursion。
- **决定**：用来**定义** RLS 的底层判定函数一律 `SECURITY DEFINER`。
- **理由**：> security definer makes the helper bypass RLS within its body, exactly the right behaviour for a predicate that's *defining* RLS on other tables.
- **今天**：✅ 成立，而且这正是上面那 72 个 definer 函数的来源 —— **这条正确的设计决定，同时也是那类洞的温床**。两件事都得记住。

#### service_role 调 RPC 时不要在函数里依赖 `auth.uid()`
`4f2f1cdc` `a622ddfa` · 2026-05-08 / 06-03 · 【否决式】

- **问题**：worker 以 service_role 调 `accept_friend_request`，函数内部读 `auth.uid()` → 每次同意好友都报 no auth。一个月后同一个形状再犯：`get_crew_whiteboard` 在 `auth.uid()` 为 null 时主动报 auth required，而 edge 正是用 service-role 调它 → 真实 GET 持续 500。
- **决定**：service_role 调用的 RPC 显式接收**已验证的操作者 id** 作为参数；route 层已可靠鉴权时，读路径直接查表，不再套一层不兼容的 RPC auth。
- **理由**：> the worker calls it via service_role — which has no auth.uid().
- **今天**：🔍 未逐个回核全部 RPC。值得注意的是同一个形状**隔了一个月复发**，说明当时没有留下机器检查。

#### 配置缺失一律 fail closed
`defe14e2` `16bb03bc` `2a0313d6` · 2026-04-29 → 05-12 · 【否决式】

- **问题**：三处默认值都是「缺配置就放行」：生产 `CORS_ALLOWED_ORIGINS` 未设时回显任意 Origin（在允许 credentials 的认证路由上 = CSRF）；ATS 为本地开发全局 `NSAllowsArbitraryLoads`；OpenAI 不支持的地区先发 ephemeral key、连接时才收 451。
- **决定**：生产缺 CORS allowlist 直接**拒绝启动**；ATS 收窄到 `NSAllowsLocalNetworking`（只放本地网络）；地区判断 fail closed，空 / 未知 country 和 Tor `T1` 一律 blocked。
- **理由**：> A missing env var should be a loud boot failure, not a silent security hole.
  地区那条补了一句权衡：> better to refuse a legitimate user who can retry than ship a token the upstream will 451 on connect.
- **今天**：🔍 未逐条回核当前值。**但同一条纪律在别处被反向违反过**：`retrospective.md` §7 记着 `BILLING_ENABLED:"false"` 被线上 KV override 成 `true`、而 Sentry 只认 env 不受 KV 覆盖 —— **三个开关的判断方式并不统一**，任何「计费当前是关的」推理都是错的。

### 3.2 身份与登录

#### 三轮误诊：`permission denied for table users` 的真因是模拟器没签名
`a3e354f0` → `124ef069` → `63487545` · 2026-05-29 → 06-01 · 【推翻】×2

- **问题**：模拟器 email 注册报 `permission denied for table users`。
- **试过**（这一栏就是这条的全部价值）：
  1. 第一次归因：模拟器未签名 → Keychain 缺 entitlement。
  2. **被自己推翻**：修好后端 signup RPC（确有 `bot_id` 歧义 + `uuidv7` 权限回归）后，把 Keychain 结论**改判成误诊** —— 理由是「Google 登录能用，email OTP 正好撞上那个坏 RPC」。这个反驳听起来完全成立。
  3. **再次实测又推翻第二次**：ad-hoc / 未签名构建拿不到 team-prefixed keychain access group，最终让模拟器也继承 Automatic + dev team 签名。
- **完整因果链**：`project.yml` 对模拟器关了签名 → ad-hoc 构建拿不到 keychain access group → Keychain 全挂 `-34018` → 会话存不住 → supabase-swift 写请求**静默降级成 anon** → anon 对 `users` 表只有 SELECT → 报表级权限错。**病因和报错点之间隔了一整个网络往返。**
- **起作用的**：线上 `SET ROLE anon` 直接复现出一模一样的报错，把它钉死在一个角色上。
- **沉淀的判据**：`permission denied for table X` = **表级 grant 被拒**；RLS 被拒会说 `new row violates row-level security policy`。两者不是一回事。
- **今天**：✅ 根治已落地。而且**两年份的教训被做成了机制**：`894ae797`（2026-07-05）把 `authedClient()` 改成显式 `try await auth.session`，拿不到就抛 `SupabaseAuthUnavailableError`，**绝不带 anon 发写请求**。我核过 `apps/pendingbot/Sources/Networking/SupabaseStack.swift:52-60` 仍在树上。原话：> 拿不到就抛 SupabaseAuthUnavailableError……绝不带 anon 发写请求。

#### 登录码上线当天被 Clerk 取代，Clerk 三周后又被 Supabase Auth 取代
`b3ff6b66` `2c3ea15e`（04-28）→ `aea77922`（05-01）· 【推翻】×2

- **试过**：先从「分享链接含不透明兑换 token」简化成自包含登录码 `pbk1.<base64url(json)>`，理由是 `dramatically simpler` —— **同一天**就被 Clerk 托管登录取代。三天后 `aea77922` 整体采用 rewrite 主干，**Clerk / BYOK / ProfileView 一起被放弃**。
- **理由**（`aea77922` 原话）：> abandons the Clerk + BYOK + ProfileView work that landed on main between bf1b82e and c0e7980 — that path is being superseded by the rewrite.
- **今天**：✅ 三次转向的终点（Supabase Auth）今天仍是现役。这条的价值不在结论，在**同一周内推翻两次仍然是对的** —— 早期方案的沉没成本值不了几天。

#### Apple 登录 403 的真因不是 nonce，是 bundle id 的信任关系
`f9944b4f` `4f13d796` `d6cfd498` `c69767ed` · 2026-04-28 · 【推翻】

- **问题**：bundle id 从 `com.pendingname.pendingbot` 改成 `com.pendingname.bot` 后，Apple 登录报 403 `authorization_invalid`。
- **试过**：加 nonce，并试图把 nonce 继续传给 Clerk（SDK 签名只收 `(provider, idToken)`）。**「缺 nonce 导致 relying party 拒绝」是个听起来很对的假设。**
- **起作用的**：**从 JWT 的 `aud` 字段定位到 bundle id**。
- **决定**：把 bundle id 改回去，**不是**去补注册。nonce 留在 Apple request 里做 replay protection，但**不当成 403 的修复**。
- **理由**：> Cheaper to revert the rename than re-register an App ID, regenerate the .p8 SIWA key, and re-fill Clerk. The bundle id is invisible to end users either way.
- **今天**：✅ bundle id 至今是 `com.pendingname.pendingbot`。

### 3.3 钱

这块是全项目设计得最细的地方，也是「否决式决策」最密集的地方。

#### PNC = 27:1，故意不好心算
`36526261` · 2026-05-29 · 【取舍】

- **决定**：1 USD = 27 PNC。**故意不是 100 / 1000 这种好心算的整数。**
- **理由**（原话）：> PNC 保留 27:1 USD（产品有意为之的不便心算，参考游戏内货币策略）
- **今天**：✅ **成立，而且这条产品不变量被写进了代码注释来防止后人「优化」掉** —— `apps/edge/src/billing/pnc.ts:2`：
  > 产品不变量：27 PNC = 1 USD（故意不整除，防心算，降消费痛感——别改回 100/1000）。

#### 砍掉 reserve/settle 状态机，全路径 settle-only + 0.5 PNC 透支
`36526261` `06f06e06` · 2026-05-29 · 【取舍】【否决式】

- **问题**：真实扣费经常要等请求完成才能确定；如果每条路径都维护 reserve/settle 两阶段，预付余额的状态机会复杂到失控。
- **决定**：全路径 settle-only，允许 **0.5 PNC** 透支；语音 / 沙箱周期结算，余额 ≤ 0 即终止。
- **理由**：把**少量透支**当作换取一致结算模型的成本，而不是在每次调用前做精确预留。
- **今天**：✅ 成立。`apps/edge/src/durable-objects/wallet.ts:17-19` 仍有 `OVERDRAFT_FLOOR_MICROS = -0.5 * MICROS_PER_PNC`，注释写着「兜流式最后几 token 估算误差」。

#### 群资金用 share-index，且**不提供提现**
`36526261` `90532e9c` `207d5203` · 2026-05-29 · 【取舍】【否决式】

- **决定**：contribution 记录加入时的 share index，消费按比例衰减，退群按 `contributed × current_idx / idx_at_join` 计算且**向下取整**；所有角色可充值，**没有任何提现接口**。
- **理由**：两条各自独立 ——
  > Floor (not round) on share_now so we never over-refund; tiny dust stays in the pool.
  不提供提现是 `to avoid "金融服务" compliance scope`。
- **今天**：✅ 成立。`supabase/migrations/20260602150732_group_pledges.sql:39,47` 两处都是 `floor(...)`。

#### 欢迎金的幂等口径从 userId 提到「规范化邮箱」
`6ab22018` · 2026-06-04 · 【否决式】

- **问题**：欢迎金按 `userId` 去重，但**同一个人可以用 Gmail 的 `+tag`、点号、`googlemail` 别名注册出多个 `auth.users`**，各领一份 35 PNC。原来那条 `external_ref='signup:'+userId` 只挡得住同一用户重试。
- **决定**：在 **DB** 里统一规范化邮箱，发额度前原子认领 `welcome_bonus_grants.normalized_email`（主键）。同一 subject 的失败重试仍放行。
- **理由**：> Gmail 忽略 local 的 '+tag' 和 '.'，这些其实是同一信箱。
- **今天**：✅ 迁移 `20260604102812_welcome_bonus_email_normalization.sql` 在树上，`welcome_bonus_grants(normalized_email PK)` 已建。⚠️ 但**规范化规则在 SQL 和 TS 里各有一份，靠手动保持同步**（`docs/tech-debt.md` 有专条）—— 这是这个修法自带的新债。

#### 缓存 token 是输入 token 的**子集**，不是加项
`59f7d19c` `efda5603` `75273e87` · 2026-05-11 · 【否决式】

- **问题**：iOS 没上报 `cached_tokens`，Worker 把缓存命中的语音输入**按全价计费**，`silently overcharging on every cache hit`。
- **起作用的**：认清 GA 的 `cached_tokens` 字段语义 —— 它是 audio/text input token 的 **SUBSET, not additive**。
- **决定**：缓存部分从完整输入 token 里**扣除**，按 `cached_input_price` 单独计一次。
- **今天**：🔍 未回核当前语音计费代码。**注意**：语音链路线上 `realtime_sessions` 0 行、**生产从未接通过一次**，所以这条修正至今没有被真实流量验证过。

#### 计费的真相源在两天内被自己推翻两次，最后定成三段式
`9754f753` `ff9135f7` `6f373b5d` `336183a5` · 2026-05-15 → 05-16 · 【推翻】×2

- **试过**：① 先把本地 alias 价目表定为 debit 真相源 → ② 发现「the table drifts and mis-bills」，**完全删掉 `computeCost`、只信 provider 上报的 cost** → ③ 又发现 WorldRouter 和语音**根本不报 cost**，那些 turn 全成了 `skipped`。
- **起作用的**：承认没有单一来源可用，改成**混合优先级**：上游明确报 cost 时优先 → voice_call 用本地音频价拆分 → 其余无上游 cost 的查 AI Gateway Logs，日志未入库时延迟重试。
- **今天**：⚠️ **这条链条今天有一个致命断点**：`CF_AIG_TOKEN` **从未部署**，所以三条原生腿的成本恒为 `null`、扣费分支根本不进。而且 `retrospective.md` §8 特别警告：**不能单独补这个 token** —— 成本查询原本只扫最近 100 条日志且不按 `turn_id` 过滤，补了 token 会从「不扣费」变成「重试到死信队列」。规模坑的代码侧修复在分支 `fix/aig-cost-lookup`（`1dd2a46e`，改成按 `turn_id` 让网关侧过滤），**也还没合 main**。

#### 内部字段名不为纯展示改名而做大迁移
`5fbcfeed` · 2026-05-08 · 【否决式】

- **决定**：用户可见单位改叫 PND，**数据库继续用 `*_credits` 字段名**。
- **理由**：> the rename would require migrating audit_log / users / billing_ledger / redemption_codes plus all RPCs (billing_debit, billing_credit, billing_redeem, billing_admin_grant) for zero user-visible benefit.
- **今天**：⚠️ 部分作废 —— 那整套 v1 credits 框架后来被 Polar + WalletDO 整体替代（见下条），连同它的字段名一起退役了。**决定本身的判断没错，只是承载它的东西没了。**

#### Billing v2 直切成权威账本，**四天后**被 Polar + WalletDO 整体替代
`79c4e289` `551296e9` `233b0543` …（05-29）→ `56b75813` `0849fa69` `61d84b5d`（06-02/03）· 【推翻】

- **试过**：把 v1 余额迁进 pack，删掉运行时的 v1 debit/gate，让 `settleUsage` / packs / ledger 成为权威路径，旧表只留冷备一周期。
- **直切（而非影子并行）的理由**（原话）：> Pre-launch, single-env, single-dev; v1 was never validated and under-recorded, so we cut over rather than run v2 as a shadow indefinitely.
- **四天后被替代的理由**：> Superseded by Polar (MoR/wallet source of truth) + WalletDO (edge cache)
- **决定**：**代码删除与历史账表物理删除分开做**（TS 代码先删，SQL 表留冷备）。
- **今天**：⚠️ 已完成替代。`docs/decisions.md` 的 R1 条目至今仍引用 `billing-v2.ts` / `settleUsage` / `ledger_entries` —— **那三样都已退役，按它找代码会扑空**。R1 自己补了警告，但这仍是账本漂移的活样本。
- **WalletDO 为什么必须存在**（`retrospective.md` §4.2 记的理由，此处保留）：Polar 余额最终一致、刷新约 10 秒（实测），进不了「每次 LLM 调用前判一下」的热路径；用 KV 也不行 —— 余额是高频递减计数器，最终一致 + 后写覆盖会丢扣减、会超支。

#### 余额门禁只拦用户发起的入口，不在系统级级联中途拦
`cb908a66` · 2026-05-07 · 【取舍】

- **决定**：messages / envelope / review 这些**用户入口**调 `requireBalance()`，不足返 402；title、lookback、bot_note 这类由已过门的动作触发的级联**继续计费但不重复 gate**。
- **理由**：> they're already caused by the gated user action upstream and aborting them mid-cascade just leaves dangling state.
- **今天**：⚠️ 这条取舍的一个后果被单独记进了 `retrospective.md` §7 危险区：**`runTitle` 的标题级联永远 free 从不计费**。也就是说「不重复 gate」在实现上滑成了「不计费」，两者不是一回事。🔍 我没有回核这两者今天是否已经对齐。

### 3.4 供应链与外包

这一整块的根都是同一条信条：**不重复造轮子，不碰技术红海。** 分工是「我们做应用搭建与设计，底层工程交给专业的人」。

#### 「WorldRouter 全目录统一七折」被逐模型核价推翻
`3ae24e5e` `6d42b596` `b3ad841d` · 2026-05-07 · 【推翻】

- **试过**：把 WorldRouter 全部价格按 OpenRouter 的 **0.7 倍**估算写进 seed；随后又被口头确认成「verified flat-30%-off」—— **估算措辞被改写成了确认措辞**，这一步是关键的错。
- **起作用的**：**对照公开定价表逐模型换算**。结果：闭源模型确实是 0.7×，但 `kimi-k2.6` 是 **0.887**、`glm-5.1` 是 **1.067**、`deepseek-v4-pro` 是 **2.80** —— 后两个**比 OpenRouter 还贵**。据此写入真实价格并把这两条的路由权重反转。
- **决定**：新 provider 必须逐模型核价，不能套全局折扣。
- **理由**（原话）：> Lesson going forward: any new provider added needs per-model price verification, not a global discount assumption.
- **今天**：❌ WorldRouter 整条已作废（`be1939d2` 软下线 —— **不能物理删除，因为历史 `audit_log` 通过外键引用它的 alias**，DELETE 直接失败）。当前主路径是 AI Gateway Unified Billing、OpenRouter 留 fallback。**但那条教训是这份文档里迁移性最好的一条**，与第一章的方法论同源：「统一七折」是个真实成立的框架，它盖住了「有三个模型不在这个折扣里」这个该单独核的事实。

#### 豆包语音上线当天删掉
`61ceb138` `7f3dbec3` `f98c2a8a` `8513ad2d` `6019a7e6` · 2026-05-11 · 【推翻】

- **试过**：OpenAI + 豆包双 provider 语音；豆包走 SpeechEngineToB SDK（这会把 CocoaPods 拖回 iOS 工具链）。备选方案是自建 Durable Object WebSocket 代理。
- **起作用的**：**读完两家的官方文档**。
- **决定**：语音只保留 OpenAI Realtime；iOS 工具链恢复 SwiftPM-only。
- **理由**：> The Volcengine Realtime API has no equivalent to OpenAI's pre-baked-session ephemeral token
  —— 没有等价的预烘焙临时令牌，意味着**系统提示词和静态凭据会下发到设备**。而自建代理方案：> Not worth the implementation cost for an experimental feature where the bot creator is always the caller anyway.
- **今天**：✅ 成立，豆包相关 SDK / CocoaPods / 字段 / 密钥引用全部不在树上。

#### Daytona 不用官方 SDK，用 REST
`4f64b8e2` · 2026-05-06 · 【否决式】

- **理由**：> Skips the @daytonaio/sdk package because it pulls Node built-ins that Workers can't load.
- **今天**：❌ Daytona 整条已被 Cloudflare Sandbox SDK 取代（`apps/edge/src/lib/sandbox.ts`）。**但「SDK 会拖进 Workers 加载不了的 Node built-ins」这条判据仍然是选型时该先问的第一个问题。**

#### 内部工具不值得套 MCP —— 脚手架当天删
`216d7592` `2dd5d7e3` `84f5e69b` · 2026-05-15 · 【推翻】

- **试过**：低层 `Server` + `InMemoryTransport`，把 per-call context 塞进 MCP 的 `_meta`；高层 `McpServer.registerTool` 也试了，但 **zod v3/v4 泛型超过 TS 的 instantiation budget**（编译器直接不干）。
- **决定**：删掉内部 MCP 脚手架。内部工具继续直接函数调用，**MCP 边界只放在外部 vendor**。
- **理由**：> After deciding internal tools stay as direct function calls and only vendor MCPs ride the MCP path, that scaffold buys nothing.
- **今天**：✅ 成立。

#### Firecrawl → Tavily，理由是「能不能对账」
`5a4c783f` `1bd81990` · 2026-05-15 · 【取舍】

- **问题**：Firecrawl 同步 scrape **不返回 `creditsUsed`**，而 PDF parsing / proxy / extraction 这些动态参数又会改变 credit 倍数 → 本地价目表对不上账。
- **决定**：默认切 Tavily extract（响应直接给 `usage.credits`）；**Firecrawl 实现留着不删**，密钥降为可选、缺失时明确拒绝调用。
- **理由**：选型的第一判据是「能提供可核对用量」，不是「效果更好」。留旧实现是为了「万一需要切回来 / 后面想做按场景路由还能直接复用」。
- **今天**：✅ 两家都还在树上（`apps/edge/src/lib/web-meter.ts` 等）。

#### 外部工具必须只有一个计量闸口，失败也照样记账
`8f8c357a` `8771b60d` `c376296b` `854d7869` · 2026-05-11 · 【否决式】

- **问题**：七个 provider helper 可以被直接调用**绕过计量**；LLM / 来信在工具调用之后失败时，上游配额已经消耗，却既没审计也没扣费。
- **决定**：把 provider helper 设为 module-private，只公开必经的 `runWebSearch` / `runWebScrape`；每轮持一个 `WebToolMeter`；**成功、错误、abort 三条路径都把 snapshot 合进同一条 audit/debit**。
- **理由**：> the upstream provider already consumed those quotas regardless of how the turn ended
  以及 > there is no longer any way for a caller to invoke a provider without metering.
- **今天**：🔍 未回核。但同族的更强版本在 2026-08-19 落地了（`596a1b6f` / `59c2a4e7`：失败的 LLM 回合也写进 audit 并带出真因），见 [§3.7](#37-工作方式与账本)。

#### Prompt 从「Langfuse 覆盖、本地兜底」改成「三层皆空即 throw」
`17312c30` → `714a4da8` `92dc5d97` `45619a7f` · 2026-06-04 → 06-06 · 【推翻】

- **问题**：Langfuse 最初只是 override 层 —— 开关关掉、缺 key、单条拉取失败、Langfuse 整体宕机，**四种情况都会静默回落到 bundled `.md`**，继续服务一份可能已经陈旧的提示词。
- **决定**：改成 L1 内存 → `PROMPTS_KV` → Langfuse miss 拉取回写。**三层都空就抛错。删掉全部 bundled prompt。**
- **理由**：代码注释里写得最好（`apps/edge/src/llm/prompt-loader.ts:9-11`）：
  > If all come up empty, getPrompt THROWS. **A wrong-but-plausible stale prompt is worse than a loud failure**, so we don't keep a bundled copy.
- **代价当时就写清楚了，没藏**：hard dependency、KV 无 TTL、webhook 顺序与最终一致性。
- **今天**：✅ 落地且仍在。`apps/edge/prompts/` 下只剩 `skills`，bundled prompt 已绝迹；`prompt-loader.ts:174` 有那个 throw。
  ⚠️ **但那三条代价里有一条已经发作**：`LANGFUSE_WEBHOOK_SECRET` **未部署** → prompt 变更推不进 KV，而 KV 又没有 TTL → **改了 prompt 线上可能长期不生效**（`retrospective.md` §7 危险区第 9 条）。
  📌 附带一条好的连带决定：`265a5560` 给 PendingCrew 打了本地 prompt bundle，理由是「**开源核心不依赖 edge/Langfuse**」—— 同一个「单一真源」的纪律，在开源边界上被正确地网开一面。

### 3.5 客户端与三端

这一整块的共同形状是：**表面症状指向 A，真因在 B，而 A 上的修补往往真的有一点效果 —— 于是把人留在错的层里。**

#### 流式回复整块跳出：不是打字机跟不上，是 `AsyncBytes.lines` 吞掉了 SSE 的空行
`57e06f20` `ef1c156f` `6f53ea23` · 2026-05-08 · 【推翻】

- **问题**：长回复整块跳出，客户端看似整轮收不到 token，只在结束时拿到一个畸形 done。
- **试过**：把揭示速度从固定 100 字符/秒改成**自适应追赶**。这**确实**限制了可见延迟 —— 所以它像个修复。原文的措辞很克制：`is no longer the dominant fix`。
- **起作用的**：两件事，都在更底下 ——
  1. **`URLSession.AsyncBytes.lines` 会吞掉空行**，而 **SSE 正是靠事件之间那个空行做 flush 信号**。换成逐字节 LF/CRLF 解析器，显式保留空行。
  2. 默认 gzip 让 URLSession 等 deflate block flush 完才批量交付字节 → SSE 请求强制 `Accept-Encoding: identity`。
- **决定**：SSE 既不能依赖会吞空行的行迭代器，也不能接受会批量缓冲的压缩编码。自适应打字机**保留**，但降级为「只负责视觉追赶」。
- **理由**：> the SSE parser was masking the typewriter entirely, since no token events ever reached the reveal loop.
- **今天**：🔍 未回核当前解析器。**这条的普适价值在于那句自评** —— 一个真的有效果的缓解措施，被明确降级成「不是主要修复」，而不是就此收工。

#### 「Mac build 通过」是编译器提前中止造成的假绿
`2fdb2907` `40c65e90` `34de20d6` `050e33ef` · 2026-05-28 · 【取舍】

- **问题**：T0.1 声称 iOS 代码已用 `#if os(iOS)` 隔离、Mac build 成功。**实际没有** —— 编译器在两个 module-resolution 错误处就提前终止，**根本没走到那 100+ 个 `import UIKit` 的文件**。
- **决定**：删掉那个不存在的 module import；在 XcodeGen 里按 SDK 配 `EXCLUDED_SOURCE_FILE_NAMES`，Mac 端排除 iOS-only 子树 —— **并把这个权宜之计当场写进 tech-debt**。
- **理由**（原话，自己给自己留的坑）：> Phase 2+ shared UI work will hit surprises about what's in vs out.
- **今天**：⚠️ **部分收口了，而且方向是对的。** `apps/pendingbot/project.yml:104` 现在只剩 `EXCLUDED_SOURCE_FILE_NAMES[sdk=iphone*]: "Mac/* Mac/**/*"`（iOS 端排除 Mac 目录），第 105 行紧接着一条注释明写：**「macOS 端不再用 EXCLUDED_SOURCE_FILE_NAMES 大锅排除业务子树」**。也就是说，当年那个权宜之计被记进债、后来真的被拆掉了 —— 这是这份文档里为数不多**「登记了 → 真的还了」**的样本。

#### 列表手势：两次改错，最后回到最早那个 20pt
`ab899ba0` `100a1eb2` `3ad8e648` `75e695a1` · 2026-05-17 → 05-20 · 【推翻】×2

- **试过**：① `swallowTap + allowsHitTesting`（原文自评 `unreliable patch`）→ ② `DragGesture(minimumDistance:0)` 统一 tap/swipe —— 但 `simultaneousGesture` 从 touch-down 就活跃，**把 UIScrollView 的 pan 拦住了**，单指纵向滚不动 → ③ 改成 12pt，**真机实测仍然 hold 住单指 touch**。
- **起作用的**：**回到原来那个稳定版本的 20pt 阈值**，tap 拆回 `.onTapGesture`（约 10pt 的 tap 容差天然低于 swipe 阈值）。
- **理由**：> 实测 12pt 仍然 hold 住单指 touch … 20pt 时小 flick 既不触发 tap 也不触发 swipe，行为和之前的稳定版本一致
- **今天**：🔍 未回核。**记这条是因为它是个健康的形状：连着两版改错之后，选择回到起点，而不是继续调参。**

#### 宽屏三栏：从「窗口宽度 ±1 硬顶一次 layout」到原生三栏
`6bb83007` `3d8115af` `084dfa2d` `4b0bdfe9` `14c8707c` · 2026-06-14 → 06-18 · 【推翻】×2

- **试过**：① 去掉 detail 的 ideal 列宽只留 minWidth → 回归 → ② **用窗口宽 ±1 强制触发一次 layout pass**（原文当场自评：「把『对的布局有没有应用到首帧』从靠运气变成确定性触发」，下一笔就写「**承上一版 ±1 窗宽 nudge（那是治标）**」）→ ③ 三栏全塞进一个顶层 `HSplitView`：不再裁切了，**但丢了原生 sidebar 的圆角、半透明材质和折叠开关**。
- **起作用的**：改成**原生三栏 `NavigationSplitView`**，sidebar / 群聊 / 成员+终端各占一个原生槽位，让系统自己协商三列宽度。
- **今天**：🔍 未回核。**这条完整演示了「治标 → 承认是治标 → 换结构」这条路径，而且中间那步付出了真实代价（丢质感）才被否掉。**

#### 环境值缺失伪装成无限转圈
`598670f9` `fe07b578` `5f2629fa` · 2026-06-10 / 06-13 · 【否决式】

- **两个不同的病，同一个形状**：
  1. `FeatureSurface` 的列方法把 view **在视图图外**求值后返回产物 → 持有 `@EnvironmentObject/@State` 的 self 副本**从未成为图节点** → wrapper 永不灌注 → 首次读取 fatalError（Mac/iPad 宽屏壳启动即崩）。修法：列方法只打配置标记，真正的分支渲染搬回 `body`。
  2. 共享视图的 `EnvironmentKey` 跨平台了，**值却只在 iOS `TabRoot` 注入**；Mac 读到 `nil` 后 `guard let api else { return }` **静默退出**，既不清 loading 也不报错 → 表现为无限转圈。
- **决定**：跨平台环境依赖必须在**每个 scene root** 显式注入；缺失时 **fail-loud**。`loading=true; defer loading=false` 挪到 guard **之前**。
- **理由**：> a missing env value can never again present as an infinite spinner.
- **今天**：🔍 未回核。**注意第二条正是「静默」这条元病根的教科书形态：`guard let ... else { return }` 是完全合法的 Swift，它的问题是把一个配置错误翻译成了一个看起来像网络慢的界面。**

#### Mac 多行输入：绑定字符串看不见 IME 组字
`9aa9cc33` · 2026-08-19 · 【否决式】

- **问题**：SwiftUI `TextField(axis:.vertical)` 在拼音**组字期间**，绑定的 `String` **一直是空的** → 用 `text.isEmpty` 控制的 placeholder 压在候选字上。
- **试过**：叠一个 `NSTextField` 做 placeholder（卡在初始 frame 且吞鼠标事件）；靠 `textDidBegin/EndEditing` 同步焦点（AppKit 要等第一次真正改字才发通知）。
- **起作用的**：换 `NSTextView` —— 用 `hasMarkedText()` 判组字，用 `become/resignFirstResponder` 同步焦点，placeholder 直接在 `draw(_:)` 里画。
- **今天**：🔍 未回核。

#### Mac 文本选择：把原生控件成本从「全列表常驻」降到「一条」
`85a79958` · 2026-08-19 · 【取舍】

- **问题**：macOS 的 `.textSelection(.enabled)` 会给**每一段文字**挂一个真实 `NSTextField`，流式刷新时成本随列表文字行数线性放大。
- **试过**：用宿主 `@State` 追踪 hover —— **那会让整个 `ConversationView` 反复失效重测，等于拿一个卡换另一个卡**。
- **起作用的**：用一个**不参与 SwiftUI 依赖追踪**的 subject 管归属，只给指针所在的那条气泡挂选择 overlay。
- **口径诚实的一处**：提交自己写明「PendingBot 侧未做对应性能采样，依据是同源机制而非照搬秒数」—— **不拿隔壁仓库的实测数字冒充自己的**。
- **今天**：🔍 未回核。

### 3.6 交付与发版

#### build 号：不是数字太小，是它算自一个会丢的东西
`e32d9307` `a7a98d4e` · 2026-08-18 · 【推翻】×2

- **问题**：monorepo 丢失后从落后 origin 的状态恢复，**git commit count 从 3571 倒退到 3178** → ASC 会拒收后续所有构建。
- **试过**：① UTC `YYYYMMDDHHMM`，备用 `YYYYMMDD.HHMM` → ② 提出更可读的 `YYYYMMDD.HHMMSS`，**被作者否决**。
- **决定**：`<纪元日>.<当天秒数>`。epoch 只读一次；补 `--check` 防止 archive 用旧快照；ASC 查询闸 **fail closed**。
- **理由**（三句都值得留）：
  > 根因不是数字太小，是 build 号从 git 历史算，而历史正是会丢的那样东西。
  > 先上最小的等于把余地全留着。
  > 序号需要外部状态，而「发版号依赖外部状态」正是这轮要拆的东西。
- **作者明确接受不可读**，换单调、无外部状态、以及未来改制的空间。
- **今天**：✅ 成立，且已经用了两轮。`27df42c0`（当时的 `main` 顶）的正文：「build 20686.48872 = 2026-08-21 13:34:32Z（纪元日.当天秒数）。脚本算出并核过 ASC 当前最高 3571，不倒退。」

#### Apple 把描述文件里没有的授权**静默剥掉** —— 全链路零报错，两周没人发现
`e34384f5` `2e0148be` `ae9a9463` `061a6372` `f718859a` · 2026-08-20 → 08-21 · 【否决式】

- **问题**：直接读 `/Applications` 里那份 2026-08-07 的产物 —— 签名 entitlements 里**没有** `com.apple.developer.applesignin`，而源里有、登录页上也有那个按钮。**Xcode 在发布签名这条路径上会把描述文件没授权的键静默剥掉**：签名有效、公证通过、Gatekeeper 放行、app 正常启动，**全链路零报错**。
- **试过**：去 portal 重新 Generate 一张描述文件 —— **该项仍然不在文件里**。这一步排除了「文件太旧」，而且证据是可核的具体数字（2026-08-22 由 34-1 提供）：
  - 描述文件 UUID 从 `6b2e0702-…` 变成 `e55ffe55-…`，`CreationDate` = **2026-08-21 12:12:39** —— 确实是新签发的，不是缓存。
  - 解开后授权清单仍是**五项**：`aps-environment` / `application-identifier` / `team-identifier` / `associated-domains` / `keychain-access-groups`。**没有 `applesignin`。**
  - **对照组**：同一个 App ID 的**开发**描述文件（2026-05-28 生成）**有**这一项。
  - 连带事实：`/Applications` 里那个 8-07 装的 Mac 版，Apple 登录**从装上那天起就不可能工作**。
- **起作用的**：两路证据同一天到齐 —— ① 重新生成的描述文件仍缺该项；② Apple DTS 明确答复该能力**不支持 Developer ID**，并对相关 bug 回「此行为符合预期」。
- **决定**：`.dmg`（Developer ID 直接分发）的包里**不显示** Apple 登录入口。两个刻意的做法：
  - **不用 `#if os(macOS)` 把这块编译掉，代码原样留着** —— 因为「真正的分界线不是『macOS』，是『Developer ID 这条分发路径』。同一个 macOS 走 App Store 就有」。
  - 按**这个包实际拿到的授权**判（读嵌进包里的描述文件），**判不出来时默认不显示**：「显示一个点了没反应的按钮，比少一个按钮糟得多」。
- **顺带钉死一条边界**：> 光把键从 entitlements 里删掉不算修好 —— 那样按钮还在、还是死的，只是让构建能过。
- **一条方法论级的副产品**（`f718859a`）：机长指出结论跟作者说的对不上（作者说 SIWA 一直勾着，断言却说描述文件缺这项）—— 两件事**可以同时为真**，但原来的报错说不清是哪一种。改法是**在报错里带上它读的是哪一份、那一份是什么时候的**（描述文件自记的 CreationDate 和 UUID）。沉淀成一条通则：
  > 任何「我读到的东西不对」类断言，都该在报错里带上它读的是哪一份、那一份是什么时候的。否则断言只完成了一半 —— 说了「不对」，没说「按哪份判的」。
- **今天**：⚠️ **结论成立且已实测坐实，但这五条提交在分支 `chore/macos-release-pipeline` 上（领先 main 11 个提交），没合进 main。** 翻回来的触发条件被写死成一行：**改走 TestFlight / Mac App Store 分发的那一刻，除此之外没有别的触发条件，并且「别再去 portal 点 Generate 试」**。同时留底了走 TestFlight 的全部代价（要 App Sandbox、本地库是缓存所以是重建不是丢数据、共用钥匙串组能不能跨沙盒边界**未核实**、缺 Mac 分发证书和 MAC_APP_STORE 描述文件、ASC 上还没有 macOS 平台记录、每版首个构建要过一次 Beta App Review）。
- **状态写法值得学**：标成「已处理」，但明写**「债本身没有消失」** —— Mac 版在当前分发形态下就是少一条登录路，只是不再有假按钮。

#### README 外链检查：黑名单方向是错的
`0d694802` `32b1f7cf` · 2026-08-21 · 【推翻】

- **问题**：**状态码 200 不代表链接可用。** TestFlight 构建全过期之后照样回 200，页面上写的是「这个 beta 不收人了」—— 对读者来说和 404 一样死。
- **试过**：对 200 死链**匹配 Apple 当前的失败文案**（黑名单）。
- **起作用的**：意识到**失效方向是错的** —— 「Apple 改一句文案，检查就无声变绿，而这正是最危险的那类死链」。改成两条**正向**断言，缺了就红：`must_appear`（正文必须仍出现让这条链接有用的那个东西，比如 App 名字）+ `keep_token`（原 URL 的关键 token 必须活到重定向之后的最终 URL 里）。
- **改完当场多抓一条**：README 里 App Store 那个 TestFlight 下载链接没带区域，从本机跑会被重定向到商店首页、id 丢了 —— **状态码检查放行了它**。
- **两个方向都在真实页面上验过，不是只验红的那半**：`keep_token` 带 `/cn/` 的绿、不带区域的红；`must_appear` 换成页上确实有的词绿、换回 App 名字红。
- **挂法也是个决定**：闸门挂在**发版**（打 `v*` tag / 每周 / 手动），**不挂每个 PR**。理由：> 这些链接指向外部世界，会自己烂掉，天天红的闸门等于没有闸门。
- **抓不到的写在明处**：> 页面写着 App 名字 ≠ 你装得上（名额、设备、系统版本都可能挡）。它证明的是「这条链接还认这个 App」。
- **今天**：✅ 已在 `main` 上（`.github/workflows/docs-links.yml` + `scripts/check-readme-links.sh`）。
- 📌 **它当场抓到的三条死链，本身就是「未成立的承诺」的清单**：TestFlight 公开组 ExTest-1 里的构建**全部过期**（唯一在线的 3571 不在该组）、`docs.pendingname.com` 尚未上线、`README_EN.md` 不存在。这三条来自 `72c31852` 的提交正文，是**当时写下的一手记录**，不是转述。

### 3.7 工作方式与账本

这一块的决定不产出功能，但它们决定了前面那些决定能不能被守住。

#### 并行 worktree 让顺序编号失效 → 迁移改时间戳前缀
`dd527847` · 2026-05-10 · 【否决式】

- **问题**：多个 worktree 并行时无法可靠认领四位顺序号；建了个 registry 登记表，但 **registry 要合并之后才对其他分支可见 —— 这就完全违背了它的目的**。
- **决定**：新迁移一律 `YYYYMMDDHHMMSS_<name>.sql`，删掉 registry。旧的 `0001`–`0061` 原样保留（字典序天然让旧块先跑）。
- **理由**：> the registry only became visible after merge, which defeats the point.
- **今天**：✅ 成立，已写进 `CLAUDE.md`。

#### 「远端迁移漂移」先查并行分支，不许直接修 ledger
`b9ce7e3e` → `c759a078` · 2026-06-03 · 【推翻】

- **问题**：`db push` 看到远端有四个本地 `main` 上不存在的 migration version。**第一反应是记成 🔴 ledger drift**，并考虑 `migration repair --status reverted` 或 `db pull`。
- **起作用的**：去查**并行在飞的分支** —— 四个 version 都有真实文件，只是先应用到了共享 prod、还没合 main。
- **决定**：多 session 共用一个数据库时，「远端领先 main」先按并行分支摩擦调查；**未核实前不修 history、不 raw apply**。
- **理由**：> Normal multi-session friction, NOT ledger drift
  提交还特地表扬了拦住自己的那道闸：auto-mode 阻止直接写 prod 是 `correct`。
- **今天**：✅ 判断成立。⚠️ **但同一个账本后来真的漂了一次**（2026-07-18 的仓库事故，线上 212 条 / 本地 208 个文件）—— 见下条。

#### 从线上账本捞回丢失的迁移：**还原规则先证后用**
`363b1eeb` · 2026-08-19 · 【取舍】

- **问题**：线上迁移账本 212 条、本地只有 208 个文件，四条都落在 7-18 → 8-15 的提交丢失窗口里 —— **仓库无法完整重建生产库**。
- **做法**（这条的价值全在做法上）：**没有凭直觉拼 SQL**。先拿**已有的**三份本地迁移，把线上 `schema_migrations.statements` 按候选规则 `array_to_string(statements, E';\n\n') || ';'` 拼回去，**逐字节 diff**，一致了才敢用。然后对四条丢失的迁移逐条按数组下标取数、校验字符/字节长度，函数定义另做 md5 对照。
- **决定**：多语句迁移按**可复现的机械规则**还原；不人工臆造丢失的空行分组；不对已在线上应用的迁移再 `db push`。
- **有损处写在明处**：> 唯一有损处：语句之间的空行数不入库……功能等价，纯排版。
- **今天**：✅ 四个迁移文件在树上（`20260808041925_short_links.sql` 等）。
  ⚠️ **但「捞回来了」只是一半**：`short_links` 和 `machine_crew_index` 两张表**线上有数据、表结构也捞回来了，可是消费它们的应用代码一行都没有** —— 我核过 `apps/` 下（排除生成的 `schema.ts`）对这两个名字**零引用**。功能实现是真的没了，捞回的只是骨架。

#### 「保持当前行为」必须先核清当前到底是什么
`65d85444` `c2d539f6` `e7e2708f` `1c3ea6f7` `73b2c317` · 2026-05-28/29 · 【推翻】

- **问题**：一个任务被默认成「keep current behavior」，但 **current 实际是 878 行、基于早已废弃的 `/v1/crew` 单数 API 的旧 codex dashboard**，和 spec v2 要求的普通群聊语法完全不是一回事。
- **理由**（原话，罕见的一句自我归因）：
  > My fault: when scoping T1.4 in the original roadmap, I implicitly assumed iOS would "keep current behavior" without flagging that current == codex dashboard and that needs replacement to match spec v2.
- **决定**：范围措辞不能让旧信息架构被静默保留下来。
- **今天**：✅ 判断成立。**这条和第一章的方法论是同一个病**：「保持当前行为」是个真实成立的框架，它盖住了「当前行为是一个已经该死的东西」这个该单独说的事实。

#### 协议字段以真 schema 为准 —— 连测试都可能给你假绿
`72ee008a` `ebeaf0b0` `c8c672c8` `5cb487ee` · 2026-06-15 → 06-19 · 【推翻】×2

- **问题**：早期按印象写的 Codex app-server 字段被对方**静默丢弃** → MCP 工具、白板和 transcript 内容全部消失。
- **最坏的一处**：> 测试此前断言了这两个虚构字段（**测了个虚构却「通过」**）。
- **起作用的**：用本机 `codex app-server generate-json-schema` **逐字段核对**并换成真 schema fixture。
- **然后又推翻了一次自己**：曾误判「Codex 没有 `additionalContext`」。真相是**同名不同协议** —— claude HookEmitter 信封的 `additionalContext` 是字符串，codex 的是 map。
- **决定**：协议字段与测试 fixture 都以 CLI 生成的真 schema 为准；外部白板走原生 `additionalContext`，不冒充用户输入。
- **今天**：✅ 判断成立（PendingCrew 已于 2026-08-17 拆到独立仓库，实现不在本仓库）。**这条是「接入外部服务必查官方文档 / 生成类型 / 实测，绝不凭印象」这条纪律最贵的一次学费。**

#### 失败必须带出真因；证据不足时**停在不足**
`596a1b6f` `59c2a4e7` `c327a815` `bb491215` · 2026-08-19 · 【否决式】【取舍】

- **问题**：`withFallback` 最终只抛 `exhausted (N attempt)` —— **真正的原因（`lastError`、`routeTrace`）挂在对象上没人读**。部分非 `FallbackError` 和 delegate 失败甚至根本不写 audit。
- **决定**：统一 `auditErrorFields`；错误 message 带上最后的 provider / class / 原文；固定标记 `[llm-fallback-exhausted]` 与 `[audit-write-dropped]`；失败行默认不计费。
- **然后是这条最值得记的部分 —— 排查 DLQ 时的收尾**：线上按小时对账排除了「消息超限」这个嫌疑，也**明确证伪**了另一个：> `CF_AIG_TOKEN` 根本没部署，`GatewayCostPendingError` 不可能触发。确认那条消息写入成功后重试进了 DLQ。**然后就停在这里**：
  > 消费失败的真正原因证据不足。
  没有挂 pull consumer、没有越过只读边界，因此**保留最终根因未知**。
- **今天**：✅ 已在 `main`。**这条是「口径诚实」这条纪律最干净的一次执行：排除了两个嫌疑、坐实了一个事实、剩下的说不知道。**

---

## 四、否定式决策 —— 补上证据链，并逐条问「今天还成立吗」

`retrospective.md` §4.1 把「想清楚了才**没做**的事」列成了一份清单，每条一行。清单是对的，但一行字不足以判断它今天还成不成立 —— 本章把 36 条逐条回查了出处、前史和现役反证。

**方法**：`git log -S` 找它是不是**曾经做过又删掉**（这类最有价值）、`git log --diff-filter=D` 找删除、读 handbook 找原始理由的原话、再回代码找反向证据。原始底表见 `.claude/decision-mining/out/negatives.md`（gitignored）。

### 4.1 最大的发现：**36 条里有 7 条已经被推翻或部分推翻，而清单上看不出来**

| 条目 | 清单上写的 | 实际 | 证据 |
|---|---|---|---|
| **board 不做运营仪表盘** | 计费归 Polar / RevenueCat，board 只做内容配置 CMS | ❌ **已部分推翻** | `cf3e80f2` / `b7ce280e`（2026-07-05）恢复了 board 的计费管理端点和页面；`apps/admin/src/App.tsx:99-106,135-136` 现有套餐映射 + 钱包查询/发放页，`apps/edge/src/routes/board.ts:219-220` 暴露对应路由。**handbook 至今仍写「计费台账去 Polar」。** |
| **不做自制运营仪表盘 / 不自建 VPS** | 一整条 | ⚠️ **VPS 那半成立，仪表盘那半破例** | 未发现任何 VPS 部署目标（Docker Compose 只有留档）；但上一条的钱包发放页就是运营操作。 |
| **不自研计费引擎** | MoR / 退款 / 对账 / IAP 全外包 | ⚠️ **只成立一半** | 「核心收款 / MoR 不自研」成立（Polar）；但 `docs/superpowers/specs/2026-06-01-billing-engine-design.md:44-45` **自己就明列**群分摊、退款编排、阈值节流、周期结算、整数影子账为「自研(edge)」，`apps/edge/src/billing/` + WalletDO + `pnc_ledger` 都在。**「全外包」是回顾时的措辞收缩。** |
| **不做自定义 RBAC / multi-owner** | 三级固定角色取代细粒度权限 | ⚠️ **部分被反向证据推翻** | 单 owner 没找到反例；但 `can_manage_*` 那组布尔位并没有被取代 —— `20260524084417_subject_foundation.sql:43-49` 定义、`20260705030253_..._read_cutover.sql:250-320` 仍在读取并合并成员级权限。**现状是固定角色与细粒度布尔位并存。** |
| **Crew tab 不做编排台** | 只做查看 + 群聊语法，不起任务 | ⚠️ **旧边界已越过** | `CrewTabView.swift:3-6` 自称 `coding-session remote control`，能看进度、批权限、steer、**起新任务**；`NewCrewTaskSheet.swift` 可选 crew / runner 并提交 brief 建 session。仍没有 DAG / 工作目录 / machine 管理，所以不是「完整编排台」，但**「不起任务」这条已经不成立**，`information-architecture.md:9,17` 没同步。 |
| **不做本地 ↔ edge 双主同步（改一次性「毕业」）** | 一次性毕业 | ⚠️ **「不双主」成立，但替代方案本身已被推翻，且文档互相打架** | 2026-06-10 `6c326adf` 明确写 **「『毕业』（publish local→edge、整 crew 换后端）作废。crew 不搬家。」**，改成「本地真源 + edge 邮差信箱」；**然而 6-20 的 handbook 又写回了「一次性毕业」**。仓库内两套说法并存。 |
| **不写「对标 / 竞品 / 像 X 但更好」** | 党纲条目 | ⚠️ **按字面已有反例** | 全仓 `对标` 命中非零，例如 `docs/superpowers/specs/2026-06-10-...-integration-v2.md:3` 写「设计哲学**对标** Claude Code / Codex」。党纲把禁令限定为「写**定位**」并允许帮助理解形态的类比 —— 按这个限定范围仍成立，按字面不成立。 |

**外加一条不是推翻、但前提已经变了的**：

- **不搞 staging / 多环境** —— 现状仍是一个部署环境（`wrangler.jsonc` 只有 `env.production`），**结论成立**。但它的原始理由是「**等有真实用户、值得隔离 churn 时再分**」，而 `retrospective.md` 已记录线上有真实消息和一笔真实充值。**触发条件到没到，需要重新拍一次板，仓库里没有这个结论。**

### 4.2 有前史的（曾经做过、后来删掉）—— 这类最容易被当新点子重提

| 条目 | 曾经做过 | 删除时机 |
|---|---|---|
| `public_open` | `f89a9d55`(05-03) 建了 `private / public_invite / public_open` 三档 | `141e5034`(05-27) 从库和存量数据删除，iOS 分支 `4d68035f` 同日删 |
| slug-as-public-identity | `62ff6862`(05-21) 建 `/b/<slug>` 契约，正文写「公开 bot 的 slug 即其稳定公开身份，不轮转 token」 | 2026-06-01 `dca0e001` / `18c72371` 返工成 invite-token |
| BYOK | `4372bea2`(04-28) 起做了整套 request-scoped BYOK/quota | `aea77922`(05-01) rewrite 丢弃，`9b30aeb8`(05-21) 从模型目录删净 |
| Lemon Squeezy | `ba9d8979`(05-29) 接了 webhook | `61d84b5d`(06-03) 删除，`321008e4`(06-04) 清残留 |
| 调用级 markup | `18e47a0b`(05-07) 的 `usdToCredits` 按成本乘 markup | `8b8b30e4`(06-16) 从语音成本预览和扣费口径去掉 |
| 自研计费引擎 | v1、v2 **两代**都实现过 | v2 于 `61d84b5d`(06-03) 删除。`handbook/shared/concepts/billing-subject.md:72` 自己写着「**两度退役**」 |

**一开始就没做的**（无前史）：不做按昵称模糊搜人、不自托管 Polar、不提现成现金、不做群内任意转账、不搞 staging。

### 4.3 几条原始理由的原话（比清单上的括号注释完整得多）

- **不收 BYOK**：> 余额、节流、群分摊、退款这套机制全建立在「平台掌握成本」之上；一旦额度来自用户自带 key，这套就散架了。
  ⚠️ **同名概念要分清**：仓库里的 `local-byok` 是 PendingCrew「用本机 claude/codex 订阅态」的旧命名（`1c9a39cf` 已正名为 `.local`，理由是「**那个 key 从没被用过**」），AI Gateway 的 `GOOGLE_BYOK_ALIAS` 是平台自有 provider 凭据 —— **两者都不是「用户拿 key 抵扣模型费」**。
- **不直连 Stripe**：> Polar 底层用 Stripe，但你只对接 Polar 的 API/SDK，没有自己的 Stripe 账号/合同——满足「走 MoR、不直连 Stripe」。
- **不自托管 Polar**：> 不自托管（Polar 是托管 MoR；其开源版自托管会失去 MoR 资格，无意义）。
- **不用 Lemon Squeezy**：> 已被 Stripe 收购、正并入 Stripe Managed Payments，与「不直连 Stripe」长期冲突。（收购这个事实本身未在仓库外核验。）
- **不提现成现金**：> 充进钱包的钱不能提现成现金——这是有意规避「金融服务」合规风险。
- **不自建 VPS**：`8a042b48` 提交正文 —— > Metabase / Appsmith 都要自己跑 VPS，跟「少运维」目标冲突，也会制造单点。
- **不做 PendingCrew iOS**：> iPad 不能跑本地 coding agent（无 `Process` API + 沙盒限制）→ iPad PendingCrew 只能玩云端 crew；iOS 用户……通过 **PendingBot Crew Tab 的遥控器能力**……不需要独立 PendingCrew iOS。
  🔍 本仓库内**没有**这条被推翻的证据（handbook 仍写 macOS + iPadOS、iOS 不做）。PendingCrew 已于 2026-08-17 拆到独立仓库，那边的现状本次未跨仓核实。

---

## 五、决定「不修」—— 判词就是决策

`docs/tech-debt.md` 表面是风险登记册，但它的 1458 行里藏着另一种东西：**每一条被判成「知道有问题、但现在不修」的债，它的判词就是一次决策 + 理由。** 这比「做了什么」更能说明这个项目的判断标准。

逐条过完全文，**明确写了「为什么不修」的有 55 条**（只描述现象、没有判词的不收）。按性质分三类：

| 类 | 数量 | 意思 |
|---|---|---|
| 【本期不做】 | 23 | 有时限的推迟，将来会做 |
| 【刻意的取舍】 | 28 | 明知代价、选择承担 |
| **【永远不做】** | **3** | 明确的长期约束，不是拖延 |
| 【存疑】 | 1 | 分不清（见下） |

底表见 `.claude/decision-mining/out/techdebt.md`（gitignored）。

### 5.1 【永远不做】的三条

**这三条最值钱 —— 它们不是待办，读的人不该再去「复核」它们。**

**① Sentry 永远不做运行时 KV 开关**
> Sentry 开关保持 env + 重部署，**故意不做运行时切**。原因：(a) `@sentry/cloudflare` 的 `withSentry` options 回调签名是同步 `(env)=>CloudflareOptions|undefined`，容不下异步 KV 读；(b) **错误捕获器的 kill-switch 必须零运行时依赖，不能让它依赖 KV/DB，否则一次边缘存储抽风会顺手静音它。**「这不是债，是刻意设计」

理由 (b) 是通用的：**监控自身的开关不能建在被监控的东西上面。**
⚠️ 但这条正确的设计有个副作用已经发作：它使得**三个开关的判断方式并不统一**（Billing / PostHog / Langfuse 走 KV override，Sentry 只认 env），而 `retrospective.md` §7 把「配置文件会骗你」列为第一号危险区。**设计对，但要记住它制造了一个不一致。**

**② OpenRouter 的搜索词不补 —— provider 根本不暴露**
> OpenRouter 的搜索词无解（provider 不暴露）。**状态**: 不修（provider 限制 / 体验可接受）

**③ 猜模型永远不为「防抓包」补协议防线**
> 猜模型纯粹是自己好玩 / 测试用的，不会有任何奖励 …… **不修，且这是个决定不是拖延** …… **要修才有意义的那个未来已经被否掉了**，所以这条不是待办、不必再复核。

这条是作者亲自定的长期约束，2026-08-20 由 `6c7d6459` / `1780142a` 正式收口。**「要修才有意义的那个未来已经被否掉了」是这份文档里最干净的一句「不修」的理由** —— 它不是说风险小，是说风险的前提不存在。

### 5.2 那条【存疑】的，以及为什么它不该被算进上面任何一类

**丢失的 7-18 → 8-09 线上改动**：
> 它们在 8-18 那次部署里就永久丢了——**这是已接受的损失，不是待办**。

它写着「不再修」，但理由是**已经不可恢复**，既不是有时限的推迟，也不是长期产品约束，更不是可逆的工程取舍。**它是第四种东西：事实陈述。** 把它塞进「取舍」会让「取舍」这个词变钝 —— 取舍意味着当时有得选。

### 5.3 几条【刻意的取舍】里，理由写得最完整的

- **audit DLQ 刻意不消费**：> DLQ **刻意不消费**，卡在那里的每条消息 = 一笔丢掉的扣费。
  ⚠️ **这条已经产生实害**：2026-08-19 的只读排查坐实了确有一条消息因此丢失，「让 DLQ 可读」已被列为最高优先待办。**取舍仍然成立（没人消费是刻意的），但它的代价已经从假设变成事实。**
- **1v1 历史信任客户端**：> 这是 1v1 为省一次查询做的取舍……不必推翻这个取舍（客户端本就有缓存，回查会加一跳延迟）。
  对照组：**群聊由服务端自查最近 20 条** —— 所以这不是做不到，是明知可以而选择不做。
- **codex 审批超时判 deny，claude 无限等人**：> 这是防 codex turn 永久挂死的安全侧选择，但和 claude 不一致。
  **两端行为不一致被明写出来了，没有粉饰成「统一的容错策略」。**
- **当前最长会话只有 11 条，不加渲染窗口**：> PendingBot 线上**最长的会话是 11 条消息**。为一个当前不存在的性能问题多加一个「加载更早」按钮、改变交互，不划算。
  —— 拿线上真实数字支撑「不做」，并写明触发条件。这是「不做」最该有的写法。
- **贴底问题不复现就不照搬隔壁的修法**：> **是否同病只有在 Mac 上真用才看得出，不凭猜改。**
- **build 号保留前导零**：> 我们无法确知每个消费方怎么解析，补零是两头都不出错的那个选择。真出问题的表现是同日第二版被判成不递增 —— **会被防倒退闸当场拦下，不会静默发错版。**

### 5.4 顺带捞出来的：**49 条自我推翻的记录**

`tech-debt.md` 里标了「✅ 已解决 / 误判 / 已作废 / 被取代 / 纠正」的条目有 **49 条**，每一条都是一次「原判 → 推翻理由」。挑三条最有代表性的：

- **「surf_runs / scroll_runs 是两张死表」→ 误判**：`surf_runs` 早就 drop 了，`scroll_runs` 是**改名**成了仍在用的 `envelope_runs`。线上查询确认 `scroll_runs` relation 根本不存在。结论：> 无表可 drop；task1（死表 drop）为伪任务。**一个凭名字提出来的清理任务，差点真的去 drop 一张活表。**
- **「白板无锁 read-modify-write 可接受」→ 被真实丢数据推翻**（🟡 升 🔴）：原判是「单用户本地、写频率低」「v1 故意接受」。2026-07-17 白板历史真的丢了。修法三件套：解码失败先归档损坏字节再 fail-loud、逐条容错解码（坏一条丢一条不连坐）、flock 互斥。**原接受口径不再成立。**
- **「persona cache 的 delete helper 没人调 = 缓存从不失效」→ 假阳**：追查发现两个 refresher 写 DB 后立即 write-through，缓存始终新鲜；delete helper 只是多余件，删掉了事。**「这个函数没人调用」不等于「这件事没人做」。**

---

## 六、只存在于会话里、没进任何账本的材料（本次抢救归档）

这一章的东西都是最近两天产生的。它们的共同问题不是内容有争议，是**载体** —— 只活在群聊里，会随会话消失。逐条回代码 / 回线上核过之后归档在这里。

### 6.1 ⚠️ 最要紧的一条：**一批已完成、已验证的决策，只活在未合并的分支上**

这不是某一条决策，是一个**结构性状况** —— 而且它和 6.2 那条埋点断层是同一个病：**做完了、验证过了，但没进任何一本账**。

**这一栏被复核过三次，三次的数都不一样 —— 三次全部照录，不做就地替换。**

| 查询时刻 | `main` | 领先 `main` 的 |
|---|---|---|
| 2026-08-22T09:47Z | `27df42c0` | 6 个分支 34 个提交 |
| 2026-08-22T10:00Z | `dda56f41` | 5 个分支 28 个提交 |
| **2026-08-24T09:18Z** | **`a4a6ba31`** | **5 个分支 18 个提交**（两天里 `dda56f41..a4a6ba31` 共 104 个提交，其中 93 个非合并） |

> ⚠️ **这一段本身出过一次本文正在讲的错，照录**：上一版这两处写的是「104 个**非合并**提交」。104 是**含合并**的数（`rev-list --count`），非合并数是 93（`--no-merges`）—— 两个数都真实存在、只差一个开关，而我给其中一个贴了另一个的标签。**由第 9 段采矿的 worker 在开工第一件事上发现并当场纠正**（它给的数对，给的成因不对 —— 它以为 104 是从 `27df42c0` 算的，其实是同一区间的含合并数）。
> 归到 [第一章](#一一条方法论拿一个真实成立的框架去覆盖一个该单独承认的事实) 那族上：**这次没有框架，只有一个限定词。**「非合并」是个精确到听起来像已经核过的词，它让一个没核的数看起来是核过的。规则：**引用计数时把产生它的那条命令一起写下来**，别只写数字和形容词。

截至 **2026-08-24T09:18Z** 的逐条状态：

| 分支 | 领先 | 里面是什么 | 今天 |
|---|---|---|---|
| `feat/mac-apple-web-oauth` | 6 | Mac 端 Apple **网页** OAuth 全链路（有原生授权走原生，没有走网页）+ 本地生成 client secret 的脚本 | 🆕 8-22 之后才出现的分支 —— 它是 [§3.6](#apple-把描述文件里没有的授权静默剥掉--全链路零报错两周没人发现) 那条策略死线的**绕法**；未合 |
| `feat/ios-unit-tests` | 4 | `PendingBotTests` —— 第一个 XCTest **target** + 三批测试 | ⚠️ 仍未合，但**主张已被部分绕过**：`main` 上现在有三组 `swift` 直跑的测试（`apps/pendingbot/Tests/`）且已进 CI（`2b581b1e`），走的是另一条更轻的路 |
| `chore/self-host-docs` | 4 | 自建指南 + `.env.example` + 两条 blocker | ❌ **前提已作废**：后端不开源之后这条路不存在，`main` 上那份 400 行自建指南已被 `09575247` 整篇换掉 |
| `fix/aig-cost-lookup` | 3 | AI Gateway 成本回读**按 `turn_id` 让网关侧过滤**（规模坑的代码侧修复） | ⚠️ 仍未合，两天没动 |
| `chore/macos-release-pipeline` | 1 | 只剩一条收尾提交 | ✅ 主体已进 `main`（0.1.1 / 0.1.2 都是从这条流水线出的包） |

**上一版单列为「最要紧」的两条，两天内都翻了**：`fix/definer-execute-revoke`（未鉴权写入洞的修复 + 两道闸门）和 `chore/fail-loud-config`（anon 降级的根治）都已合进 `main`。

**但这一栏的结论没有变，只是换了主角** —— 对 `retrospective.md` 第八章「回来第一天做什么」那张表：

- **第 5 项（自动化测试）今天要改判**：不再是「写完了、卡在合并」，而是**另一条更轻的路已经落地并进了 CI，那个分支还有没有必要存在需要重新拍板**。
- **第 2 项（AI Gateway 成本回读）仍然是「写完了、验过了、卡在合并」**，两天没动。它同时是补 `CF_AIG_TOKEN` 的前置条件。

- **今天**：✅ 三次读数逐条核过（`git rev-list --count main..<branch>`）。**这份文档不动这些分支**（边界是只读 + 写文档），只把状态记下来。**保留全部三次读数、不悄悄替换旧数** —— 一份专门讲「结论会过期」的文档，如果自己就地更新掉过期的那一版，就等于承认那条方法论只对别人成立。

### 6.2 PostHog 埋点断层：两边都以为对方在发
- **核实日期**：2026-08-22，全部回代码核过。

| 事实 | 证据 |
|---|---|
| 后端定义 **8** 个规范事件 | `apps/edge/src/lib/track.ts` 的 `AnalyticsEvent` 常量 |
| 实际接线 **6** 个 | `MessageSent` / `GroupCreated` / `GroupJoined`(×2) / `VoiceCallStarted`(×2) / `VoiceCallEnded`(×2) 走 `trackEvent`；`TopupSucceeded` 走 `billing-webhooks.ts` 直接 `capture()` |
| **2 个定义了从未接线** | `GroupSubjectCreated`、`GroupToppedUp` —— 全仓零调用点 |
| 客户端 **0** 个业务埋点 | `apps/pendingbot` 全仓只有 `PostHogSDK.shared.setup / identify / reset` 三处，**一个 `capture` 都没有** |
| **两边都以为对方在发** | `track.ts:22-26` 的注释逐字写着：`signed_up` and `bot_created` are intentionally NOT here … **Those fire from the iOS PostHog SDK instead**。而 iOS 从来没实现过。 |

- **接线的那 6 个里，有 5 个挂在线上数据为 0 的路径上** —— 群聊、语音、群邀请、群充值全部零线上数据（见 `retrospective.md` §7②）。**真正可能有数据的只有 `MessageSent` 一个。**
- **这个断层的成因是一次好决定的副产品**：`5812f2bd`（2026-06-03）明确决定 **「没有真实服务端 seam 的事件登记为后续，而不是伪造」**：
  > Events with NO server-side seam are deliberately NOT faked
  这个判断是对的 —— 伪造埋点会造出错误的漏斗。**问题出在下一步：那条注释把「登记为后续」写成了「由 iOS 发」，于是一件没人负责的事看起来像有人负责。**
- **归到第一章那条方法论上**：「不伪造没有 server seam 的事件」是个真实成立的框架，它盖住了「这两个事件现在谁都没在发」这个该单独说出口的事实。**摘掉框架只念事实：`signed_up` 和 `bot_created` 至今零上报。**
- **今天**：❌ 断层仍在，`main` 上没有任何客户端业务埋点。

### 6.3 开源翻转的完整时间线
见 [§2.1](#21-开源--闭源--开源跨度-79-天翻了两次)。此处只补两条本次核实的更正：

- ⚠️ **更正**：流传的说法是「handbook 那句『不开源』是三周之后（6-26）写的」。**实际是 2026-06-20**（`d35e6806` 与 `4d47072f`，`git log -S` 可复现），距 `b2bcaeda` 是 **16 天**，不是三周。**结论（事后追认）不变，间隔要改。**
- ✅ **落地状态已核实**：`gh repo view syncmeta/PendingBot` → `visibility: PUBLIC`、`license: mit`、建于 `2026-08-21T07:44:08Z`、最后推送 `2026-08-22T09:16:01Z`。**不是「已备好未执行」，是已经公开了。**

### 6.4 Apple 的两条策略死线 —— **它们不是同一类东西，别混着引用**

这两条常被并列成「Apple 的两条限制」，但它们的**证据性质完全不同**，混着引用会让其中一条虚增可信度。

**① Developer ID 直发的 macOS 应用拿不到「用 Apple 登录」—— ✅ 实测坐实（我们真做过实验）**

完整证据链见 [§3.6](#apple-把描述文件里没有的授权静默剥掉--全链路零报错两周没人发现)：重新 Generate 的描述文件（UUID 变了、CreationDate = 2026-08-21 12:12:39）授权清单仍是五项、没有 `applesignin`，而同 App ID 的开发描述文件有。**这不是配置错，是 Apple 按分发方式扣能力**；重新 Generate 不管用，已经试过了。

**② iOS 版没法从 GitHub Release 分发 —— 📘 平台约束，不是我们的实测**

iOS 的安装通道只有四条：App Store、TestFlight、ad-hoc（描述文件里逐台写死 UDID，上限 100 台）、企业分发（Apple Developer Enterprise Program，仅限组织内部）。**iOS 侧根本不存在 macOS 那种 Developer ID 直接分发**，所以挂在 Release 上的 `.ipa`，任意下载者装不上。

**这条的正确记法是「平台机制上这条路不存在」，不是「我们试过装不上」。** 两者结论一样，但一个是可被新事实推翻的实测、一个是平台设计 —— 引用时该区分。（口径来自 34-1，2026-08-22。）

### 6.5 TestFlight 断层 —— ✅ **已亲手核实，而且核出了两处该改的说法（其中一处是我自己写的）**

**核实方式**（只读 GET，无任何写操作，凭据复用 `scripts/release/asc_highest_build.py` 的 JWT 生成）：
```
GET /v1/apps?filter[bundleId]=com.pendingname.pendingbot     → app id 6763897911
GET /v1/builds?filter[app]=6763897911&limit=200
GET /v1/apps/6763897911/betaGroups?limit=200
GET /v1/betaGroups/{id}/builds?limit=200
GET /v1/builds/{id}/betaAppReviewSubmission
```
**查询时刻：2026-08-22T09:51:57Z，09:52:33Z 复核一次，两次一致。**

**① 构建断层 —— 属实，但要换个说法才硬。** 全量 10 个构建：

| build | 上传时间 (UTC-7) | 过期 |
|---|---|---|
| `20686.48872` | 2026-08-21 06:40:56 | 否 |
| `3571` | 2026-08-10 21:05:06 | 否 |
| `8` `7` | 2026-05-21 06:00 / 03:06 | 是 |
| `6` `5` | 2026-05-20 05:48 / 03:46 | 是 |
| `4` | 2026-05-03 22:56 | 是 |
| `3` | 2026-04-29 09:23 | 是 |
| `2` | 2026-04-27 19:59 | 是 |
| `1` | 2026-04-26 06:41 | 是 |

- **「9 个构建」现在是 10 个** —— 8-21 传了一版。**这类数字必须带查询时刻，否则下一个人核不上。**
- **「5–8 月中间是空的」改成可复核的形式**：`build 8`（2026-05-21）到 `3571`（2026-08-10）之间 **81 天零上传**。「81 天空档」比「5–8 月是空的」硬。

**② 「公开组里的构建全部过期」—— ❌ 这条今天已经不成立了，而且它在我这份文档的上一版里还写着 ✅。**

| 组 | 类型 | 组内构建 | 未过期 |
|---|---|---|---|
| `PendingBot-test` | 内部 | 10 | **2**（`20686.48872`、`3571`） |
| `ExTest-1` | **外部 · 公开链接** `https://testflight.apple.com/join/K6Ju9qqP` | 6 | **1**（`20686.48872`，2026-11-19 过期） |

而且那个构建的 `betaAppReviewSubmission.betaReviewState = **APPROVED**` —— 外测审核已通过，不是「在组里但还在排队」。

**实测公开链接本身**（`curl -sL`，2026-08-22）：HTTP 200，页面正文是 **`Join the PendingBot beta`**，App 名出现 3 次。对照 `0d694802` 定的判据 —— 「beta 不收人 / 构建过期时 Apple 回的是通用页，标题只有『TestFlight - Apple』，App 名字出现 0 次」——**这条链接现在是活的。**

**③ 状态是什么时候变的 —— 一条单一时间线，不是两个冲突的观测**

| 时刻 | `ExTest-1`（公开链接组）状态 | 出处 |
|---|---|---|
| **2026-08-21T21:43Z** | 未过期构建 **0** 个，新 build 未加入 | PendingBot·机长的脚本落盘时间 |
| **2026-08-22T09:51Z 起**（三次独立查询一致） | 新 build **已在组内**、外测审核 **APPROVED**、公开链接返回真实 beta 页 | 本次核实 + 机长 09:54:57Z 复查 |

**中间十余小时内，有人把构建加进了外部组并通过了外测审核。** 就这一条事实，没有别的。

> ⚠️ **本文上一版把这件事写成了「84 秒内的一次翻转 / 两个带时刻的观测值」，那是错的，已撤。**
> 起因是机长在同一条消息里贴了一个当下时刻（09:50:33Z 的 builds 表）**又在紧挨着的下一段写了一个 12 小时前的外部组结论**，没给后者自己的时间戳。我按那个新鲜时刻去理解整段，于是凭空造出了一个「84 秒内翻转」的谜团 —— **谜团不存在，两个观测本来就不同龄。**
> 他主动核了脚本落盘时间（2026-08-21T21:43:23Z）把这件事纠回来。**这一例已提炼进[第一章](#一一条方法论拿一个真实成立的框架去覆盖一个该单独承认的事实)，是同一族病灶的一个新变种。**

**④ `72c31852` 那句话的处理**：提交正文写「TestFlight 公开组 ExTest-1 里的构建全部过期（唯一在线的 3571 不在该组）」。**写的时候是对的** —— 3571 确实不在 ExTest-1，我核过组内清单里没有它。**是这句话过期了，不是当时写错。**

**⑤ 一条连带的好消息**：README 里那条公开 TestFlight 链接（`https://testflight.apple.com/join/K6Ju9qqP`）**现在是活的**。它此前是「公开前必须做完的三件事」之一（另两件：`docs.pendingname.com` 未上线、`README_EN.md` 不存在，见 `72c31852` 正文）。**三件里这件已经消掉了。**

**④ 值得记的是它当初是怎么被发现的**：不是有人去翻 ASC，是 [§3.6](#readme-外链检查黑名单方向是错的) 那道正向断言的死链闸门把它逼出来的 —— **一个 200 状态码背后的空壳页面**。而现在同一道闸门对同一条链接会判绿。**这不是闸门失效，恰恰是它按设计工作**：它断言的从来不是「这个 beta 永远开着」，是「这条链接此刻还认这个 App」。

### 6.6 7-18 仓库事故的余波
- ✅ **迁移那半已捞回**：四条丢失迁移用「先证后用」的机械规则从线上 `schema_migrations.statements` 还原，逐字节校验过（见 [§3.7](#从线上账本捞回丢失的迁移还原规则先证后用)）。
- ❌ **代码那半没有等价账本**：`short_links` / `machine_crew_index` 两张表**线上有数据、迁移文件已捞回、但应用层零引用** —— 我核过 `apps/` 下（排除生成的 `schema.ts`）对这两个名字零命中。**功能实现是真的没了。**
- ✅ **已被消解的一条**：`retrospective.md` 曾记「线上 worker 比仓库新，任何 deploy 都是静默回滚三周」。2026-08-18 那次授权部署主动吃掉了回滚代价，此后两次从仓库部署，线上重新成为 `main` 的祖先（`1207fc7b` 已把该条标记为已消解）。**丢失的代码和缺失的 deploy guard 仍未恢复。**
- 🔍 另有一批「被报告过、但在本机 15 个仓库和两个远端都解析不出来」的提交，本次未复核。

---

## 七、这份文档自己的边界

写清楚，免得它变成下一份「会误导你的文档」。

1. **口径**：主力来源是 1500 条长正文提交（>300 字，去掉 trailer 后计），**不是全部 3250 条**。短提交里如果藏着理由，本次会漏掉。
2. **「今天还成立吗」那一栏，标 🔍 的都没验。** 全文 🔍 的条数不少 —— 那不是偷懒的托词，是**「推理成立 ≠ 已验证」**这条纪律的记账方式。要用某条结论之前，先看它是不是 🔍。
3. **✅ 的含义**：我实际跑了命令 / 读了那一行代码 / 查了线上，并把命令或文件行号写在条目里。没写出处的 ✅ 不存在 —— 如果有，那是我的错，请当成 🔍。
4. **跨仓库的部分没核**：PendingCrew 已于 2026-08-17 拆成独立仓库。凡涉及 crew 客户端实现的条目（runner、captain、白板、codex 协议），本仓库只能核到文档和历史，**代码现状未跨仓验证**。
5. **只读边界**：没有改任何业务代码，没有部署，没有碰任何线上写操作。**唯一打过的外部服务是 App Store Connect，全部是 GET**（见 §6.5，端点已逐条列出，可复跑）；Polar / PostHog / Langfuse 一个都没碰。其余线上事实来自此前已归档的只读审计报告。
6. **证据的出处链也要标**。本文引用的事实分三档，写法不同：**实测**（我或别人真跑过，带命令 / 数字 / 文件行号）· **平台约束 / 厂商规则**（不是实测，是这条路在设计上不存在）· **转述**（只有人说过，没有一手记录 —— 一律 🔍）。§6.4 那两条 Apple 限制之所以要拆开写，就是因为它们分属第一档和第二档，并排放会让第二档虚增可信度。
7. **没有做的一件事**：`.claude/decision-mining/out/` 下的原始采集（8 段共约 230 条 + 55 条不修判词 + 36 条否定式考据）**比本文详细得多**，本文是选编。那个目录 gitignored、会随工作树消失 —— **如果它值得留，需要单独决定把它提交进仓库**（就像 `docs/handwrite/` 当初那样）。

---

## 附：这份文档和其他账本的分工

| 账本 | 回答什么 |
|---|---|
| **本文** `decision-log.md` | 当时怎么走到那个结论的 · 那个结论**今天还成不成立** |
| [`retrospective.md`](retrospective.md) | 你想做的是什么产品 · 现在到哪了 |
| [`decisions.md`](decisions.md) | 拍过板的产品 / 设计决策登记（D1–D5 + 反向核实记录） |
| [`tech-debt.md`](tech-debt.md) | 结构风险 + 关不掉的尾巴 |
| [`progress.md`](progress.md) | 当前真实状态 rollup + 阻塞 + 下一步 |
| [`handbook/`](handbook/) | 期望页 —— 东西**应该**是什么样 |

**冲突时**：以本文标 ✅ 的条目为准（它们带命令 / 行号，可复现）；标 🔍 的一律以代码和线上为准，不以任何文档为准。
