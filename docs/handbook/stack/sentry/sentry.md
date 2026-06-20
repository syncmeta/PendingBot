# Sentry(错误捕获)

Sentry = 大绿豆的**错误 / 异常追踪**:worker 端崩溃 + 吞错点、客户端崩溃 / 错误,集中上报。相关:[Dashboard 栈(PostHog / Grafana / Langfuse)](../grafana/grafana.md) · [Edge](../cloudflare/edge.md)。

**逻辑 — 它在系统里扮演什么**

- **错误集中地** — edge worker 和 iOS / Mac 客户端把崩溃 / 未捕获异常 / 关键吞错点上报 Sentry,集中看错误率、堆栈、影响面。
- **worker 端包裹 + 补吞错点** — Worker 被 `withSentry` 包裹;另外在几处"错误会被悄悄吞掉、到不了 withSentry"的地方补了显式 `captureException`:`app.onError`(Hono 把 throw 转成 500 response、原本到不了包裹层)、队列审计的非瞬时失败、cron 的 `safe()` 包装。
- **客户端最早 init** — iOS / Mac 上 Sentry 在 `Telemetry.configure()` 里**最早**初始化(为了抓启动期崩溃),用 subject_id 当 `setUser` 身份;与 PostHog / RevenueCat 同一个协调器接线,登录 setUser / 登出清空。

**为什么 — 关键取舍**

- **错误追踪要零运行时依赖** — Sentry 的开关故意**不做成可运行时切换**:错误捕获器本身必须最稳、不依赖任何会失败的远程配置;DSN 未设 = no-op,设了即生效,改要重部署。这是有意为之(可观测性底座不能自己挂)。
- **零 VPS、免费档** — 用 Sentry Cloud 免费档,不自托管,契合"观测外包"。
- **吞错点要主动补** — 框架默认只抓未捕获异常,但很多错误被 try / catch 或 framework 转成了正常 response;主动在这些缝上补 `captureException`,否则错误率失真。

**用在哪·长什么样**

- 用户感知不到 Sentry。开发 / 运维侧:在 Sentry 后台看错误聚类、堆栈、首次 / 最近出现、影响用户数,排查线上故障。

**示例** — 某个 bot 回复路径在解析上游响应时抛了未预期异常 → Hono 的 `onError` 把它转成 500 给客户端,但补的 `captureException` 同时把堆栈 + turn 上下文发给 Sentry → 你在后台看到这条错误的频率和影响面,定位修复,而不是只看到一堆没上下文的 500。

**边界 — 明确不做什么**

- **不当产品分析** — 行为 / 漏斗 / 留存归 [PostHog](../posthog/posthog.md);Sentry 只管"哪里出错了"。
- **不当 LLM 观测** — 模型成本 / 质量 / trace 归 [Langfuse](../langfuse/langfuse.md)。
- **开关不可运行时切** — 不像 billing / PostHog / Langfuse 那样能在 board 运行时翻;Sentry 一律 env + 重部署。
- **当前客户端不加手动 breadcrumb / 自定义 perf span** — 用 SDK 默认自动捕获即可(YAGNI)。

**注意 — 坑 / 已变更的决策**

- ⚠️ **开关刻意"不可运行时切"** — board 上 Sentry 那行是**只读**展示,不像其它 feature flag 能切;原因:`withSentry` 的 options 回调是同步的、且错误捕获器开关必须零运行时依赖。别试图把它做成可切。
- ⚠️ **DSN 未设 = no-op** — 没配 DSN 时整条上报静默跳过、不报错;dev / preview 不会误发数据,但也意味着"没看到错误"可能只是没配 DSN。
- ⚠️ **吞错点是反复踩出来的** — `onError` / 队列 / cron 这三处的补丁是因为"错误被悄悄吞、Sentry 收不到"才加的;新增类似的 try / catch 边界时记得想一下要不要补 `captureException`。
- ⚠️ **客户端真机投递未闭环验证** — 客户端只验了编译 + 启动不崩,错误真实到达面板的真机闭环未做(记 tech-debt)。

**现状** — 🟨 worker `withSentry` 包裹 + 三处吞错点 `captureException` 代码齐;**Sentry 生产已启用**(DSN 已设)。客户端 Sentry SDK(`Telemetry.swift`)代码就位但 key / 真机投递闭环未验。证据见 [`docs/superpowers/specs/2026-06-01-dashboard-stack-design.md`](../../../superpowers/specs/2026-06-01-dashboard-stack-design.md) §5 + [`docs/progress.md`](../../../progress.md)(block 3 Sentry 行 + 2026-06-08 feature-flags「Sentry 不可切」)。
