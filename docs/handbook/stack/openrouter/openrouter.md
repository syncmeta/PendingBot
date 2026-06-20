# OpenRouter(模型目录 + fallback)

OpenRouter 在大绿豆里有**两个互不相干的角色**:① 公开的**模型目录 / 元数据源**(免费 GET,无需密钥);② 推理的**fallback / 透传层**。主路径推理不走它——走 [AI Gateway 统一计费](../cloudflare/ai-gateway.md)。相关:[模型选择](../../shared/concepts/models.md) · [建 bot 与预设](../../pendingbot/features/create-bot-presets.md) · [模型盲盒](../../pendingbot/features/model-blindbox.md)。

> 这块极易被旧心智带跑(以为"OpenRouter = 主推理通道、edge 持 OR key")。务必按现状理解(见文末「注意」)。

**逻辑 — 它在系统里扮演什么**

- **模型目录(主用途)** — OpenRouter 的公开 `/api/v1/models` 是一份持续更新的全市场模型清单(id、上下文窗口、输入模态等)。edge 把它当**外部目录**薄缓存几分钟,用来:判断某模型是否支持视觉、查上下文窗口、给"建 bot 预设"动态解析旗舰 / 最新 / 最快候选。**没有 DB 里的模型目录表**,模型元数据全部源自这个上游 + 边缘缓存。
- **预设解析的数据底座** — [建 bot 预设](../../pendingbot/features/create-bot-presets.md) 的"旗舰 / 各家最新 / 最快"按这份目录实时解析:旗舰锚系列前缀取发布日最新、最快打 per-model `/endpoints` 看吞吐。盲盒抽模型也从这份清单里挑。
- **推理 fallback(次用途)** — 主路径推理经 [AI Gateway Unified Billing](../cloudflare/ai-gateway.md);OpenRouter 作为兜底 / 透传通道留着,自报精确成本时计费直接用它的数。

**为什么 — 关键取舍**

- **目录免费且全,不必自建** — 一个不需要密钥、覆盖全市场、自动更新的模型清单,自己维护一张表只会越维护越旧;直接读上游 + 短缓存最省心,符合"配置 / 元数据别硬编码"。
- **推理不绑死单一供应商** — 主路径走 AI Gateway 统一计费(统一鉴权 / 日志 / 代付),OpenRouter 留作 fallback,避免把推理命脉押在一家透传商上。
- **不为 fallback 在 edge 散落 OR 密钥** — 用户拍板:edge **不持 OpenRouter key**,目录走公开端点即可;推理计费 / 鉴权统一收口在 AI Gateway。

**用在哪·长什么样**

- 用户感知不到 OpenRouter;它表现为"建 bot 时能选到的那一排模型预设(旗舰 / 各家最新 / 最快 / 盲盒)始终是最新的市场快照"。
- 开发侧:catalog 模块薄缓存这份清单(命中失败保留旧缓存、下次重试),预设解析 + 视觉能力判断都读它。

**示例** — 你新建 bot,选"各家最新旗舰"预设。后台拿 OpenRouter 最新目录,按各产品线系列前缀解析出当下真旗舰(如 opus-latest / gpt-latest / kimi-latest),你不必知道具体 slug。等真聊天时,bot 存的是预设引用,对话时再据当时目录解析成具体模型,推理经 AI Gateway 跑。

**边界 — 明确不做什么**

- **不是主推理通道** — 主路径推理走 [AI Gateway 统一计费](../cloudflare/ai-gateway.md),不是 OpenRouter;它只是目录源 + fallback。
- **edge 不持 OpenRouter API key** — 目录是公开 GET、无需鉴权;不在 worker 里放 OR 密钥。
- **目录只用稳定公开端点** — 不依赖前端 / rankings 这类内部端点(实测多为 404 或参数无效),只用稳定版 `/api/v1/models` 和 per-model `/endpoints`。

**注意 — 坑 / 已变更的决策**

- ❌ **"OpenRouter 是主推理通道 / edge 持 OR key"** —— 错。主推理走 AI Gateway Unified Billing,edge 无 OR key,OpenRouter 只剩"目录 + fallback"两职。
- ⚠️ **稳定版 `/api/v1/models` 的 `order=` 参数无效**(前端专用),前端 / rankings 端点多 404 —— 实测证伪过文档。所以"最贵 / 最热门"不能靠目录排序参数:旗舰自己按系列前缀 + 发布日解析,最快打 per-model `/endpoints` 吞吐,最热门走外部评分代理(LMArena)。
- ⚠️ **裸子串匹配会误杀** — 解析系列前缀时按 `-./` 分段精确匹配,别用裸子串(否则 `mini` 会误命中 `minimax` 之类);新厂商 / 大版本上来要补 seed 或排除集(已记 tech-debt)。
- ⚠️ **`latest_per_vendor` 会捞到噪声**(如 `openrouter/fusion`、`nvidia content-safety:free`)——需排 `:free` / openrouter meta / `-fast` 等,各家"最新"还要落在付费档。
- ⚠️ **凭训练知识判模型失效不可信** — 曾凭印象误判 `gemma`/`gemini` 系列模型失效,curl 真目录证实全部有效;判存废一律打真目录,别凭记忆。

**现状** — ✅ 模型目录读取 + 边缘缓存 + 预设解析(旗舰 latest_in_series / 最快 endpoints / 盲盒)代码在生产路径上用;视觉能力 / 上下文窗口判断读它。🟨 fallback 推理路径随计费总开关 + AI Gateway 链路一并待真实扣费验证。证据见 [`docs/progress.md`](../../../progress.md)(2026-06-15/16 模型预设 + 目录实测纠偏行)。
