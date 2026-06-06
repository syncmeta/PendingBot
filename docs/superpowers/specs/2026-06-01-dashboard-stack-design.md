# Dashboard 栈设计 —— 用现成工具替换自制 board（零 VPS 版）

日期：2026-06-01（2026-06-02 重审 BI/admin → **去掉 VPS**）
分支：`chore/billing-dashboard-specs`
状态：**草案,待评审**

> 关联:同分支 [`2026-06-01-billing-engine-design.md`](./2026-06-01-billing-engine-design.md)。交叉点:计费迁到 **Polar** 后,余额事实源在 Polar(它有自带计费视图);本文档的 **Refine 控制台**同时是计费 spec 里 admin grant/调整的落地面。
>
> **2026-06-02 重审结论**:原方案的 Metabase + Appsmith 都需要自托管 VPS,与"少运维/别老坏"相悖。重审后**两个都换掉,整台 VPS 不要了**:BI 用 **Grafana Cloud Free 直连 Supabase**,控制台用 **Refine 部署到 CF Pages**。全栈变成"托管免费 + 已有 CF"。

## 目的

用经千锤百炼的现成工具,**整体替换自制 `apps/board`**(老出问题),四域一次铺到位、不留债,且**不新增任何需要常驻看护的服务器**:

- 收入/钱包 BI + 运维 ad-hoc
- 行为分析(漏斗/留存/session replay)
- LLM 成本/可观测
- 后台管理/审核控制台(可写)
- 配套:错误追踪、基础设施指标

## 治脆三原则

自制 board 反复坏的病根是三类自找的复杂度。对策:

1. **能直读 Postgres 就别建管道**(schema 改了顶多某图要调,不会整站崩)。
2. **看(只读)和改(可写)彻底分家**(自制 all-in-one 最容易在这条缝上烂掉)。
3. **每块能独立替换 + 尽量零运维**(托管/静态优先,不养服务器)。

## 非目标

- **不**自托管任何 dashboard 组件(BI 用托管云、控制台用静态站)→ **不要 VPS**。
- **不**让 BI 写数据(Grafana 只读;写一律走 Refine→edge)。
- **不**把聊天内容/敏感 PII 发进任何外部分析平台。

## 工具栈总览（零 VPS）

| 域 | 工具 | 形态 | 成本 |
|---|---|---|---|
| 收入/钱包 BI(固定看板) | **Grafana Cloud Free** | 纯托管,直连 Supabase(`bi_ro` 只读角色) | 免费 |
| ad-hoc SQL 探索 | **Supabase Studio**(SQL editor + saved snippets) | 已含在 Supabase | 免费 |
| 行为分析/留存/replay/灰度 | **PostHog** | Cloud(EU 区)免费档 | ~100 万事件/月免费 |
| LLM 成本/trace/eval | **Langfuse** | Cloud 免费 Hobby | 免费起 |
| 后台/审核控制台(可写) | **Refine / react-admin** | **CF Pages 静态部署(零服务器)** | 免费(用已有 CF) |
| 错误追踪 | **Sentry** | Cloud 免费档 | 免费起 |
| 基础设施指标 | **Cloudflare 原生** | 已有 | 免费 |

**月度基线 ≈ $0**(全免费档 + 已有 CF);无 VPS。规模上来后最可能第一笔是 Langfuse 超量(Core $29/月)。

## 各域设计

### 1. Grafana Cloud Free + Supabase Studio —— 收入/钱包 BI + ad-hoc(只读)
- **接入**:Grafana Cloud(免费档)加一个 **PostgreSQL datasource** 指向 Supabase,用**只读角色 `bi_ro`**(迁移 `20260602051354_metabase_readonly_role.sql` 已建,仅 `SELECT`,无写;上线时设其密码 + 把 Grafana Cloud 出口 IP 加进 Supabase 网络允许,或用 Grafana **PDC**)。
  > 角色名 `bi_ro`(由历史 `bi_ro` 于 2026-06-04 正名),给 Grafana 用,功能不变。
- **覆盖**(读已落库事实,SQL 面板):
  - 收入:Polar 的支付审计 + edge 影子账 `pnc_ledger`(充值/退款流水、净收入、退款率)。
  - 钱包/配额:`pnc_ledger` 余额聚合、负余额/overdraft 名单。
  - 产品转化骨架:`users`/`subjects`/`bots`/`conversations`/`group_join_requests` → 注册→建bot→进群→付费 结果漏斗(SQL 拼)。
- **告警**:Grafana 告警(退款率突增等)发邮件/Slack。
- **ad-hoc**:Supabase Studio 的 SQL editor + saved snippets 写探索查询(零额外搭建)。
- **取舍说明**:Grafana 强在"写好 SQL 的固定看板",弱在"随手拖拽下钻"。但**探索式产品分析归 PostHog**(行为),Metabase 那种点选 ad-hoc 在这里非刚需;真有需要再上 Preset Free(Superset 云,零运维)或 Metabase(要 VPS/$100mo)。

### 2. PostHog —— 行为分析(第一天就上)
理由:用户对产品分析有野心、问题未定。**宽埋点先采后追问**——PostHog 能回答今天还没想到的问题(只要当时采到);Grafana/SQL 只能答已建模的。
- iOS PostHog SDK(交互事件/replay/flag)+ edge 服务端权威领域事件,同 `distinct_id` 缝合。第一天功夫 = 定事件命名规范(见下)。

