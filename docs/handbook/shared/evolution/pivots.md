# 重大转向史

> 这一篇登记**拍过板的大方向掉头**:从 A 换到 B、为什么换、旧 A 现在是死的(别照它实现)。它和 [路线图](roadmap-and-status.md) 互补 —— 那篇答"要做什么、按什么顺序",这篇答"为什么是现在这个样子,不是当初设计的样子"。
>
> **为什么要有这一篇**:大绿豆迭代快,老 spec / 老注释里埋了大量已废弃的心智模型。2026-06-15 一次 9 路并行考古审计(`docs/stale-model-audit-2026-06-15.md`)发现 52 条"还按已废决策实现 / 注释"的残留。把这些转向集中讲清楚,后人读到旧 spec 时能立刻知道"这条已经掉头了",不被带跑。
>
> 每条转向的结构:**从 → 到** · 为什么 · 旧方案现状(残留清理到哪了)。证据指针给到 `docs/decisions.md`(D 编号)、`docs/progress.md`、`docs/stale-model-audit-2026-06-15.md`(R/Y/G 编号)。

---

## 1. 模型 provider:WorldRouter → Cloudflare AI Gateway 统一计费(OpenRouter 留 fallback)

**从 → 到** — 早期自建 / 设想过一层叫 **WorldRouter** 的模型路由,后来一度以 **OpenRouter** 为推理主路径。现在主路径走 **Cloudflare AI Gateway 的 Unified Billing**(四 provider 统一计费),**OpenRouter 仅留 fallback**;模型**目录**仍查 OpenRouter 的公开端点(加 CF 边缘缓存),但**推理 token 不经 OpenRouter 计费**。

**为什么** — 统一计费让"一个账户、一处结算、跨 provider"成立,省掉自己维护多家 provider 的密钥 / 计费对账;符合党纲的"关键基础设施外包、零 VPS"。edge 干脆**不持 OpenRouter key**:目录走公开端点、推理走 AI Gateway。

**旧方案现状** — `WorldRouter` 已是纯历史名词,仅在 `billing.ts` / `ai-gateway.ts` / `token-estimate.ts` 几处**注释**和一个测试名里残留命名,**零运行时残留**(审计 G10)。provider 路由已对齐:四 provider AI Gateway 主路径 + OpenRouter fallback,无用户 BYOK(Gemini 经平台自存 key 是受控合法例外)。详见 [stack/cloudflare/ai-gateway](../../stack/cloudflare/ai-gateway.md) · [stack/openrouter](../../stack/openrouter/openrouter.md) · [concepts/models](../concepts/models.md)。

---

## 2. 计费引擎:自研结算 → 外包(Polar 钱包本体 + RevenueCat iOS + WalletDO 边缘门禁)

**从 → 到** — billing-v2 阶段曾**自研一整套结算引擎**(`settleUsage` / packs / 本地账本 `ledger_entries`)。现在**结算外包**:**Polar = MoR + 信用钱包事实源**(pnc meter),**RevenueCat = iOS IAP 入账**,Cloudflare 上的 **WalletDO**(per-subject Durable Object)做**边缘门禁缓存 + 用量 outbox**(强一致、push-sync + 稀疏对账)。群分摊仍**自研**(共享池 + 认缴 pledge 模型)。

**为什么** — 计费引擎自己写要扛 MoR(merchant of record,代收税务合规)、退款、对账、IAP 入账等一大堆非核心复杂度;外包给 Polar / RevenueCat 把这些非差异化的重活交出去,只在"群成本怎么分摊"这个真正产品独有的地方自研。不直连 Stripe(让 Polar 当 MoR 挡在前面)。

**旧方案现状** — 自研结算引擎已 **#209 删 16 个文件**(billing-v2.ts / pack / lemon / iap / refund / expiry + pack cron);`packs` / `ledger_entries` / `refund_events` 表已 drop(`usage_events` 一度漏 drop 成孤儿,后续清掉)。OpenMeter SDK 已彻底删除、lemon/squeezy/iap webhook 已删干净(只剩 Polar + RevenueCat)、Stripe 从未直连。**易错点**:`decisions.md` 反向核实 R1 引用的 `billing-v2.ts` / `ledger_entries` / `settleUsage` **均已退役**,按那些失效路径找代码会扑空 —— "责任主体快照"模型本身仍在,但承载物件已换成 pnc_ledger + WalletDO + Polar 的 owner 维度(审计 G15)。详见 [concepts/wallet-pnc](../concepts/wallet-pnc.md) · [concepts/billing-subject](../concepts/billing-subject.md) · [concepts/group-pledge](../concepts/group-pledge.md) · [stack/polar](../../stack/polar/polar.md) · [stack/revenuecat](../../stack/revenuecat/revenuecat.md)。

