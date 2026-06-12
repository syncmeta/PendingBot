# PendingCrew 登录 / 家族 SSO 设计

**2026-06-08**。配套上游讨论(本 session)。取代"必须扫码 / 必须选模式"的旧登录心智。

## 目标

PendingCrew 的登录要**更顺、且安全不过权**:

1. **进软件默认就是本机模式**(已落 `155f09e5`),登录是**可选升级**(解锁云端 crew / Fly machine / unified billing),不开屏逼人选。
2. **本机若已有同公司 app 的登录态 → 近乎一键登录**(你说的"本机已登录 pendingbot 就直接登录"),但 **PendingCrew 永远只拿到自己 scoped 的 grant,碰不到别的 app 的权限**。
3. 对齐业界成熟模式(Microsoft MSAL / Google Sign-In 的 same-publisher SSO):**共享"账号身份/换票凭据",不共享"全权令牌";每个 app 各换各的 scoped 票**。

非目标:不做第三方 IdP 联邦;不动现有扫码流程的服务端语义(只在其上加层)。

## 背景 / 现状(已核实代码)

- 登录 = **device-login challenge**(`apps/edge/src/routes/device-login.ts`):
  - `POST /v1/device-login/challenges` → `{challengeId, secret, code, qrPayload}`,`qrPayload = https://bot.pendingname.com/d/<id>?s=<secret>&k=<appKind>`。
  - `GET /v1/device-login/challenges/:id?secret=` 轮询;approved 那拍 mint 出 `deviceGrantToken`(`pdg_…`)。
  - `POST /v1/device-login/challenges/:id/approve`(`requireSession()`)由**已登录用户**批准,授 `grantKind ∈ {pendingbot_client, pendingcrew_control, pendingcrew_runner}`,scope 受 `allowedScopesForGrant` + 原始 challenge 请求双重夹逼。
- `bot.pendingname.com` 目前 **worker 全 404 + 只做 Apple Universal Link(AASA)** —— 扫码 = universal link 唤起**手机 PendingBot app** 在 app 内批准,**没有批准网页**。
- 两个 app **同 team `M42BKJN82S`**,但 keychain access group **各用私有组**(`…com.pendingname.pendingcrew` / `…pendingbot`),**互不可读**。
- grant 体系本就是"per-app scoped 票" —— 正好是 SSO 里"各换各的 scoped 票"的现成承载。

## 架构:三层 fallback(从最顺到兜底)

> 共同前提:成功登录(任意一层)除了拿到本 app 的 grant,还会拿到/刷新一个**家族 SSO 凭据**写进**共享 keychain 组**,供后续任意同 team app 自助换票。第一台机的首登必然走 L2/L3 bootstrap,之后 L1 生效。

### Layer 1 —— 家族凭据自助 mint(最优,纯本地、秒登)

- 共享 keychain 组里有家族凭据 → PendingCrew 直接 `POST /v1/device-grant/mint {familyCred, appKind:'pendingcrew_macos', grantKind:'pendingcrew_control', deviceName, devicePublicKey, scopes}` → edge 校验后**只发 `pendingcrew_control` grant**。
- **不需要手机、不需要浏览器、不需要 PendingBot 在跑**。
- PendingCrew 拿到的永远是自己的 scoped grant;家族凭据**换不出 session、代表不了用户读数据**。

### Layer 2 —— OAuth / 浏览器(无本机登录态时)

- `ASWebAuthenticationSession`(claude code 同款)打开 `bot.pendingname.com/d/<id>`(**需新建批准网页**):
  - 浏览器已登录 pendingname.com(Supabase 会话 cookie)→ "授权这台 Mac 跑 PendingCrew?[批准]" 一键 → 调 `/approve`。
  - 没登录 → 网页内先 Supabase 登录(邮箱 OTP / Apple / Google)→ 再批准。
  - 批准后顺手签发家族凭据(给 L1 bootstrap);回调 `pendingcrew://device-login`(scheme 已注册)关闭浏览器。
- app 侧轮询照旧拿 grant。

### Layer 3 —— 扫码(兜底 / 跨设备)

- 现有手机扫码流程不变。批准时同样签发家族凭据。

## 核心机制:家族 SSO 凭据 = 一个只有 `family_sso` 能力的 grant

**不新造令牌类型** —— 复用 device-grant 表 + 撤销机制:

