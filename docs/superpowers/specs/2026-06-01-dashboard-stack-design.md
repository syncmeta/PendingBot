# Dashboard 栈设计 —— 用现成工具替换自制 board

日期：2026-06-01
分支：`chore/billing-dashboard-specs`
状态：**草案,待评审**

> 关联文档:同分支的 [`2026-06-01-billing-engine-design.md`](./2026-06-01-billing-engine-design.md)。两者独立,但有交叉:计费迁到 OpenMeter 后,部分「收入 BI」由 OpenMeter 自带视图承担;本文档的 Appsmith 控制台同时是计费 spec 里 admin grant/调整的落地面。

## 目的

用经千锤百炼的现成工具,**整体替换自制 `apps/board`**(老出问题),四个域一次铺到位、不留债:

- 收入/钱包 BI + 运维 ad-hoc
- 行为分析(漏斗/留存/session replay)
- LLM 成本/可观测
- 后台管理/审核控制台(可写)

外加配套:错误追踪、基础设施指标。

## 治脆三原则

自制 board 反复坏的病根是三类自找的复杂度。对策:

1. **能直读 Postgres 就别建管道**(schema 改了顶多某张图要调,不会整站崩)。
2. **看(只读)和改(可写)彻底分家**(自制 all-in-one 最容易在这条缝上烂掉)。
3. **每块能独立替换**(松耦合,渐进升级)。

## 非目标

- **不**自托管 PostHog(自托管要 ClickHouse/Kafka,太重;用 Cloud)。
- **不**自己造基础设施监控(先用 Cloudflare 原生 + Sentry,需要更深再叠 Grafana)。
- **不**让 Metabase 写数据(即便它有 Actions;写一律走 Appsmith→edge)。
- **不**把聊天内容/敏感 PII 发进任何外部分析平台。

## 工具栈总览

| 域 | 工具 | 形态 | 成本 |
|---|---|---|---|
| 收入/钱包 BI + ad-hoc | **Metabase** | 自托管(1 容器,只读连 Supabase) | 免费 |
| 行为分析/留存/replay/灰度 | **PostHog** | Cloud(EU 区)免费档 | ~100 万事件/月免费 |
| LLM 成本/trace/eval | **Langfuse** | Cloud 免费 Hobby | 免费起 |
| 后台/审核控制台(可写) | **Appsmith** | 自托管(1 容器) | 免费 |
| 错误追踪 | **Sentry** | Cloud 免费档 | 免费起 |
| 基础设施指标 | **Cloudflare 原生** | 已有 | 免费 |

**成本原则(用户定)**:贵的自托管、便宜的用 SaaS;学生福利只当 bonus(快毕业,基线按自付价)。

## 各域设计

### 1. Metabase —— 收入/钱包 BI + ad-hoc(只读)

- **接入**:给 Supabase 开一个**只读** Postgres 角色(仅 `SELECT`,RLS-bypass 的服务视角,限本机/VPS IP),Metabase 直连。
- **覆盖**(读已落库的事实):
  - 收入:`topups` / `refund_events` / `packs`(审计记录)→ 充值流水、退款率、净收入、breakage。
  - 钱包:`subject_wallets`(若保留作缓存)/ `redemption_codes` 核销率。
  - 产品转化骨架:`users`/`subjects`/`bots`/`conversations`/`group_join_requests` → 注册→建bot→进群→付费 的**结果漏斗**(已落库部分)。
  - 运维 ad-hoc:任意 SQL。
- **告警/报表**:Metabase Alert(退款率突增、异常用量)发邮件/Slack;月报定时推送。
- **与计费 spec 的边界**:**余额事实源在 OpenMeter**(它有自带计费仪表盘);Metabase 只读 Supabase 里的支付审计 + 产品事实。两者不重叠。

### 2. PostHog —— 行为分析(第一天就上)

理由:用户对产品分析有野心、问题未定。**宽埋点先采后追问**——PostHog 能回答今天还没想到的问题(只要当时事件采到),Metabase 只能答已建模进表的。

- **三处采集缝成一条用户时间线**:
  - **iOS PostHog SDK**:交互事件(页面浏览、autocapture、onboarding 每步、充值页曝光)、session replay、feature flag。
  - **edge PostHog 服务端 SDK**:权威领域事件(见事件规范),用 user/subject id 做 `distinct_id` 缝合客户端+服务端。
  - (Metabase 不进 PostHog;领域事实的对账在 Metabase。)
- **能力**:漏斗(含"看了充值页→真的充值"这种交互+领域混合)、留存、cohort、session replay、feature flag。
- **第一天功夫**:定**事件命名规范**(见下节),autocapture 兜点击,关键转化手动埋。

### 3. Langfuse —— LLM 成本/可观测

- **接入**:在 `apps/edge/src/llm/` 的调用处包 Langfuse TS SDK 的 `generation()`(埋点,非管道),传 model、prompt、usage。
- **看**:每模型成本/p95 延迟、最费 token 的 bot/群、arena(`model_comparisons`/`ai_picks`)实际胜率、token 异常告警、eval。