---

## 3. PendingCrew 双轨(本地 BYOK ↔ 登录 edge):"双主同步" → "一次性毕业,不双写"

**从 → 到** — 早期设想 PendingCrew 本地 crew 与 edge crew **双向镜像同步**(原 spec §2/§7 的写法)。现在的定调(2026-06-10「接合 v2」):**不双主同步**。纯本地 crew 就纯本地(没有 edge bot 参与);一旦想要 bot / 手机参与群聊,就**一次性"毕业"**(publish local → edge),从此走 edge,而不是两边持续同步。

**为什么** — 双主同步是分布式系统里最难维持一致的形态。关键洞察:**edge bot 要参与就必须够得着白板** → 纯本地 crew 根本没有 edge bot;反过来想要 bot / 跨设备群聊,就接受一次性迁移的代价。这把"什么时候上云"变成一个明确的一次性动作,而不是一个永远要对账的同步关系。三条正交轴(通信托管位置 / 执行位置 / 接入点)各自独立,不再纠缠。

**旧方案现状** — `BackendMode` 枚举已全删,`AppModel.backend` macOS 恒 LocalBackend;两模式选择壳(WelcomeView 双模式 + LocalSetupView)成死代码(审计 Y1)。**注意**:旧的"双轨路由 `AuthMode` 优雅分流"措辞(roadmap T5.2)是这次掉头前的设计 —— 现状是"本地为家、edge 是邮差"的单向毕业模型,别照 roadmap 旧措辞理解。详见 [pendingcrew/concepts/local-first](../../pendingcrew/concepts/local-first.md) · [pendingcrew/concepts/runtime-location-and-machine](../../pendingcrew/concepts/runtime-location-and-machine.md)。

---

## 4. Captain 心智纠偏:edge-bot 编排器 → 本地 session 人格(技术接口不特殊)

**从 → 到** — 老 spec(§6.3)把 captain 设计成**一个 edge bot**:由 edge `bot-reply` 注入机长 persona、被白板消息**唤醒**去跑、持有一组 edge 编排工具(`start_session` / `create_child_crew` / `recruit_temp_bot` / `request_permission`)。现在 captain = **一个被打上机长标记的本地 session**,跑在 PendingCrew 本机、走和普通 worker session 同一套接口,**技术接口上不特殊**,只是多了机长 persona + 两个本地 MCP 工具(`answer_decision` / `rename_crew`)。**审批不归 captain**,走各 coding agent 自己的 PreToolUse 门、直接送人类。

**为什么** — 把模糊意图变可执行、把噪音收成几件待拍板的事,这件事需要判断力,适合交给一个 LLM 人格,而不是一套硬编码编排状态机。让 captain 就是个普通 session(换 persona + 多两个工具),就不必为"机长"单独造一套 edge 机制。这次纠偏由用户 2026-06-15 直接指出:`feat/captain-orchestration`(给 edge bot 挂 `post_to_crew` / `request_permission`)是**按旧心智做的、方向错了**,顺藤摸瓜触发了整个 stale-model 审计。

**旧方案现状** — 2026-06-16 审计 R1 **实删**了 edge bot-当-captain 的整个编排面(start_crew / start_session / create_child_crew / recruit_temp_bot 工具 + captain persona 注入 + crew-comms 唤醒 + crew-proposal/decide 端点,净 -1341 行)。**保留** `captain_bot_id` 字段 + `create_crew_with_captain` RPC + `POST /v1/crews` —— 调研确认它们是**客户端建 crew 的活路径**(`system_generated` 分支建一个 captain bot 作 crew 的 captain 身份),非 bot-reply 残留,不能裸 drop。

