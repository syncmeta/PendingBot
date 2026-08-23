# Mac 端「用 Apple 登录」走网页 OAuth — 落地前的官方文档结论

> 调研日期 **2026-08-23**。动因：Developer ID 直发的 macOS 包拿不到
> `com.apple.developer.applesignin` 授权（见 `docs/tech-debt.md` / 2026-08-21 实测），
> 原生 `ASAuthorizationController` 那条路在 Mac 直发包上不可用，需要一条不依赖该授权的网页 OAuth 路径。
>
> **核心风险**：Apple 的用户标识 `sub` 如果在「原生 App ID」和「网页 Services ID」两条路上不一致，
> 同一个人在 iPhone 和 Mac 上会变成两个账号，且**不报错**。本文把这条钉死后才允许写代码。

---

## 1. Services ID 必须分组到现有 App ID 之下（不是可选项）

创建 Services ID 时，Apple 后台的 Sign in with Apple → Configure 弹窗里那一步就是分组：

> "In the modal that appears, **select your app from the list of primary App IDs that is related to your website**."
> — [Configure Sign in with Apple for the web](https://developer.apple.com/help/account/capabilities/configure-sign-in-with-apple-for-the-web/)

分组的用途，Apple 讲得很直白：

> "To enable an App ID for a related app (for example, an App ID for the iOS version of your Mac app),
> group it with the existing primary. This is helpful if your app has versions for multiple Apple platforms
> **or the web** that you want to enable with Sign in with Apple."
> — [About Sign in with Apple](https://developer.apple.com/help/account/capabilities/about-sign-in-with-apple/)

> "Your users will need to provide consent for their information to be shared with you.
> To ensure this is only done once for each of your related apps or websites,
> we recommend grouping related identifiers together."
> — [Group apps for Sign in with Apple](https://developer.apple.com/help/account/capabilities/group-apps-for-sign-in-with-apple/)

最关键的一句，直接点名了「iOS / macOS / 网页 bundle ID 不同也只授权一次」：

> "You may group apps in your developer account for Sign in with Apple so an app only requests
> information the first time the user logs in. **A simple confirmation to continue appears even if
> the app bundle IDs are different across systems, such as iOS, macOS, and the web.**"
> — [Authenticating users with Sign in with Apple](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple)

**这一句是整件事的地基**：分组之后，Mac 网页那次登录**不是一次新授权**，用户不会被再问一遍「共享/隐藏我的邮箱」，
也就不会产生第二个邮箱身份。下面第 3 节解释为什么这恰好是重复账号的唯一现实成因。

## 2. `sub` 的作用域 —— 官方口径 vs. 现场反例

Apple 官方最明确的一句在 app transfer 文档里：

> "Every Sign in with Apple user has a user identifier. Apple issues a signed ID token for the user
> that contains the user identifier and, if applicable, the private email address specific to your team.
> **All of your applications share the same identifier for the user.**"
> — [Transferring your apps and users to another team](https://developer.apple.com/documentation/signinwithapple/transferring-your-apps-and-users-to-another-team)

同一篇里反复把它叫做 "team-scoped user identifier"（团队作用域）。

**但有一条现场反例，不能无视**：Supabase Auth 维护者在
[supabase/auth#1592](https://github.com/supabase/auth/issues/1592) 里明说

> "This is expected because of how Apple's OAuth works. The `sub` claim in the ID token Apple sends to
> Supabase Auth changes based on the bundle ID / app."

那个 case 里两个 App ID **没有分组**（是换了 bundle ID 新建的独立 primary）。这和第 1 节能对上：
`sub` 实际是按**分组**走的，未分组的两个标识符各算各的。

**结论：不能只凭文档拍板，必须在真实用户之前实测一次。** 实测方案见第 5 节 —— 成本极低且完全可回滚。

## 3. 配错了会怎样、能不能补救

Supabase 侧的判定逻辑（`supabase/auth` 源码 `internal/models/linking.go::DetermineAccountLinking`
+ `internal/api/provider/oidc.go::parseAppleIDToken`）：

1. 先按 `(provider='apple', provider_id=sub)` 找 identity —— 找到 → `AccountExists`，**同一个用户**。
2. 找不到，就按**已验证邮箱**去找现有用户 —— 找到 → `LinkAccount`，给老用户挂一条新 identity，**仍是同一个用户**。
   （Apple provider 里邮箱恒为 `Verified: true`，所以这条兜底一定生效。）
3. 邮箱也对不上 → `CreateAccount`，**这才产生第二个账号**。

所以真正会炸的组合是「`sub` 不同 **且** 邮箱不同」。邮箱不同的现实成因只有一个：
用户在第二次授权时选了「隐藏我的邮箱」，拿到一个不同的 relay 地址 ——
而第 1 节那句 Apple 原文说明，**正确分组会消灭这第二次授权**。#1592 的截图里一个真邮箱、一个
`@privaterelay.appleid.com`，正是这个形状。

**补救**：
- Apple 侧**没有**接口。`transfer_sub` / `userMigrationInfo` 那一套只服务于**跨团队的 app 转让**
  （[TN3159](https://developer.apple.com/documentation/technotes/tn3159-migrating-sign-in-with-apple-users-for-an-app-transfer)），
  不能用来合并同一团队内的两个 `sub`。
- 我们侧**能**补，但是手工脏活：在 `auth.users` / `auth.identities` 里合并，并把业务表的外键改指向，
  而且用户此时可能已经在两个账号里各自产生了数据。
- 一句话：**不是永久不可逆，但代价是手工数据迁移**，必须在发生前避免。

## 4. Supabase 是否支持同时授权多个 client id —— 支持，但顺序是硬要求

Supabase 官方文档（[Login with Apple](https://supabase.com/docs/guides/auth/social-login/auth-apple)）原文：

> "If your project also uses native Sign in with Apple (for example on iOS, Expo, or Flutter),
> list this Services ID as the **first** entry in the *Client IDs* field. Supabase uses the first
> client ID in the list for the web `signInWithOAuth` flow, while the native `signInWithIdToken`
> flow accepts any client ID in the list as a valid token audience, regardless of order.
> **If a native App ID comes before the Services ID, native sign-in keeps working but web sign-in
> is rejected by Apple.**"

源码印证：`internal/api/provider/apple.go::NewAppleProvider` 里 `ClientID: ext.ClientID[0]`。

**对我们的意义**：这个字段填错顺序**不会弄坏 iOS 原生登录**，只会让 Mac 网页登录失败。
也就是说改这一项对现有 iOS 用户是安全的。

Client secret 的 `sub` claim 必须等于用来发起请求的 `client_id`，即 **Services ID**
（[Creating a client secret](https://developer.apple.com/documentation/AccountOrganizationalDataSharing/creating-a-client-secret)）。
原生流程根本不用这个 secret（只做 JWKS 验签），所以这一项同样碰不到 iOS。

## 5. 写代码之前要做的那次实测（把第 2 节钉死）

顺序：作者按第 6 节配好后台 → 我在 Mac 上用作者自己的 Apple 账号走一遍网页登录 →
去 Supabase 看 `auth.users`：

- **还是原来那一行**（可能多出一条 `auth.identities`）→ 分组生效，可以放心往下做。
- **多出一行新 user** → 分组没有统一 `sub`，停手；删掉这行测试用户，回来重新设计
  （届时的备选是显式的「账号关联」UX，而不是硬上）。

这一步发生在任何真实用户之前，且完全可回滚。

## 6. 作者要去后台点的清单（照着点就行）

已知量：Team 下 App ID = `com.pendingname.pendingbot`；Supabase 项目 ref = `zafhoiwwpanpuashtnxy`。

**A. Apple Developer 后台**

1. Certificates, Identifiers & Profiles → Identifiers → 确认 `com.pendingname.pendingbot`
   的 Sign in with Apple 是 **"Enable as a primary App ID"**（不是 grouped 到别的下面）。
2. Identifiers → `+` → **Services ID**
   - Description：随便，例如 `PendingBot Web Sign In`
   - Identifier：建议 `com.pendingname.pendingbot.web`（**记下来，后面每一步都要用**）
3. 回到列表点开这个 Services ID → 勾 **Sign in with Apple** → **Configure**
   - **Primary App ID 选 `com.pendingname.pendingbot`** ← **整件事最关键的一步，选错就是重复账号**
   - Domains and Subdomains：`zafhoiwwpanpuashtnxy.supabase.co`
   - Return URLs：`https://zafhoiwwpanpuashtnxy.supabase.co/auth/v1/callback`
   - Done → Continue → Save
4. Keys → `+` → 勾 **Sign in with Apple** → Configure → Primary App ID 选 `com.pendingname.pendingbot`
   → Continue → Register → **下载 `.p8`（只能下一次，丢了只能吊销重发）**，记下 Key ID 和 Team ID。

**B. Supabase Dashboard → Authentication → Providers → Apple**

5. **Client IDs**：改成 `com.pendingname.pendingbot.web,com.pendingname.pendingbot`
   —— **Services ID 必须在前**（见第 4 节；顺序反了只会坏 Mac，不会坏 iOS）。
6. **Secret Key (for OAuth)**：用第 4 步的 `.p8` + Key ID + Team ID 生成 client secret，
   **JWT 的 `sub` 填 Services ID**（`com.pendingname.pendingbot.web`）。
   Supabase 文档页自带一个纯浏览器端的生成工具（Safari 不支持，用 Chrome/Firefox）。
7. Authentication → URL Configuration → **Redirect URLs** 里加上 app 的回调
   （`pendingbot://` scheme 已经注册在 Info.plist 里，具体路径我在实现时定下来后回来告诉你补）。
8. 把生成 secret 时用的 **到期时间记进日历**（Apple 上限 6 个月，见 tech-debt）。

**C. 然后叫我** —— 我做第 5 节那次实测，出结果再往下写代码。

## 7. 一条要纠正的前提

任务描述里说「Google 在 Mac 上现在就是 `signInWithOAuth` 这个形状，这条路已经被验证过」——
**仓库现状不是这样**。`Sources/Networking/GoogleSignIn.swift` 走的是 GoogleSignIn SDK
（`GIDSignIn.sharedInstance.signIn` → `signInWithIdToken(.google, …)`），全仓没有任何一处
`signInWithOAuth`。所以「浏览器授权 → 回跳 app → 建立会话」这条链路在本项目里是**全新的**。

不影响可行性（`pendingbot://` scheme 已在 `Resources/Info.plist` 注册，`supabase-swift` 的
`signInWithOAuth` 底下走 `ASWebAuthenticationSession`），但工作量和风险要按「新链路」估，
不能按「照抄 Google」估。

---

## 引用

- Apple — [About Sign in with Apple](https://developer.apple.com/help/account/capabilities/about-sign-in-with-apple/)
- Apple — [Group apps for Sign in with Apple](https://developer.apple.com/help/account/capabilities/group-apps-for-sign-in-with-apple/)
- Apple — [Configure Sign in with Apple for the web](https://developer.apple.com/help/account/capabilities/configure-sign-in-with-apple-for-the-web/)
- Apple — [Authenticating users with Sign in with Apple](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple)
- Apple — [Transferring your apps and users to another team](https://developer.apple.com/documentation/signinwithapple/transferring-your-apps-and-users-to-another-team)
- Apple — [TN3159: Migrating Sign in with Apple users for an app transfer](https://developer.apple.com/documentation/technotes/tn3159-migrating-sign-in-with-apple-users-for-an-app-transfer)
- Apple — [Creating a client secret](https://developer.apple.com/documentation/AccountOrganizationalDataSharing/creating-a-client-secret)
- Supabase — [Login with Apple](https://supabase.com/docs/guides/auth/social-login/auth-apple)
- Supabase — [auth#1592 Changing Apple bundle ID causes duplicate users](https://github.com/supabase/auth/issues/1592)
- Supabase — 源码 `internal/models/linking.go`、`internal/api/provider/apple.go`、`internal/api/provider/oidc.go`