### 3. Langfuse —— LLM 成本/可观测
- 在 `apps/edge/src/llm/` 埋点(gated helper `lib/llm-trace.ts` 已就绪,key 未设=no-op,待接调用点)。看每模型成本/延迟、最费 token 的 bot、arena 胜率、token 异常。

### 4. Refine / react-admin（CF Pages）—— 后台/审核控制台(可写)
性质与上面不同:**写生产数据**,必须单独一套、带登录和审计。
- **形态**:Refine(或 react-admin)构建的 SPA,**部署到 Cloudflare Pages,零常驻服务器**;跑在已有 CF 基建上。
- **接入**:自定义 **dataProvider 指向 edge REST API**(**不**用 `ra-data-postgrest` 直连库——那会绕过 edge);所有写经 edge 端点/RPC,业务规则 + 审计才进得去。鉴权 `authProvider` 接 Supabase Auth / edge session。
- **页面(初稿)**:人工求助队列(`human_help_requests`)、权限审批(`permission_requests`)、**计费 admin**(给 Polar 钱包发/减 credit + `pnc_ledger` 调整,>100 PNC/≥10 owner 二次确认)、账号操作。操作落 `admin_audit`/`audit_log`。
- **起步兜底**:正式控制台搭好前,用 **Supabase Studio** 改单条数据应急(但它无审批流/无 edge 审计,只当临时手术刀)。

### 5. Sentry + Cloudflare 原生 —— 错误/基础设施
- Sentry:`@sentry/cloudflare` 已包裹 Worker(DSN 未设=no-op,已就绪),设 DSN 即生效。
- 基建:Cloudflare 自带 Workers Analytics;需要更深再叠 Grafana Cloud(同一个账号,把 CF 指标也接进来)。

## 事件规范初稿(PostHog 主线)
`distinct_id` = user_id(登录后)/ 设备匿名 id(登录前),登录 `identify` 合并。领域事件由 edge 发,交互事件由 iOS 发。

| 事件 | 发自 | 关键属性 |
|---|---|---|
| `app_opened` / `$screen` | iOS | screen_name |
| `signed_up` | edge | method, subject_id |
| `onboarding_step` | iOS | step, completed |
| `bot_created` | edge | bot_id, visibility, model |
| `group_joined` | edge | group_id, via(invite/code/qr) |
| `paywall_viewed` | iOS | trigger, balance_bucket |
| `topup_succeeded` | edge | channel, pnc, usd |
| `voice_call_started` | edge | kind(1v1/group) |
| `crew_started` | edge | location, runner_kind |

> 隐私:**不发**消息内容/prompt/PII;session replay 默认遮罩输入框;PostHog 走 EU。

## 部署（零 VPS）
- **BI**:Grafana Cloud（注册免费档）+ datasource 指 Supabase（`bi_ro`）。
- **控制台**:Refine SPA → `wrangler pages deploy`（CF Pages）。
- **PostHog / Langfuse / Sentry**：各家免费云。
- **无 VPS、无 Docker Compose 常驻。**
  > `infra/dashboards/docker-compose.yml`（Metabase+Appsmith）+ `docs/dashboards-setup.md` **降级为可选 fallback**:仅当将来确实要"点选式自助 BI"且愿意养 VPS 时才用;主路径不走它。

## 隐私 / 安全
- Grafana 用 **只读** `bi_ro` 角色;Supabase 网络限源(Grafana Cloud 出口 IP / PDC)。
- PostHog 走 EU,不发内容/PII,replay 遮罩。
- Refine 控制台写一律经 edge(鉴权 + 审计);后台登录 2FA。
- 聊天/账单真身只在 Supabase / Polar。

## 成本
- **$0 基线**(全免费档 + 已有 CF);规模上来第一笔 ≈ Langfuse Core $29/月。

## 开放问题
1. `bi_ro` 角色密码 + Grafana Cloud 连接方式(出口 IP allowlist vs PDC)。
2. PostHog iOS SDK 接入点(App 启动、登录 identify 时机)。
3. Refine vs react-admin 二选一(都可;react-admin 自定义 dataProvider 文档更全)。
4. 事件规范评审:主线是否够。
5. 将来若要点选式自助 BI:Preset Free(零运维)vs Metabase(VPS/$100mo)——留到有需要再定。

## 分阶段落地 checklist
> 设计阶段,待办。
- [ ] **P0** Grafana Cloud 账号 + 设 `bi_ro` 密码 + datasource 连 Supabase;Supabase Studio 存几条 ad-hoc snippet。
- [ ] **P1** Grafana:收入/退款/钱包/转化骨架几张图(零 app 改动)。
- [ ] **P2** Sentry 设 DSN(代码已就绪)。
- [ ] **P3** Langfuse:接 `lib/llm-trace.ts` 到 `apps/edge/src/llm/` 调用点(随计费 P2 一起,避免重复动 llm 路径)。
- [ ] **P4** PostHog:定事件规范 → iOS SDK + edge 服务端事件(接 `lib/analytics.ts`)→ 漏斗/留存。
- [ ] **P5** Refine 控制台 → CF Pages:求助/权限/计费 admin/账号,经 edge + 审计。