> ⚠️ **`decisions.md` D4「captain 4 种来源」已部分过时,需降级谨慎引用。** D4(2026-06-01)写 captain 有 4 种来源(含 `spawned_by_captain`)。但当前活的建 crew RPC 只接受 **2 种** `captain_source`(`reuse_bot` / `system_generated`),客户端**实际只用 `system_generated`**;`spawned_by_captain` / `create_child_crew` 那套只在 legacy `/v1/crew`(单数)路由和旧迁移注释里残留。引 D4 前先核对到这一层。captain 概念的权威定义见 [pendingcrew/concepts/captain](../../pendingcrew/concepts/captain.md)(本手册全篇过时风险最高的几篇之一,已按现状写)。

---

## 5. 模型评价:A/B 盲投竞技场(arena) → 模型盲盒(blindbox)

**从 → 到** — 早期有一套**模型评价 arena**:A/B 盲投比较(`/v1/arena/compare`)、个人 Elo / 后来的 Bradley-Terry 排行榜、`model_comparisons` 表、MeTab 榜单。现在转成**娱乐盲盒**:会话**抽一个模型即固定**(prompt-cache 友好,只 regen / 手动换才重抽),藏名显示成 `PendingModel` 让用户**猜**,猜中 / 放弃就揭晓整个会话,bot 可设惊喜 / 披露模式。

**为什么** — arena 把"评价模型"这件偏工程的事推给普通用户,娱乐性和留存都弱;盲盒把同一个"用户不知道背后是哪个模型"的机制,转成一个**好玩的猜谜**,更贴党纲"是朋友不是工具"的调性。会话内固定模型还顺带对 prompt cache 友好。

**旧方案现状** — 旧评价框架**连根拔**:删 A/B 盲投端点 + Bradley-Terry 个人排行榜 + `model_comparisons` 表(edge `arena.ts` / `arena-bradley-terry.ts`、iOS `ArenaStanding` / `Leaderboard` / `CompareResult` / `ArenaCompareCard` / MeTab 榜单全删,审计已确认 arena 评价框架连根拔)。**保留**模型池随机选(这是盲盒内核)和 `ArenaModelPoolEditor`(盲盒模型池编辑器,命名沿用,非残留)。**易错点**:旧 footer 文案曾仍承诺"盲评 → 我 → 模型竞技场榜单"(审计 G1,已改成盲盒话术);注意中间还套了一层 **Elo → Bradley-Terry** 的算法迭代,那是 arena 时代内部的事,整个 arena 已被盲盒取代。详见 [pendingbot/features/model-blindbox](../../pendingbot/features/model-blindbox.md)。

---

## 6. 数据驻留:US 区 Supabase → EU 区(Frankfurt)

**从 → 到** — 主库原在 **US(us-west-2,`sslzhblojwkxfdyisity`)**。现在迁到 **EU(eu-central-1 Frankfurt,`zafhoiwwpanpuashtnxy`)**:新建 EU 项目、全套迁移重跑、**不迁数据**(pre-launch 无真实数据),旧 US 库留作回退。

**为什么** — 用户数据 GDPR / EU 驻留。pre-launch 阶段无真实数据,正是零成本换区的窗口。观测栈也跟着走 EU host(PostHog `eu.i.posthog.com` / Langfuse `cloud.langfuse.com`)。

**旧方案现状** — edge `SUPABASE_URL` + 主 worktree linked project 均已 = EU 项目,**#250 换 EU 区 → 已 completed**。迁库过程修了一个账本漂移(`public.rls_auto_enable` 安全网早于 squash、只活在 US 库从未进账本,已逐字补回迁移,任何空库可重建)。旧 US 库待端到端全验后删除。这是 pre-launch 单环境立场下的一次性动作 —— 不是搞多区 / staging 基建(见 [charter](../charter.md) 的商业立场)。

---

## 7. 后台 board:自制 UI + 应用内登录 → Refine on CF Pages + Cloudflare Access

**从 → 到** — 早期是**自制的 board UI**(`apps/board`),带应用内密码 / OTP 登录 + Turnstile。现在后台是 **`apps/admin`**:Refine v5 + react-router SPA,部署在 **Cloudflare Pages**,身份**唯一走 Cloudflare Access**(同源 `/board` 网关),**没有应用内登录**,第二因子归 Access policy。board 本身是 CMS:把模型 slug、预设、功能开关、运营文案等可改配置收进 KV / board,不硬编码。

