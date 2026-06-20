# RevenueCat(iOS 内购入账)

RevenueCat = iOS 端 Apple 内购(IAP)的**收据校验 + 计费回流层**:把 App 内的充值变成"给 Polar 钱包发 credit"的 webhook。相关:[Polar(钱包本体)](../polar/polar.md) · [钱包与 PNC](../../shared/concepts/wallet-pnc.md) · [责任主体计费](../../shared/concepts/billing-subject.md) · [Apple 登录 / IAP](../apple/asc-testflight.md)。

**逻辑 — 它在系统里扮演什么**

- **iOS 充值的入账中转** — iOS 上充值必须走 Apple IAP(平台强制)。RevenueCat 负责校验 Apple 收据、识别购买 / 退款,再发 webhook 给 edge;edge 据此给对应 [Polar](../polar/polar.md) Customer 钱包发 credit。**与 web / Mac 的 Polar 入账同构**——两条路最终都收敛到同一个钱包,不为 iOS 单起一个余额。
- **身份对齐用 subject_id** — iOS 端购买前先把 RevenueCat 的 `app_user_id` 设成我们的 subject_id(`logIn(subject_id)`);webhook 据此把这笔购买记到正确的钱包主体。与 edge / PostHog / Sentry 的"外部主键统一用 subject_id"一致。
- **事件即入账触发** — 充值类事件触发"加 credit",退款 / 退款撤销事件触发对应的冲销 / 重发。edge 侧做幂等(用事件 / 交易 id 去重),防重投重复加额度。

**为什么 — 关键取舍**

- **绕不开 IAP,就用 RevenueCat 收口** — Apple 强制 iOS 内购走 IAP;直接对接 App Store Server Notifications 繁琐易错,RevenueCat 把收据校验 / 退款回流 / 跨设备身份这些脏活封装好,且小规模免费。
- **它只管 iOS 这一段** — web / Mac 的收款 + 代税在 [Polar](../polar/polar.md);RevenueCat 不碰那条路。两者分工清晰:RevenueCat = iOS 入账适配器,Polar = 余额事实源。

**用在哪·长什么样**

- 用户感知到的是:iOS app 里点充值 → 弹 Apple 的内购确认 → Face ID / 密码付款 → 钱包到账。RevenueCat 本身用户看不见,它在 Apple 和我们的钱包之间转一道。
- 客户端三端共享一个 `Telemetry` 协调器统一管 RevenueCat 身份(登录 `logIn(subject_id)` / 登出 `logOut`),与 PostHog / Sentry 同一处接线。

**示例** — 你在 iOS 上买一个 PNC 充值包 → Apple 完成内购 → RevenueCat 校验收据、发"非续期购买"webhook 到 edge → edge 用 `app_user_id`(=你的 subject_id)找到你的 Polar 钱包、发等额 credit + 记影子账。你的钱包余额到账,和在 Mac 上充值结果一致。

**边界 — 明确不做什么**

- **不是余额事实源** — RevenueCat 不记 consumable 余额;余额真源在 [Polar](../polar/polar.md) + 影子账。它只是"这笔 iOS 购买发生了 / 退了"的信号源。
- **当前只接身份,不接购买流程** — 客户端 SDK 现阶段只做身份同步(identify / reset),不碰 App Store 内购产品 / offering / paywall / 购买动作——那些随 IAP 正式上线另做。
- **投递非 exactly-once** — webhook 可能漏 / 延迟(尤其 consumable 退款),所以必须配 reconciliation 兜底对账,不能假定每个事件都准时到一次。

**注意 — 坑 / 已变更的决策**

- ⚠️ **webhook 鉴权只有共享密钥头,没有签名** — RevenueCat 用 `Authorization` 共享密钥(非 HMAC 签名);edge 用常量时间比对,密钥进 worker secret。别按"验签"思路实现。
- ⚠️ **身份要在购买前 logIn** — 购买前若没先 `logIn(subject_id)`,这笔购买可能挂到匿名 / 旧 id;webhook 侧要用 `original_app_user_id` / aliases 兜一层。
- ⚠️ **占位 key,账号未开通** — 客户端 `revenueCatKey` 当前是空串占位(RevenueCat 账号未开),空 key = SDK 整段 no-op、不崩。待账号开通 + 真上 IAP 才填真值。
- ⚠️ **退款链路可能延迟** — consumable 退款投递可能晚到 / 漏;必须靠对账兜底,别只信 webhook。

**现状** — 🟨 edge 侧 RevenueCat 入账 webhook(`POST /v1/billing/revenuecat/webhook`)代码 + 单测齐;客户端身份 SDK(`Telemetry.swift` 三端共享,登录 logIn / 登出 logOut)代码就位。**但 RevenueCat 账号未开通、key 占位空串、IAP 产品未配**,真机充值闭环完全未验。证据见 [`docs/superpowers/specs/2026-06-01-billing-engine-design.md`](../../../superpowers/specs/2026-06-01-billing-engine-design.md) §iOS 入账 + [`docs/superpowers/specs/2026-06-08-client-telemetry-sdks-design.md`](../../../superpowers/specs/2026-06-08-client-telemetry-sdks-design.md)「待办尾巴」。
