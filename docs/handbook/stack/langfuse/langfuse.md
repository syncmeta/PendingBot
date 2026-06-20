# Langfuse(Prompt 管理 + LLM 观测)

Langfuse 在大绿豆里身兼**两职**:① **Prompt 的唯一真源**(管理 + 版本 + production label),改完即生效;② **LLM trace / score**(每回合成本 / 延迟 / 模型 / 评分)。相关:[Prompt 与世界观](../../shared/concepts/prompts.md) · [AI Gateway](../cloudflare/ai-gateway.md) · [KV 配置分发](../cloudflare/kv.md) · [模型盲盒](../../pendingbot/features/model-blindbox.md)。

> Prompt 真源经历过一次"bundled `.md` → Langfuse"的迁移,务必按现状理解(见文末「注意」)。

**逻辑 — 它在系统里扮演什么**

- **Prompt 真源(管理面)** — 所有给 LLM 看的 prompt(世界观 / 各角色指令)在 Langfuse 里编辑 + 版本化,打 `production` label 的版本是 worker 实际 serve 的那一份。运营改 prompt 不必发版即生效。
- **改完即生效靠 webhook 写 KV** — Langfuse 在 prompt 版本变化时 POST 一个 **HMAC-SHA256 签名**的 webhook 到 edge;edge 验签后把"production 标签 + text 类型"的版本镜像进 [KV](../cloudflare/kv.md)。读路径从 KV 取(L1 内存 → KV → miss 时回 Langfuse 拉并回写),所以改 prompt 不用重部署。
- **LLM 观测(观测面)** — 每个聊天回合的 model / tokens / cost / latency,以及完整 input / output 本文,作为 trace 发到 Langfuse;需要时可给某次调用附一个质量评估 `score`。用来看每模型成本、最费 token 的 bot、token 异常。(注:早期"盲盒 arena 投票喂 score"的数据流已随 arena 退役,见 [pivots §5](../../shared/evolution/pivots.md)。)
- **两职用同一个 client,但开关解耦** — prompt 读取与 trace 上报共享一个 Langfuse client 单例,但**prompt 读取不受 trace 开关 gate**:`LANGFUSE_ENABLED` 只控制 trace 上报,prompt 分发始终在线。

**为什么 — 关键取舍**

- **Prompt 该可改、不硬编码** — 党纲红线:给 LLM 的文本走 prompt 通道,不内联成 const 字符串。Langfuse 既当编辑面又当版本库,配 webhook→KV 实现"改完即生效",比"改代码 + 重部署"顺滑得多。
- **第一方观测,发完整本文** — Langfuse 是自家观测平台(不是把数据交给广告类第三方),所以 trace 发**完整 prompt / completion 本文**(早先"只发结构指标"的隐私口径已反转)——要的是全功能可观测,不是半成品指标。
- **零 VPS、免费起步** — 用 Langfuse Cloud 免费档,不自托管;规模上来最可能第一笔超量费就在这(Core $29/月),仍远低于养引擎 / VPS。

**用在哪·长什么样**

- 用户完全感知不到 Langfuse。它表现为"bot 的人设 / 世界观 prompt 能被运营在后台改、且不用发版就生效",以及内部可观测每次模型调用的成本 / 质量。
- 开发 / 运营侧:在 Langfuse 后台编辑 prompt + 打 production label;在 trace / score 视图看 LLM 成本与质量。

**示例** — 运营在 Langfuse 改了"世界观"prompt、把新版本打上 production → Langfuse 发签名 webhook 到 edge → edge 验签、把新版本写进 KV → 下一次 bot 回复就用上新 prompt,全程没重部署。这次回复的 model / tokens / cost / 完整 input·output 又作为一条 trace 回到 Langfuse,可在后台核对成本与质量。

**边界 — 明确不做什么**

- **不是 prompt 的兜底层** — 现状是 Langfuse = 唯一真源,bundled `.md` 已删;读路径全空就 **fail-loud 抛错**,不再 serve 陈旧本地副本(pre-launch 可激进,"空了就空了")。
- **不在热路径同步阻塞** — trace 上报是 off-path / 批量 flush,不卡模型响应;Workers 下用 `flushAsync` 兜批量发送(否则 isolate 拆了批次丢)。
- **trace 开关默认关** — `LANGFUSE_ENABLED` 现网默认 false(只 gate 上报),真实 trace 到面板待开启后验。

**注意 — 坑 / 已变更的决策**

- ❌ **bundled `.md` 当 prompt 真源 / 当兜底** —— 已弃:16 个 `.md` 一次性 seed 进 Langfuse 后,删掉了本地 `.md` + 兜底逻辑,Langfuse 成唯一真源。
- ❌ **prompt override 走 `i18n_prompts` 表** —— 已 DROP,override 源切到 Langfuse Prompt Management(`<name>/<locale>` + production label)。
- ❌ **trace"只发结构指标不发本文"** —— 已反转:发完整 prompt / completion 本文(第一方观测,要全功能)。
- ⚠️ **webhook 验签别搞错签名串** — HMAC-SHA256 over `${timestamp}.${rawBody}`,头 `x-langfuse-signature: t=<unix>,s=<hex>`,常量时间比对;密钥 `LANGFUSE_WEBHOOK_SECRET` 进 worker secret + Langfuse 后台配。
- ⚠️ **label 移动会发两个事件**(失去 production / 获得 production);只对"获得 production 的 text 版本"动作,避免回退到旧版本。
- ⚠️ **prompt 改完要重新 seed** — 涉及更新 prompt 后需把新内容重新 seed 到 Langfuse,否则线上读到的是旧版本(已有遗留尾巴提醒)。

**现状** — 🟨 Prompt loader 换源 KV 分发 + fail-loud、HMAC webhook→KV、trace / score helper(`lib/llm-trace.ts` / `langfuse-client.ts`)代码 + 单测齐;16 个 prompt 已 seed 进 Langfuse production。**待**:配 `LANGFUSE_WEBHOOK_SECRET`(worker secret + 后台 webhook 指向)、翻 `LANGFUSE_ENABLED=true` 开 trace 上报、真实一轮 trace 到面板核验。证据见 [`docs/superpowers/specs/2026-06-01-dashboard-stack-design.md`](../../../superpowers/specs/2026-06-01-dashboard-stack-design.md) §3 + [`docs/progress.md`](../../../progress.md)(2026-06-06 prompt 切 Langfuse + KV 行)。
