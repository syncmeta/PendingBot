# Grafana(财务 / 观测看板)

Grafana Cloud = 大绿豆的**只读 BI 看板**:营收 / 钱包 / 群池 / 成本 / 转化,直连 Supabase 用专设的只读角色 `bi_ro`。相关:[Supabase](../supabase/supabase.md) · [PostHog(行为分析)](../posthog/posthog.md) · [config-as-cms / board(写一律走 edge)](../../shared/concepts/config-as-cms.md) · [钱包与 PNC](../../shared/concepts/wallet-pnc.md)。

> 这是"自制 board 反复坏 → 改用现成工具 + 零 VPS"的落点,且 BI 方案从 Metabase 换成了 Grafana,务必按现状理解(见文末「注意」)。

**逻辑 — 它在系统里扮演什么**

- **固定财务 / 钱包看板** — 把已落库的事实(营收 / 退款率、钱包余额聚合、负余额名单、群池不变量、按类成本、注册→付费转化骨架)用 SQL 面板画出来。Grafana 强在"写好 SQL 的固定看板"。
- **直读 Postgres,不建管道** — Grafana Cloud 加一个 PostgreSQL datasource 直指 Supabase,用**只读角色 `bi_ro`**(仅 `SELECT`、无写)。schema 改了顶多某张图要调,不会整站崩——这是治"自制 board 反复坏"的核心思路:能直读库就别建管道。
- **告警** — 退款率突增之类用 Grafana 告警发邮件 / Slack。

**为什么 — 关键取舍**

- **看(只读)和改(可写)彻底分家** — 自制 all-in-one board 最容易在"既读又写"这条缝上烂掉。BI(Grafana)只读、写一律走 [board → edge](../../shared/concepts/config-as-cms.md)。这条分界是治脆三原则之一。
- **零 VPS** — 原方案的 Metabase 要自托管 VPS(JVM 吃内存、要看护),与"少运维、别老坏"相悖;改成 Grafana Cloud Free 纯托管直连 Supabase,整台 VPS 不要了。
- **探索归 PostHog / Supabase Studio** — Grafana 弱在"随手拖拽下钻";但探索式产品分析归 [PostHog](../posthog/posthog.md)(行为)、ad-hoc SQL 归 Supabase Studio(SQL editor + saved snippet),点选式自助 BI 在这里非刚需,真要再上(留作开放项)。

**用在哪·长什么样**

- 用户感知不到 Grafana。运营 / 财务侧:在 Grafana 看营收 / 退款 / 钱包 / 群池 / 成本 / 转化几张固定看板,配告警盯异常。
- 数据基座:看板 SQL 基于真实库表(营收读 Polar 支付审计 + edge 影子账,钱包 / 群池读自研簿记)。

**示例** — 运营每天打开 Grafana 的"营收"看板:净收入、退款率、当日充值笔数一目了然;退款率超阈值时 Grafana 告警发到 Slack。要临时查一条具体记录,转去 Supabase Studio 写 ad-hoc SQL,不动 Grafana 的固定看板。

**边界 — 明确不做什么**

- **绝不写库** — Grafana 用只读 `bi_ro`,连不上写;所有写经 [board → edge](../../shared/concepts/config-as-cms.md)(带鉴权 + 审计)。保持这条纪律,别给 BI 开写权限。
- **不发聊天内容 / 敏感 PII** — 看板只聚合财务 / 计量事实;聊天真身留在 Supabase。
- **不当行为分析** — 漏斗 / 留存 / replay 归 [PostHog](../posthog/posthog.md);Grafana 管库内已建模事实。
- **不当后台控制台** — 人工求助 / 权限审批 / 计费 admin 这类**写**操作归独立的 Refine / react-admin 控制台(部署 CF Pages、写经 edge),不在 Grafana 里做。

**注意 — 坑 / 已变更的决策**

- ❌ **Metabase + Appsmith on VPS** —— 已换掉:BI 改 Grafana Cloud、控制台改 Refine on CF Pages,整台 VPS 不要了。旧自托管 runbook(`docs/dashboards-setup.md`)**降级为可选 fallback**,仅当将来确实要点选式自助 BI 且愿养 VPS 才用;主路径不走它。
- ⚠️ **`bi_ro` 是正名后的角色名** — 由历史角色名于 2026-06-04 正名为 `bi_ro`(给 Grafana 用,功能不变、仅 SELECT);datasource 连接用户名形如 `bi_ro.<project-ref>`。别用旧名。
- ⚠️ **RLS 在直读时不自动护** — Grafana 直连库时绕过应用层;为不放松 RLS policy,部分看板走专设的 security-definer 聚合视图取数。
- ⚠️ **spec 里的表名可能与实表不符** — 落地时发现 spec 写的 `pnc_ledger` 不存在、实表是 `billing_ledger`;SQL 以真实列为准,别照 spec 表名抄。
- ⚠️ **连接需放行 Grafana Cloud 出口 IP**(或用 Grafana PDC)+ 设 `bi_ro` 密码(out-of-band,不进迁移)——上线前必做。

**现状** — 🟨 5 张 provisioning 看板(营收 / 钱包配额 / 群池 / 按类成本 / 转化漏斗,`infra/grafana/dashboards/*.json`)SQL 全部基于真实列、JSON 合法;`bi_ro` 只读角色迁移已建 + 已 apply(EU)。**待用户**:开 Grafana Cloud 账号、设 `bi_ro` 密码、连 datasource 到 Supabase(出口 IP / PDC),看板端到端出图未验。证据见 [`docs/superpowers/specs/2026-06-01-dashboard-stack-design.md`](../../../superpowers/specs/2026-06-01-dashboard-stack-design.md) §1 + [`docs/dashboards-setup.md`](../../../dashboards-setup.md)(已降级的 fallback runbook)+ [`docs/progress.md`](../../../progress.md)(Grafana 解卡行)。
