# PendingCrew 登录页搬 PendingBot + 同发布者「确认登录」设计

**2026-06-17**。延续并具体化 [2026-06-08 PendingCrew 登录 / 家族 SSO 设计](2026-06-08-pendingcrew-login-sso-design.md)：**保留**那份 spec 的核心安全立场（PendingCrew 只持 scoped grant、不共享全权 session），在其上把登录**入口 UI** 换成 PendingBot 那套登录页，并加一张同发布者「确认登录」卡。

## 目标

1. **登录页搬 PendingBot**：PendingCrew 的登录界面镜像 PendingBot Mac 的 [MacWelcomeView](../../../apps/pendingbot/Sources/Mac/MacWelcomeView.swift) —— BrandMark + 「登录 / 注册：」+ `Apple / Google / 扫码` 三胶囊同排 + 邮箱验证码行 +「你是？」人机验证（Turnstile）。逻辑复用跨平台 `WelcomeViewModel`。
2. **同发布者「确认登录」**：检测到本机已登录过 PendingBot（共享 keychain 有家族凭据）→ 先显示一张**确认卡**（头像 + 账号名 +「继续使用此账号」），一键登录；「换其它账号」→ 落到 #1 的登录页。
3. **安全模型不变**：无论走哪条路径，PendingCrew 最终只持有受限的 `pendingcrew_control` device grant（`pdg_*`）。直接登录路径里的 Supabase session 是**一次性**的，用完即弃、绝不持久化。

## 非目标

- 不让 PendingCrew 变成持有全权 Supabase session 的完整客户端（用户已拍板「沿用 scoped grant」）。
- 不动服务端 device-login / device-grant / 家族 SSO 的语义（只在 client 侧重组 UI + 复用现有端点；edge 仅一处增量回包，见下）。
- 不做第三方 IdP 联邦。

## 已敲定决策（本 session 与用户确认）

- **D1 登录态模型 = 沿用 scoped grant**。直接登录页在 app 内登 Supabase 拿**临时** session → 调 `/v1/me/family-credential` 拿 `pfa_` → `/v1/device-grant/mint` 换 `pendingcrew_control` grant → 丢弃 session。
- **D2 平台 = macOS + iPad** 都做。
- **D3 保留扫码**为第三条登录路径（第三个胶囊），忠实镜像 MacWelcomeView。扫码是「本机没装 PendingBot、但账号在手机 PendingBot 上」的跨设备路径，价值独立，不退役。
- **D4 确认卡身份来源 = 扩展共享 keychain payload**：PendingBot 登录时把 `displayName` + 头像 seed 一起写进共享组，PendingCrew 离线即时渲染确认卡（确认前就能显示头像+账号）。字段可选，旧 payload 优雅降级。
- **D5 移植方式 = Port-Full**：连 supabase-swift（Auth）+ GoogleSignIn SDK 整套搬进 PendingCrew，两 app 登录逻辑零漂移；仅 VM 成功回调的落点不同（兑换 grant 而非存 session）。

## 背景 / 现状（已核实代码）

### 两套并存的认证模型

- **PendingBot**：登录产出完整 **Supabase session**（`AccountStore`），Apple/Google/邮箱 OTP 走共享 `WelcomeViewModel` + `EmailSignIn`/`AppleSignIn`/`PendingGoogleSignIn`。
- **PendingCrew**：登录产出受限 **device grant**（`pdg_*`，[PendingCrewAuthCredential](../../../apps/pendingcrew/Sources/Support/PendingCrewAuthCredential.swift)），经 `Authorization: Bearer pdg_…` 调 `/v1/*`。macOS 上 `AppModel.isConfigured` 恒 true（本地为家），登录是**可选能力叠加**（侧栏入口，绝不开屏逼登）；iPad 上登录是硬门槛（无本地后端）。

### 三条登录路径的服务端事实（device-login.ts / device-grant.ts / me.ts）

- **扫码 / device-login**（[device-login.ts](../../../apps/edge/src/routes/device-login.ts)）：未登录设备 `POST /v1/device-login/challenges`（带 `appKind`）→ `{challengeId, secret, code, qrPayload}`，`qrPayload = https://bot.pendingname.com/d/<id>?s=<secret>&k=<appKind>`。已登录的手机 PendingBot 扫码 → `POST /challenges/:id/approve`（`requireSession()`，按 `grantKind` 授权）→ 出码方 `GET /challenges/:id?secret=` 轮询拿 `deviceGrantToken`。
  - **同一端点服务两 app，靠 `k=appKind` 区分**：`pendingcrew_macos` vs `pendingbot_macos`。手机扫码器 [QRScannerView.DeviceLoginLink](../../../apps/pendingbot/Sources/Components/QRScannerView.swift) 解析 `k` 并自带显示名（"PendingCrew" / "PendingBot Mac"），展示对应同意文案 + 用匹配 `grantKind` 调 approve。
  - **产出按 app_kind 分流钉死**：`supabaseTokenHash`（→ session）只在 `app_kind==='pendingbot_macos'` 时签发（device-login.ts L255）；`pendingcrew_*` 永远只拿 `pdg_` grant。`appGrantCompatible` 双重夹逼（pendingbot_macos→pendingbot_client；pendingcrew_*→pendingcrew_control/runner）。
  - approve/consume 那拍**顺手签发家族凭据 `pfa_`** 随响应回包（供写共享组）。
