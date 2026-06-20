# 党纲与准则

> 大绿豆的不可谈判信条。任何新决策与这里冲突,要么改决策、要么改这份。
> 工程的机械约定(分支模型 / commit / 迁移 / 部署 / 四账本纪律)见根 [`CLAUDE.md`](../../../CLAUDE.md),不在此重抄。

## 产品信条

- **是朋友,不是助手** — 大绿豆主动反思、主动探索,会反驳你、给你新视角,不是听话的工具。三件核心(复盘 / 校正、网上冲浪、一群 bot 议论你)都不用催、到点自己做。
- **主动性是内核** — "到点自己做"是产品的灵魂,不是功能堆砌。加任何新能力先问一句:它能不能让 bot 更像一个会主动关心你的朋友。
- **社交建立在信任上,不做开放广场** — bot 和群都是邀请制 + 留痕,不做陌生人可搜的公开身份;隐私默认收紧(头像 / 昵称只在"加好友"和"群成员"两条路径暴露)。
- **两个产品,主 + 辅** — PendingBot 是普通人的日常入口(三端 IM),PendingCrew 是开发者的 crew 编排台(可开源)。PendingBot 看见 crew、PendingCrew 深度操作 crew,互不吞功能。

## 红线

- **配置走 board / 前端,不硬编码** — 模型 slug、功能开关、运营文案这类该可改的,一律进 board / KV,不写死在代码。
- **给 LLM 的文本走 prompt 通道** — 所有 prompt 走 `prompts/<locale>/*.md` + loader / Langfuse,不内联成 const 字符串。
- **不为图省事埋雷** — 任何绕过当下约束的临时方案(关签名 / placeholder / 双写 / 只验最易过的路径)必须立刻记 tech-debt 或加 fail-loud 校验;验证要覆盖**最终使用路径**(真机),不是只验最容易过的那条。
- **已落地 = 已验证,不是"代码写完"** — `completed` / ✅ 以"验过可用"为准。
- **优先原生、优先长期体验** — 能用原生组件就不自绘;默认不推"省事最快",要最优体验。

## 商业立场

- **未发布,单环境** — v1 没发,只有一个 Supabase + 一个 prod worker;不搞 staging / 多环境基建。
- **不在中国大陆上架** — 中文只是开发语言,评估时别把中国 App Store 限制当约束。
- **关键基础设施外包,零 VPS** — 模型走 Cloudflare AI Gateway 统一计费(OpenRouter 留 fallback);计费引擎 Polar(MoR)+ RevenueCat,门禁走 WalletDO,不直连 Stripe;观测用 Grafana / PostHog / Langfuse / Sentry。
- **域名 `pendingname.com`** — 邮件 / Site URL / Universal Link 都基于它;对外品牌站在另一个仓库。

**现状** — ✅ 当前信条(随重大转向更新,变更史见 `shared/evolution/pivots`)。