- 新 `grant_kind = 'family_sso'`(或等价的 `family:mint` scope):**唯一能力**是"为**同一 user**、**同家族**的 app mint 子 grant,scope ≤ `allowed(appKind)`"。**不能**:换 Supabase session、读/改用户数据、当用户身份调任何业务端点。
- **签发**:任意一层登录成功(approve / OAuth / 扫码)时,edge 额外发一张 `family_sso` grant(`pfa_…`),长生命周期、可撤销、可轮换。
- **存储**:写进**共享 keychain 组** `M42BKJN82S.com.pendingname.shared`(两 app entitlement 都加 + `kSecAttrAccessGroup` 显式带这个组)。
- **mint 端点** `POST /v1/device-grant/mint`:
  - 认证 = 家族凭据(`Authorization: Bearer pfa_…`),**不是** session。
  - 校验:凭据有效/未撤销/未过期 → 目标 `grantKind` 属本家族且与 `appKind` 兼容(复用 `appGrantCompatible`)→ `scopes ⊆ allowedScopesForGrant(grantKind)`。
  - 产出:一张普通 device-grant(同现有 mint 逻辑),记 `parent_family_grant_id` 便于级联撤销。
- **撤销**:用户"退出所有设备 / 撤销本机授权"→ 撤 family grant → 级联撤其 mint 出的子 grant。

### 信任模型(为什么安全)

- 家族凭据虽能换本家族任意 app 的 grant,但**防线 = 共享 keychain 组(entitlement-gated,只有同 team `M42BKJN82S` 签名的 app 读得到)** + **不可换 session** + **可撤销** + **mint 出的 grant 仍受 scope 矩阵夹逼**。
- 这与 **MSAL 共享 refresh token / Google 共享 SSO 凭据**同一套假设:同一发布者的 app 互信,OS keychain 组做边界,签发方按 app 限 scope。
- **关键:不共享 Supabase 全权 session** —— 这正是上游讨论里否掉的过权点。

## 改动面

**Edge**:
- 迁移:`subject_device_grants` 加 `family_sso` kind + `parent_family_grant_id`(级联撤销)。schema regen。
- `device-login.ts`:approve / mint 路径在发子 grant 的同时,若无 family grant 则签发一张并随响应返回(供 app 存共享组)。
- 新 `device-grant.ts`:`POST /mint`(家族凭据认证)+ `POST /revoke`(撤销家族 + 级联)。
- L2 批准网页:`bot.pendingname.com/d/:id` 服务一个 HTML(浏览器内 Supabase auth + 批准 UI + 回调)。**这是 L2 的大头**,可独立排期(L1+L3 先上,L2 后补)。

**App(PendingCrew + 后续 PendingBot Mac)**:
- entitlement 加共享组 `M42BKJN82S.com.pendingname.shared`;`KeychainStore` 家族凭据读写带 `kSecAttrAccessGroup`。
- 登录编排:启动静默试 L1(读共享凭据→mint)→ 失败才在侧栏给"登录"入口(L2 ASWebAuthenticationSession;L3 扫码)。
- 登录成功后把响应里的家族凭据写进共享组。
- 侧栏身份区:本机模式下"登录 PendingBot 账号"入口(目前是占位)。

## 验证策略

- **能本地验**:mint 端点 + family grant 签发/撤销/级联(edge vitest);scope 夹逼矩阵;app 侧 KeychainStore 共享组读写(单测)。
- **需真机/部署验(人工尾巴)**:① 共享 keychain 跨 app 真读到(要两个真签名 app + 含共享组的 provisioning);② L2 浏览器 OAuth 全链路(真浏览器 + 部署 edge + 真 Supabase 会话);③ L1 秒登端到端。
- 安全自查:family 凭据**确实换不出 session**(负向测试:拿 family 凭据打业务端点 → 401);撤销后子 grant 全失效。

## 决策 / 待定

- **D1 家族凭据用 `family_sso` grant_kind**(复用 grant 表),不另起表/令牌族。✅(本 spec 采用)
- **D2 谁先 bootstrap**:不强依赖 PendingBot Mac —— **PendingCrew 自己首登(L2/L3)也会写家族凭据**,之后同机任意同 team app(含将来 PendingBot Mac)秒登。自举。
- **D3 排期**:L1(mint + 家族凭据 + 共享组)+ L3(扫码顺手发家族凭据)先做(纯本地可验大半);**L2 批准网页**单独一块(要 web + 部署)。
- **D4 共享组命名** `M42BKJN82S.com.pendingname.shared` —— 需在 Apple Developer 配 provisioning(两 app 都包含)。**人工尾巴**。
- **开放**:PendingBot 现在把 Supabase 会话存哪(supabase-swift 默认 keychain storage?)→ 决定 PendingBot 侧改动量;本 spec 不要求改 PendingBot 的会话存储,只要求它登录时**也存一份家族凭据进共享组**。

## 与现有工作的边界

- 不动 `feat/session-crew-comms` 已落的 ask-approval / 本机模式默认 / 正名。
- 这是**独立一块**(登录 SSO),建议自己的分支 / task;edge schema 改动要从主 worktree `db push` + regen(授权我做运维,但要你在场确认那一拍)。