- **家族 SSO mint**（[device-grant.ts](../../../apps/edge/src/routes/device-grant.ts)）：`POST /v1/device-grant/mint`，认证 = `Authorization: Bearer pfa_…`（**不是 session**），校验 `appGrantCompatible` + scope 夹逼 → 出一张 `pdg_` grant。PendingCrew 现有 `AppModel.tryFamilySSO` 已在用（grantKind `pendingcrew_control`，scopes `subject:read/crew:read/crew:write/runner:read/runner:write`，appKind `pendingcrew_macos`）。
- **session → 家族凭据**（[me.ts](../../../apps/edge/src/routes/me.ts) `POST /v1/me/family-credential`，`requireSession()`）：登录态直接签发 `pfa_`，返回 `{familyCredential:{token, subjectId}}`。PendingBot Mac 登录后用它 bootstrap 家族凭据。

> **关键收敛**：三条路径殊途同归到「拿到 `pfa_` → `mint` 换 `pdg_`」（扫码路径直接出 `pdg_`，省去 mint）。直接登录路径 = `session →（/me/family-credential）→ pfa_ →（/device-grant/mint）→ pdg_ → 丢 session`，全程复用现有端点，**edge 仅需一处增量**（见改动面 E1）。

### 共享 keychain 契约（两 app 字节级一致）

- 共享组 `M42BKJN82S.com.pendingname.shared`，service `com.pendingname.family-sso`，存 `FamilyCredential{token, subjectId}`（JSON）。
- 写入侧 = PendingBot [FamilyCredentialWriter](../../../apps/pendingbot/Sources/Storage/FamilyCredentialWriter.swift)；读取侧 = PendingCrew [FamilyCredentialStore](../../../apps/pendingcrew/Sources/Support/FamilyCredentialStore.swift)。
- **两 app entitlement 已含共享组**（PendingCrew.entitlements / PendingBot.entitlements 都已声明），无需 portal 配置。
- **已知缺口**：① PendingBot 的 writer 是 `#if os(macOS)`，`AccountStore` 登录时只在 Mac 调 `syncIfNeeded()` —— iOS/iPad 不写凭据 → 同一台 iPad 上 PendingBot 已登录也检测不到。② payload 只有 `{token, subjectId}`，**无 displayName/头像** → 确认卡没法离线显示身份。

### PendingCrew 客户端现状缺口

- **无 Supabase/Turnstile/Google 配置**：PendingCrew 当前只有 `AppModel.apiBaseURL`，没有 HostedConfig 等价物。直接登录（Apple/Google/邮箱 OTP）需要 Supabase URL + publishable key + Turnstile siteKey/host + Google client id —— 全要新建（镜像 PendingBot HostedConfig 的对应字段）。
- 登录 UI 现状：iPad 走 [WelcomeView](../../../apps/pendingcrew/Sources/Views/WelcomeView.swift) →[LoginView](../../../apps/pendingcrew/Sources/Views/LoginView.swift)（扫码 + 一个家族 SSO 按钮，无头像/账号展示）；Mac 走侧栏「用本机 PendingBot 身份登录」入口。

## 架构

### 三条登录路径（各管一段）

| 路径 | 适用场景 | 机制 | 产出 |
|---|---|---|---|
| **确认卡（家族 SSO）** | 本机装过且登录过 PendingBot | 读共享 `pfa_` → `mint` | `pdg_` grant |
| **Apple / Google / 邮箱**（搬来） | 本机没 PendingBot、手机也不在手边 | 临时 session →`/me/family-credential`→ `pfa_` →`mint` | `pdg_` grant |
| **扫码** | 本机没 PendingBot、但账号在手机上 | 出码 → 手机 PendingBot 扫码批准 → 轮询 | `pdg_` grant |

### 顶层流程

