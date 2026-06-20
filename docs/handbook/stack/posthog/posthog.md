# PostHog(产品分析 / 事件)

PostHog = 大绿豆的**行为 / 产品分析平台**:漏斗、留存、事件流(以及未来可能的 session replay / 灰度)。"宽埋点先采后追问"——先把领域 / 交互事件采全,日后再问今天还没想到的问题。相关:[Dashboard 栈(Grafana / Sentry / Langfuse)](../grafana/grafana.md) · [责任主体计费(身份对齐)](../../shared/concepts/billing-subject.md)。

**逻辑 — 它在系统里扮演什么**

- **行为分析的事实源** — 注册 → 建 bot → 进群 → 付费 这类产品转化、留存、漏斗,以及交互事件,都进 PostHog。它回答"用户怎么用产品"——而 [Grafana / SQL](../grafana/grafana.md) 只答已建模的库内事实。
- **两路事件,一个身份缝合** — **领域 / 权威事件由 edge 服务端发**(signed_up / bot_created / group_joined / topup_succeeded / voice_call_started / crew_started 等),**交互 / 屏幕事件由 iOS SDK 发**;两路用同一个 `distinct_id` 缝合:登录后 = subject_id,登录前 = 设备匿名 id,登录时 `identify` 合并。
- **客户端三 SDK 统一接线** — iOS / Mac 的 PostHog 身份与 Sentry / RevenueCat 共用一个 `Telemetry` 协调器:登录 `identify(subject_id)` / 登出 `reset()`,标识只用 subject_id、不传 email / PII。

**为什么 — 关键取舍**

- **第一天就上,宽埋点先采** — 用户对产品分析有野心、问题未定。能采到才追得到;Grafana 只能答"已经建好的 SQL 模型",而很多产品问题是事后才想到的——所以行为侧先用 PostHog 宽采。
- **看(行为)和算(库内事实)分家** — 探索式产品分析归 PostHog,固定财务 / 钱包看板归 Grafana 直读 Postgres。各司其职,不让一个工具又当 BI 又当行为分析而烂在接缝上。
- **零 VPS、免费档** — 用 PostHog Cloud(EU 区)免费档(约百万事件 / 月),不自托管,契合"观测外包、零 VPS"。

**用在哪·长什么样**

- 用户感知不到 PostHog(它是后台分析)。运营 / 产品侧:在 PostHog 看注册→付费漏斗、留存曲线、各事件趋势。
- 事件命名有规范(领域事件由 edge 发、交互事件由 iOS 发),第一天的功夫主要花在定这套命名上。

**示例** — 一个新用户装 app(登录前事件挂设备匿名 id)→ 注册(edge 发 `signed_up`,`identify` 把匿名 id 合并到 subject_id)→ 建第一个 bot(edge 发 `bot_created`)→ 充值(edge 发 `topup_succeeded`)。这条链在 PostHog 拼成一条转化漏斗,运营能看到每步的流失率。

**边界 — 明确不做什么**

- **不发聊天内容 / prompt / PII** — 只发事件名 + 结构化属性;session replay(若开)默认遮罩输入框。隐私是硬约束。
- **不当财务 BI** — 收入 / 钱包 / 退款率这类库内事实归 [Grafana](../grafana/grafana.md) 直读 Postgres;PostHog 管行为不管账。
- **不当错误追踪** — 崩溃 / 异常归 [Sentry](../sentry/sentry.md)。
- **不在热路径阻塞** — 服务端事件 fire-and-forget;Workers 下用 `captureImmediate`(走 fetch、随请求 resolve),不依赖会被 isolate 拆掉的后台 flush。

**注意 — 坑 / 已变更的决策**

- ⚠️ **走 EU 区**(`eu.i.posthog.com`)— 隐私姿态:分析基础设施留在欧盟,与 Supabase EU 一致;别误配成美区。
- ⚠️ **无 server seam 的事件留给客户端补** — 有些事件没有 edge 服务端触发点(如 `signed_up` 经 DB 触发器、`bot_created` 客户端直写、1v1 通话结束在 DO 内、屏幕事件):这些走 iOS SDK / 后续补,**没造假塞假事件**(缺口已记 tech-debt)。
- ⚠️ **feature flag 不迁 PostHog** — 现有 `*_ENABLED` 是运维 kill-switch,故意零运行时依赖;迁 PostHog 会引入循环依赖,是反模式(评估后决定不迁)。
- ⚠️ **客户端 key 占位 / 未真机验** — 空 key = SDK no-op;事件真实投递到面板的真机闭环未做(只验了编译 + 启动不崩)。

**现状** — 🟨 edge 服务端事件 helper(`lib/track.ts` / `lib/analytics.ts`)接在 message_sent / group_created / group_joined / voice_call_* / topup_succeeded 等点,代码 + 单测齐;iOS / Mac PostHog 身份 SDK(`Telemetry.swift`)代码就位。**Sentry + PostHog 生产已启用**(EU host)。**待**:定全套事件规范 + iOS 交互事件补齐 + 真机事件投递闭环 + 漏斗 / 留存搭建。证据见 [`docs/superpowers/specs/2026-06-01-dashboard-stack-design.md`](../../../superpowers/specs/2026-06-01-dashboard-stack-design.md) §2 + [`docs/superpowers/specs/2026-06-08-client-telemetry-sdks-design.md`](../../../superpowers/specs/2026-06-08-client-telemetry-sdks-design.md) + [`docs/progress.md`](../../../progress.md)。