**为什么** — 自制后台 UI + 自己管登录是重复造轮子且是安全面;Refine 提供现成的 CRUD 后台,Cloudflare Access 把身份 / 第二因子 / 审计交给平台,符合"零 VPS、关键基础设施外包"。把配置收进 board 也兑现党纲红线"配置走 board / 前端,不硬编码"。

**旧方案现状** — 自制 board UI **已整目录删除**(`apps/board` 不存在);后台无应用内登录 / Turnstile 残留(审计反向核实 12)。**易错点**:旧 board 登录页"CAPTCHA / Turnstile"那条 tech-debt 已被 Cloudflare Access **取代**(`apps/admin/src` 对 `signInWithPassword` / `signInWithOtp` / supabase 零命中);代码里 `board.ts` / `index.ts` 等处的 `requireAdmin` / `requireSession` 旧注释已过时(实际是 Access,代码行为已对,审计 G9)。详见 [concepts/config-as-cms](../concepts/config-as-cms.md) · [stack/cloudflare/access](../../stack/cloudflare/access.md)。

---

## 8. 运营仪表盘:自制 dashboard(含 VPS) → 全托管、零 VPS 拼盘

**从 → 到** — 早期设想自制运营仪表盘(一度有 Metabase + Appsmith 的 docker-compose 留档)。现在走**全托管、零 VPS** 的拼盘:**Grafana Cloud**(营收 / 钱包 / 群池 / 成本 / 转化看板,走只读 `bi_ro` 角色)+ **Supabase Studio**(BI)+ **PostHog**(产品分析)+ **Langfuse**(LLM 观测)+ **Refine on CF Pages**(后台,见上一条)+ **Sentry**(错误)。看板与后台分家,各用各的专业工具。

**为什么** — 自己跑一台 VPS 装 Metabase / Appsmith 是运维负担和单点;全托管 SaaS 拼盘符合"零 VPS、关键基础设施外包"。每个工具只做它最擅长的一层(指标 / BI / 行为 / LLM trace / 错误),不强求一个万能面板。

**旧方案现状** — `infra/dashboards/docker-compose.yml`(Metabase + Appsmith)是 spec 明确的"**可选 fallback**"留档,**非残留**(审计反向核实 12)。Grafana provisioning dashboard + Sentry / PostHog / Langfuse 接线代码已就绪并自测,但**待用户开第三方账号 + 填 secret 才能真实端到端**。注意 Grafana 的 SQL 基于真实列(agent 一度发现 spec 的 `pnc_ledger` 表名 / `billing_ledger` 不一致,已核实纠正)。详见 [stack/grafana](../../stack/grafana/grafana.md) · [stack/posthog](../../stack/posthog/posthog.md) · [stack/langfuse](../../stack/langfuse/langfuse.md) · [stack/sentry](../../stack/sentry/sentry.md)。

---

## 9. 产品使命:信息基础设施级大愿景 → 越做越窄 → 重新校准(体验 + 桥梁)

> 前八条都是**技术 / 架构**掉头。这一条是**产品使命本身**的演化 —— 大绿豆"到底要做成什么"一路怎么变窄、又怎么被重新校准。它不是某一次拍板,而是一条贯穿始终的线;诚实记下来,免得后人拿最初那套宏大叙事去对照今天收窄后的现状,觉得"怎么差这么远"。

**从 → 到** — 从**信息基础设施级的宏大愿景**(BubbleBored 时代),一路落地收窄成"主动 AI 朋友 IM",再于 2026-06 这轮**重新校准**到"做扎实体验 + 当 crew↔人的桥梁",原始大愿景**降格为北极星**而非当下交付物。分四段:

1. **最初 · BubbleBored 的大愿景** — 机器人**参与社交网络、组织信息**,帮用户**突破信息茧房(破茧)**,经营**弱关系网络**,做用户的「**挚友 / 明镜**」。这是**信息基础设施级**的野心:不是做个聊天机器人,是做信息怎么流动、怎么被组织、怎么破茧的底层。