```
进入登录态
  │
  ├─ FamilyCredentialStore.get() 有 pfa_ ?
  │     ├─ 有 → ① 确认卡：[头像] displayName
  │     │         「继续使用此账号」→ AppModel.tryFamilySSO()（已存在）→ pdg_ → 进主界面
  │     │         「换其它账号」──────────────┐
  │     └─ 无 ────────────────────────────────┤
  │                                           ▼
  └──────────────────────────► ② 登录页（镜像 MacWelcomeView）
                                  Apple / Google / 扫码 / 邮箱 OTP
                                  ├─ 扫码 → 现有 device-login（出码给手机批准）→ pdg_
                                  └─ Apple/Google/邮箱 → 临时 Supabase session
                                       → POST /v1/me/family-credential → pfa_（写共享组）
                                       → POST /v1/device-grant/mint → pdg_
                                       → **丢弃 session** → 进主界面
```

### 各平台落点

- **iPad**：登录是硬门槛。`RootView` 在 `!isConfigured` 时渲染新 `CrewWelcomeView`（iPad 渲染层）；若有家族凭据，页顶先出确认卡，「换号」切到登录页主体。替换现有 WelcomeView→LoginView 链路。
- **macOS**：本地为家，登录是可选能力叠加，**不做启动 gate**。侧栏「登录」入口点击后以 **sheet** 弹出 `CrewMacWelcomeView`（Mac 渲染层）；若有家族凭据，sheet 直接开到确认卡（一键继续）。沿用 `AppModel` 里「登录必须是用户显式动作、不在启动静默 mint」的既定约束。

### 安全：一次性 session

直接登录路径里，Supabase session 只为调一次 `/v1/me/family-credential` 而短暂存在。机制 = PendingCrew 的 Supabase client 用**内存态 `AuthLocalStorage`**（不写 keychain/UserDefaults），兑换拿到 `pfa_` 后立即 `signOut()` 清掉内存 session。fail-loud 校验：兑换出口断言「共享组外、app 私有 keychain 里没有任何 Supabase session token」，单测覆盖（注入内存 storage，兑换后查不到 session）。PendingCrew 长期只持 `pdg_` grant —— 守住 2026-06-08 spec 的「不共享全权 session、最小权限」。

## 改动面

### PendingCrew（主体）

- **PC1 Vendor 登录栈**：把 PendingBot 的 `WelcomeViewModel` + `EmailSignIn` + `AppleSignIn` + `GoogleSignIn` + Turnstile webview（iPad `TurnstileWebView` / Mac `MacTurnstileWebView`）按既有 vendor 惯例（[Sources/Chat/Vendored](../../../apps/pendingcrew/Sources/Chat/Vendored)）复制进 PendingCrew。
- **PC2 新渲染层**：`CrewWelcomeView`（iPad）/ `CrewMacWelcomeView`（Mac）镜像 PendingBot 的两个 Welcome 视图；新增 `AccountConfirmCard`（头像 + displayName + 继续/换号）。
- **PC3 VM 成功落点改写 + 一次性 session 机制**：PendingCrew 的 Supabase client 用**内存态 `AuthLocalStorage`**（不落 keychain，对齐 supabase-swift 可注入 storage 的设计），所以 session 天然不持久化。`WelcomeViewModel` 的 Apple/Google/邮箱成功回调从 PendingBot 的「auth listener 落 session 到 AccountStore」改为「`CrewLoginExchange`：从内存 session 取 access token →`/me/family-credential`→`mint`→`signOut()` 清内存 session→`AppModel.saveDeviceGrantToken`」。扫码路径不碰 Supabase，沿用现有 `PendingCrewAPI.createDeviceLoginChallenge` + 轮询。
  - 注意：PendingBot 的 `EmailSignIn`/`AppleSignIn`/`PendingGoogleSignIn` 内部直接驱动 PendingBot 自己的 supabase 单例 + AccountStore；vendor 进 PendingCrew 时要把它们重定向到 PendingCrew 的内存态 client（`CrewLoginExchange` 持有），不引 AccountStore。
- **PC4 配置面**：新建 PendingCrew 的 `HostedConfig` 等价（Supabase URL + publishable key + Turnstile siteKey/host + Google client id），镜像 PendingBot 取值；project.yml 加 SPM 依赖 **Supabase** + **GoogleSignIn**。
- **PC5 确认卡读取**：`FamilyCredentialStore` 读扩展后的 payload（含可选 displayName/头像 seed）渲染确认卡；缺 profile 时降级到通用文案，mint 成功后用 `/v1/me/subject`（已在调）回填真实身份。
- **PC6 RootView/侧栏接线**：iPad gate 换新页；Mac 侧栏入口弹 sheet。

### PendingBot（小改）

