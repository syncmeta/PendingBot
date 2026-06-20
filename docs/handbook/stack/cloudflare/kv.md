# KV(边缘配置缓存 + prompt 下发)

Cloudflare KV = 全球最终一致的边缘键值存储。大绿豆用它做两件事:**admin 改的配置的边缘缓存**,和 **prompt 的跨 isolate 分发**。相关:[Edge](edge.md) · [Admin(board)](admin.md) · [Anthropic / prompt 通道](../anthropic/claude-code.md) · [config-as-cms 概念](../../shared/concepts/config-as-cms.md)。

**逻辑**
- **它是什么** — 一层贴在边缘的共享缓存。它**不是事实源**——真源是 Supabase 里的配置表、或 Langfuse 里的 prompt;KV 只是让"每个冷 isolate 不必各自跨区回源"。
- **配置的两源合成** — 功能开关 / 模型角色 / 模型预设这类配置,运行时按"**KV 覆盖 ?? 代码默认**"合成:代码里有一个永远能用的兜底默认(同步、不会失败),board 在 KV 里写覆盖让运营不重新部署就能改。**KV 读失败一律静默回退到代码默认,绝不抛**——一个抖动的 KV 不能拖垮配置解析。
- **三层缓存** — 典型读路径是 L1 isolate 内的 Map(秒级 TTL)→ L2 KV(跨 isolate)→ 回源(Supabase / Langfuse)。第一个冷 isolate 回源并写 KV,其余冷 isolate 从 KV 拿(个位数毫秒)。连"查无此值"也缓存(装箱区分"真 null"和"KV miss"),免得每个冷 isolate 都去捅一次源。
- **prompt 下发** — 给 LLM 的 prompt 真源是 Langfuse;KV 是把它分发到各 Worker isolate 的中转层。Langfuse 控制台改 prompt → webhook 写穿 KV;读时 miss 再从 Langfuse 拉一次回填。**没有打包进代码的兜底副本**:全空时宁可**大声失败**也不喂一个"看起来对的陈旧 prompt"。

**为什么**
- **省跨区回源** — Supabase 单点在法兰克福,US / Asia 的冷 isolate 每次回源都吃跨洋往返。KV 把"第一次回源"摊薄成全网一次。
- **board 改完即时生效、又不重部署** — 配置走 KV 覆盖,运营在 board 改、TTL 窗口内传播到边缘,不必发版(党纲红线:该可改的不写死)。
- **prompt 不内联** — 给 LLM 的文本一律走 prompt 通道(Langfuse → KV → loader),不写成代码里的 const 字符串(党纲红线);KV 是这条通道的边缘环节。

**用在哪·长什么样**
- 用户感知不到 KV;它表现为"board 改了功能开关 / 模型角色,几十秒内全网生效",以及"在 Langfuse 改了 prompt,Worker 很快用上新版"。
- 上面挂着的逻辑键大致是:功能开关、模型角色映射、模型预设、prompt 记录,还有部分记忆 / 附件缓存。

**边界**
- KV **不是事实源**,也不做强一致——要强一致 / 单写者去 [Durable Objects](durable-objects.md)。
- 不放大对象(附件字节去 [R2](r2.md))、不放 secret。
- staleness 受 TTL 约束:board 一改,**当前 TTL 窗口内**传播,不是瞬时;这是刻意的取舍。

**注意**
- **prompt 是"基础设施",不归观测开关管**:prompt 下发不被 Langfuse 的 trace 总开关 gate——keys 没配 + KV 空时,prompt 不可用、Worker **大声失败**(故意没兜底副本)。别把"关掉 Langfuse trace"误当"prompt 也跟着兜底"。
- **改 prompt 走 Langfuse,不改代码**:别在 `.ts` 里内联 prompt 字符串。
- ⚠️ 曾踩过"上线 KV 缓存失效"的坑(见 `docs/tech-debt`),改配置失效逻辑时留意。

**现状** — ✅ KV 配置缓存(功能开关 / 模型角色 / 模型预设)与 prompt 下发(Langfuse → KV → loader)均已落地并在生产读路径上使用。prompt 通道的"全空即大声失败、无打包兜底"是刻意设计。