### 4. Appsmith —— 后台/审核控制台(可写)

性质与上面三个不同:**写生产数据**,必须单独一套、带登录和操作审计。

- **接入**:Appsmith 自托管,连 **edge REST API**(不直连库写),所有写操作经 edge 端点/RPC,业务规则 + 审计才进得去。
- **页面(初稿)**:
  - 人工求助队列(`human_help_requests`)+ 一键处理。
  - 权限审批(`permission_requests`)。
  - **计费 admin**(对接计费 spec):`admin_grant` credit grant / ledger adjustment(>100 PNC 或 ≥10 owner 二次确认)、退款处理、refund_risk 名单。
  - 账号操作(封号/删除 `account_deletion_log`)、disposable email 名单。
  - 操作一律落 `admin_audit` / `audit_log`。

### 5. Sentry + Cloudflare 原生 —— 错误/基础设施

- **Sentry**:`@sentry/cloudflare` 挂 Worker;错误/性能;免费档。
- **基础设施**:Cloudflare 自带 Workers Analytics + dashboard;语音容器/runner 健康先用 CF 原生。需要更深再叠 Grafana Cloud 免费档(不在本期)。

## 事件规范初稿(PostHog 主线)

`distinct_id` = user_id(登录后)/ 设备匿名 id(登录前),登录时 `identify` 合并。领域事件由 **edge 服务端**发(权威),交互事件由 **iOS** 发。

| 事件 | 发自 | 关键属性 |
|---|---|---|
| `app_opened` / `$screen` | iOS | screen_name |
| `signed_up` | edge | method, subject_id |
| `onboarding_step` | iOS | step, completed |
| `bot_created` | edge | bot_id, visibility, model |
| `group_joined` | edge | group_id, via(invite/code/qr) |
| `friend_added` | edge | kind(human/bot) |
| `message_sent` | edge | conversation_kind, has_attachment |
| `paywall_viewed` | iOS | trigger, balance_bucket |
| `topup_succeeded` | edge | channel, pnc, usd |
| `voice_call_started` | edge | kind(1v1/group) |
| `crew_started` | edge | location, runner_kind |

> 隐私:**不发**消息内容、prompt、PII;金额可发但用户可识别信息脱敏;session replay 默认遮罩输入框。

## 部署

- **自托管两容器**(Metabase + Appsmith + 各自元数据 Postgres)→ **Docker Compose 跑一台 Hetzner VPS**。
- **实话:4GB 偏紧会 OOM 抖动**(JVM Metabase + Appsmith 都吃内存)→ **建议 8GB ≈ €7–8/月**(毕业后照付得起;GitHub Student Pack 的 DO/Azure 额度只当前期 bonus,不进基线)。
- PostHog / Langfuse / Sentry 全在各家免费云;Cloudflare 原生已有。

## 隐私 / 安全

- Metabase 用 **只读**角色;VPS 防火墙限源 IP;Metabase/Appsmith 后台强密码 + 2FA。
- PostHog 走 **EU 区**,不发内容/PII,replay 遮罩。
- Appsmith 写一律经 edge(鉴权 + 审计),不给它直连写库。
- 聊天/账单真身只在 Supabase / OpenMeter。

## 成本

- **月度基线 ≈ €7–8**(8GB VPS);其余免费档。
- 规模上来后最可能的第一笔:Langfuse 超 5 万 units → Core $29/月(其余长期免费)。

## 开放问题

1. Metabase 只读角色:用 Supabase 的哪种角色(自建只读 role vs service_role 限读)?需绕 RLS 但限权限。
2. PostHog iOS SDK 与现有 iOS 架构的接入点(App 启动、登录 identify 时机)。
3. Appsmith 自托管资源占用实测(确认 8GB 够 Metabase + Appsmith 同机)。
4. 事件规范评审:主线是否够、要不要加 crew/语音更细粒度。
5. 是否本期就要 Grafana(基础设施),还是先只 CF 原生 + Sentry。

## 分阶段落地 checklist

> 设计阶段,以下为待办。落地顺序按「最快见效 + 依赖」。

- [ ] **P0** VPS(Hetzner 8GB)+ Docker Compose 骨架;Supabase 只读角色。
- [ ] **P1** Metabase:收入/钱包 BI 几张图 + 转化骨架(零 app 改动,当天见效)。
- [ ] **P2** Langfuse:`apps/edge/src/llm/` 埋点。
- [ ] **P3** PostHog:定事件规范 → iOS SDK + edge 服务端事件 → 漏斗/留存(要发 app,周期最长,并行启动靠后收口)。
- [ ] **P4** Appsmith:审核控制台(求助/权限/计费 admin/账号)经 edge + 审计。
- [ ] **P5** Sentry 挂 Worker;确认 CF 原生指标够用。
