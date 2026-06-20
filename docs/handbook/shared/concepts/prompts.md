# Prompt 与世界观

所有给 LLM 看的文本——主 system prompt、语音指令、来信指令、群聊调度、bot 的社交常识、crew session 的世界观——**一律走 prompt 通道,不内联成代码里的常量字符串**。相关:[配置即 CMS](config-as-cms.md) · [工具系统](bot-tools-and-scopes.md) · [session 与世界观](../../pendingcrew/concepts/session-and-world-model.md)。

**逻辑**

- **Langfuse 是 prompt 正文的唯一真相** — 每条 prompt 在 Langfuse 里有一个版本(键 `<name>/<locale>`,production 标签)。代码里**没有兜底副本**:一条 prompt 拿不到时,worker 的 LLM 路径**直接报错(fail loud)**,而不是退回一份可能过时的内置文本——"一份貌似对其实陈旧的 prompt"比"响亮地失败"更危险。
- **三层分发,热路径同步读** — 编辑在 Langfuse 控制台改 → 版本 webhook 把新正文推到边缘 KV → worker 各 isolate 内存缓存(短 TTL)。LLM 路径每次 turn 先 await 一次"确保 prompt 已载入",之后的取用是**同步**的(读内存)。冷启动 / webhook 漏推时,会按需从 KV(再不行从 Langfuse)拉一次补进来。
- **prompt 有清单** — 系统认得的 prompt 是一份固定清单(主 system / voice / group-voice / 来信几段 / title / group-router / bot 社交图谱 / session 世界观 / lookback / 识图 / 群机器人自我介绍 / 输出模式…)。加一条新 prompt = 往清单加个名字,再在 Langfuse 建对应版本。
- **世界观 / 技能注入** — 有些 prompt 是**永远注入**的固有常识:例如"bot 社交图谱"段(向 bot 解释它对自己社交圈、好友可见性、`ask_friend`/`delegate` 工具语义的固有认知)。crew 的 session 世界观则在每个 session 启动时由 edge **渲染填值后注入**(身份 / 输入输出 / 群聊定位 / captain / 拍板方 / 读白板 / 权限模式)。用户自建的 skill 正文也走注入(订阅后系统 prompt 带上),逻辑同源——都是把该热改的文本从代码里抽出来、在组装时拼进去。
- **locale 变体** — 中文(默认)永远每条都有;个别 prompt 有别的语言变体(如 session 世界观有英文版),取不到该语言时回落到中文版。

**为什么**

- **党纲红线** — "给 LLM 的文本走 prompt 通道,不内联成 const 字符串"是不可谈判的红线。prompt 是产品的"性格"和"规矩",要能不发版就调;内联进 `.ts` 等于把运营文案焊死在代码里。
- **fail loud 而非兜底** — prompt 被当作基础设施:keys 没配 + KV 空 → prompt 不可用 → worker 响亮失败。这是刻意的:藏一份内置副本会让"线上其实在用半年前的旧 prompt"这种事悄无声息地发生。
- **board / KV 可热更** — 配合工具说明(走注册表)和模型角色(走 KV),整个"模型读到的东西"都做成可热调:prompt 正文在 Langfuse、工具说明在注册表、用哪个模型在 model-roles,三条通道各归其位,运营改完数秒到分钟级生效。

**用在哪·长什么样**

- **运营侧**:在 Langfuse 控制台编辑 prompt(production 标签),保存即经 webhook 推到线上。board 侧有一份 prompt 名字 + 说明的清单(知道每个名字管什么),正文编辑在 Langfuse。
- **用户侧**:用户感知不到 prompt 这一层;他们感知到的是 bot 的语气、会不会主动复盘、群里抢不抢话——这些都由对应 prompt 决定。

**示例** — 你觉得群聊里 bot 太爱抢话。你在 Langfuse 改 `group-voice` 这条 prompt(加一句"轮到你再说,别打断"),存到 production。版本 webhook 把新正文推到边缘 KV,各 worker isolate 在下一个 TTL 窗口或下一通群语音里读到新版本——没发版,群里 bot 的行为就变了。

**边界**

- **不藏兜底副本** — 故意不在代码里留 prompt 的 fallback 文本;拿不到就报错。这意味着 Langfuse / KV 这条链是 prompt 的硬依赖,不是可选增强。
- **prompt 正文不进手册** — 手册讲"prompt 怎么走、谁是真相",不抄具体 prompt 文本(那在 Langfuse / 仓库 `prompts/` 下)。
- **trace 开关与 prompt 取用解耦** — Langfuse 的 trace 上报有独立开关(可关),但 prompt 的取用**不受该开关影响**——prompt 是基础设施,trace 是观测。

**注意**

- 历史上有一批 prompt 内联在 `.ts` 里(const 字符串),已陆续迁到 prompt-loader + Langfuse。审计还点出过个别漏迁的(如 lookback 指令一度内联),修迁后才算齐——遇到代码里残留的内联 prompt,是债不是范例,别照抄。
- 旧的"crew captain 整套编排注入"在 bot-reply 里是**已废残留**(edge-bot 当 captain 的旧心智),已退役;session 世界观注入是活路径,别混。

**现状** — ✅ **prompt-loader + Langfuse + KV webhook 分发已落地**(main),fail-loud 无兜底副本,session 世界观注入活路径在跑。🟨 **尾巴**:个别历史内联 prompt 迁 Langfuse 后,"getPrompt 真去 Langfuse 拉到"的端到端真验要等真消息 / 通话触发;更新后的 prompt 重新 seed 到 Langfuse 是运营动作。
