# Google(OAuth 登录身份提供方)

Google = 大绿豆登录的**一条第三方身份路径**:用户用 Google 账号登录,经原生 Google Sign-In 拿 id token、交给 [Supabase](../supabase/supabase.md) Auth 换 session。本篇讲 Google 作为外部服务 / 配置依赖的角色;登录路径的产品形态(几条路、各长什么样)在 [登录](../apple/sign-in.md),不在此重抄。相关:[Supabase(身份源)](../supabase/supabase.md) · [Apple(平台 / 登录)](../apple/sign-in.md)。

**逻辑 — 它在系统里扮演什么**

- **一个外部 IdP,身份最终落 Supabase** — Google 只负责"证明你是这个 Google 账号的人":客户端跑原生 Google Sign-In sheet 拿到 id token → 交给 Supabase Auth(`signInWithIdToken`)→ Supabase 产出正常 session。账号身份事实源仍是 Supabase,Google 是它的一个上游 IdP。
- **配置依赖在 Google Cloud Console** — 用 Google 登录需要在 Google Cloud Console 建一个 **OAuth 2.0 Client ID**;客户端读它(`GIDClientID`)发起登录。这是 Google 在系统里的主要"配置面"。
- **三种登录路之一,平等并列** — 在 PendingBot 登录壳里,Google 和 Apple / 邮箱 OTP / 扫码并列;留 Google 是为覆盖面与触达,不把退路全交给单一提供方。

**为什么 — 关键取舍**

- **多条登录路、不押单一提供方** — 评估过"纯 OAuth"(能省 SMTP / 收件箱 / email 滥用),最终决定 email OTP + Apple + Google 三种并存:不把退路交第三方、保留 email 触达、扩大覆盖面。Google 是这套"多路并存"里的一条。
- **身份不外包给 Google** — Google 只做"这一次登录的身份证明",session / 账号体系 / RLS 全在 Supabase;换 IdP 不动账号根基。

**用在哪·长什么样**

- 用户感知到的是登录壳里的"用 Google 登录"胶囊:点它弹原生 Google 账号选择 sheet,选完即登录。背后的 id token 交换用户看不见。
- 同一套登录状态机驱动 iOS 与 Mac(逻辑共享、平台各用原生控件)。

**示例** — 你在 PendingBot 登录页点"用 Google 登录" → 弹 Google 账号 sheet、选账号 → 客户端拿到 Google id token → 交给 Supabase 换成 session → 进入 app。你的账号身份记在 Supabase,不是 Google。

**边界 — 明确不做什么**

- **不做第三方 IdP 联邦 / 不靠 Google 当账号体系** — Google 只产 id token 供一次登录;账号 / session / 可见性都在 Supabase。同发布者 SSO 用 OS keychain 共享组(见 [设备授权](../../shared/concepts/device-grant.md)),不引第三方身份联邦。
- **本篇不讲登录流程全貌** — 几条登录路径、PendingCrew 的"一次性 session → scoped grant"特殊路等产品形态在 [登录](../apple/sign-in.md);这里只锚 Google 这一外部依赖的角色 + 配置 + 坑。

**注意 — 坑 / 易错点**

- ⚠️ **`GIDClientID` 必须填正向 client id,不能填反转** — 正确是 `<digits>-<token>.apps.googleusercontent.com`(正向);反转形 `com.googleusercontent.apps.<…>` 只能放进 URL scheme(`CFBundleURLTypes`),填到 `GIDClientID` 会**静默不启动**登录。这俩长得像、极易填反。
- ⚠️ **现有 client id 是 iOS 型,Mac 上可能 `invalid_client`** — Google 登录在 Mac 上还依赖一个 **macOS 型 OAuth client** 配置;现有 `GIDClientID` 是 iOS 型,Mac 启用前必须在 Cloud Console 建对应 Mac client 并坐实,否则 Mac 上的 Google sign-in 会 invalid_client(已记 tech-debt,Mac 真实 Google 登录回合尚未跑)。
- ⚠️ **PendingCrew 的 Google 路径还差后台配置** — `com.pendingname.pendingcrew` 的 iOS OAuth client id 尚未在 Cloud Console 建好 / 填进工程,在此之前 PendingCrew 的 Google 登录会抛错;PendingCrew 当前可用路径是邮箱 OTP + 扫码 + 同发布者确认卡(见 [登录](../apple/sign-in.md) 注意)。
- ⚠️ **签名问题会伪装成登录失败** — 模拟器 / ad-hoc 签名下会话存不住、写降级 anon,报"像后端权限"的错;验 Google 登录态要用真签名的 Xcode GUI 构建(详见 [登录](../apple/sign-in.md) 注意)。

**现状** — 🟨 iOS Google Sign-In → Supabase 换 session 的客户端代码已落、iOS OAuth client id 已配(Info.plist + `GIDClientID`)。**待**:Mac 端 macOS 型 OAuth client 配置 + Mac 真实 Google 登录回合;PendingCrew 的 Google client id 未配。证据见 `apps/pendingbot/Sources/Networking/GoogleSignIn.swift` + [`docs/progress.md`](../../../progress.md)(2026-06-06 登录决策行 + Mac 钱包 session Google client 尾巴)+ [登录](../apple/sign-in.md) 现状行。