2. **加上灵魂特质** — 在大愿景之上叠了人格定位:**主动 / 自然 / 不谄媚**,以及**「知道自己错了的 AI」**。早期 README 逐字:「**知道自己错了的 AI · 主动上网冲浪还要处处想着你**」。两大目标 =(a)**复盘、校正彼此**(当局者迷、旁观者清);(b)**探索未知、做信息的 VC**(缓解信息茧房)。并明确划界:**不是助手,不是又一个 Agent,也不是标准 AI 陪伴,是带来新视角的朋友**。

3. **收窄(落地过程)** — 真去做三端(iOS / iPad / macOS)时,使命被现实压缩成「**主动 AI 朋友 IM**」。大愿景里那套「信息网络 / 组织信息 / 破茧」**基本没动手做** —— 不是放弃,是产能先压在"把一个能聊、会主动的 AI 朋友做出来"上,宏大那半搁置了。

4. **现在再调(2026-06 这轮)** — 一次有意识的重新校准,几处挪动:
   - **主动性从内核降级** —— 它是最初的核心想法,但后来逐渐弱化、实际也没怎么做到位;这轮把它从"内核"挪下来,不再当作定义性特质硬扛。
   - **「知错」升为核** —— 当初的灵魂特质之一(知道自己错了),现在成了 **lookback(复盘)机制的目的**,从"气质"变成"产品要交付的那件事"。
   - **价值非拟人** —— 重点是**给真价值**,不必为了"像个人"而拟人;朋友感是手段,不是要扮演人。
   - **富感知** —— 主动喂给它**天气 / 热点 / 对方处境**等环境与上下文信号,让它的反应贴合当下,而不是真空里对话。
   - **移动端做 crew↔人的桥梁** —— 三端 app 的新定位:当 **PendingCrew(crew)与人之间的桥**,配 **todolist**,把 crew 的进展 / 待办 / 待拍板的事接到人手上。
   - **和市面划清界限** —— 明确**不做**那种"一句话帮你做 X"的通用 agent;大绿豆是朋友视角的新价值,不是任务执行器。

**为什么** — 宏大愿景一次性做不出来,落地必然先收窄到一个能交付的内核(IM)。但收窄久了容易**忘了北极星、也容易把"主动"这种当初拍脑袋的特质当成不可动摇的内核**。这轮校准就是回头对账:哪些是真要的(知错 → lookback、真价值、富感知、桥梁),哪些是当初想当然、实际没做也不必硬扛的(把"主动"当定义性内核)。**原始大愿景不删,留作北极星**指方向;但当下交付**诚实收敛在"体验打磨 + crew↔人桥梁"**,不假装已经在做信息基础设施那一层。

**旧方案现状** — 这条不是"删代码"式的掉头,是**叙事与定位的校准**,残留主要在**文案 / README / 老 spec 的使命表述**里。看到老文档写着「主动是内核」「破茧 / 信息网络 / 组织信息」当作**当下在做的事**来描述时,默认它停在第 2~3 段的旧叙事 —— 现状以第 4 段为准:**主动性已降级、知错升为 lookback 之核、价值非拟人、富感知、移动端=crew↔人桥梁、与"一句话做 X" agent 划清界限**;宏大愿景仅作北极星保留。判断"大绿豆现在到底要做成什么",以本条第 4 段 + [charter](../charter.md) 为准,不以早期 README / 老 spec 的使命段为准。

---

## 注意 — 读这一篇的方式

- **这些转向都是 pre-launch 阶段的掉头**,代价低(没有线上用户 / 真实数据要迁),所以大胆做干净的新实现、不为旧路径对冲。看到老 spec / 老注释写着上面任一"从"那一侧,**默认它已过时**,以"到"那一侧为准。
- **残留清理是渐进的。** "旧方案已删 / 已退役"通常指**运行时活代码**已清,但注释 / 命名 / 旧 spec 引用可能还在(审计里大量 🟢 命名漂移)。判断"现状"以代码 + 本手册为准,不以注释为准 —— 这正是 stale-model 审计的起因教训。
- **拿不准的标 unsure,别照旧 spec 写回。** 任何与本篇、`docs/progress.md`、`docs/stale-model-audit-2026-06-15.md` 冲突的旧设计,以最新为准。