- **PB1 payload 加 profile**：`FamilyCredential` 结构加可选 `displayName` + 头像 seed；`FamilyCredentialWriter` 写入时带上（从 `AccountStore` 取）。
- **PB2 writer 跨平台**：把 `FamilyCredentialWriter` 从 `#if os(macOS)` 放开到 iOS 也编、`AccountStore` 在 iOS 登录后也调 `syncIfNeeded()`（验证 PendingBot iOS 已含共享组 entitlement —— 现有 entitlements 文件跨平台共用，应已覆盖，构建时核实）。

### Edge（一处增量）

- **E1** `POST /v1/me/family-credential` 顺手回 `displayName`（给直接登录路径 mint 后也能即时显示身份；确认卡主走 PB1 的 keychain profile，E1 是冗余兜底）。`mint` / scopes / `pendingcrew_control` 全现成，无新端点。

### 共享契约

- **C1** `FamilyCredential` 结构两侧同步加可选字段（PendingBot writer 写、PendingCrew store 读）—— 字节级契约，**一次提交同时改两边**，新字段 optional 保证旧 payload 不 decode 失败。

## 分阶段 + 顺序约束

- **P1（核心、低依赖、不引 supabase-swift/Google）**：reskin 登录页骨架（含扫码胶囊，复用现有 device-login）+ 确认卡 + 家族 SSO mint（复用 `tryFamilySSO`）+ PB1/PB2/C1（PendingBot 写 profile、iOS 也写）。交付 hero 体验「pendingbot 登录了 → 确认」。
- **P2（较大）**：Apple/Google/邮箱直接登录栈（PC1/PC3/PC4 + E1）。
- **顺序约束**：**P2 落地前不拆扫码**。否则「本机没装 PendingBot 的全新 iPad 用户」在 P1 阶段会无路可登（确认卡不出、直接登录还没上、只剩扫码）。扫码在本设计里本就是 D3 保留项，无退役计划。

## 验证策略

- **能本地验**：
  - `CrewLoginExchange` 兑换状态机（session→pfa_→mint→丢 session）单测（mock 端点）；fail-loud「无 session 持久化」断言。
  - `FamilyCredential` 扩展 payload 的 encode/decode 向后兼容（旧 payload 无新字段仍 decode 成功）。
  - `WelcomeViewModel` 复用 PendingBot 现有逻辑，行为不变。
  - Mac + iPad `xcodebuild` 编译过。
- **需真机 / Xcode GUI 验（人工尾巴，记 tech-debt）**：
  - ① 共享 keychain 跨 app 真读到（两个 Apple Development 正常签名的 app；headless ad-hoc 构建下 `-34018` 必失败 —— 见 FamilyCredentialStore 注释）。
  - ② 确认卡端到端：Mac 装 PendingBot 登录 → PendingCrew 确认卡显示正确头像+账号 → 一键登录拿 grant。
  - ③ 直接登录三种方式（Apple/Google/邮箱）真机各通一遍 + 兑换出 `pdg_`。
  - ④ iPad 上 PendingBot（iOS 写凭据）→ PendingCrew 确认卡可用。
  - ⑤ 扫码：PendingCrew 出码 → 手机 PendingBot 扫码识别为 "PendingCrew" → 批准 → grant。

## 风险 / tech-debt

- **R1 Port-Full 给 PendingCrew 引入 supabase-swift + GoogleSignIn 两个重依赖**，仅为拿一次性 session。这是为「登录逻辑零漂移」付的代价；记 tech-debt（可评估后续抽 GoTrue REST 薄封装去依赖，但当前不做）。
- **R2 appKind 枚举无 iPad 变体**：`AppKind` 只有 `pendingbot_macos` / `pendingcrew_macos`，iPad 上 PendingCrew 复用 `pendingcrew_macos`（命名漂移，不影响逻辑 —— `appGrantCompatible` 只认 pendingcrew 前缀族）。记 tech-debt，后续可正名为平台无关的 `pendingcrew`。
- **R3 PendingBot iOS 写家族凭据 = 扩大共享凭据的产生面**：iPhone-only 用户登录也会落一张 `pfa_` 进共享组（虽然 iPhone 上没 PendingCrew 读）。可接受（凭据本就可撤销、90 天过期、entitlement-gated），记一笔。
- **R4 真机尾巴多**（上面 ①-⑤）：共享 keychain / OAuth / 扫码都只能真机或 Xcode GUI 验，骨架阶段 task 不提前关，缺口记 tech-debt。

## 与现有工作的边界

- 不动 2026-06-08 SSO spec 已落的 device-login / mint / 家族 SSO 服务端语义，只在其上重组 client UI + 一处 edge 增量回包。
- 不动本地为家 / ask-approval / crew-comms 等既有 PendingCrew 工作。
- edge 改动（E1）极小，若需 db push 无（无 schema 改动）；部署照常 user 在场确认。
