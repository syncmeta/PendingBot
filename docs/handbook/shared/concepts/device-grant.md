# 设备授权(scoped grant)

一台设备怎么"代表某个 [subject](subject.md)"做事,而又**不持有那个 subject 的全权登录态**。这是 PendingCrew 登录的安全地基。

**逻辑** —— 核心是把"账号身份"和"能力令牌"分开:

- **PendingCrew 永远只拿到 scoped grant,拿不到全权 session。** 它持有的是一张受限的设备授权令牌(`pdg_*`,grant kind `pendingcrew_control`),只能调它被授权的那几类端点(读 subject、读写 crew、读写 runner),**换不出 Supabase session、代表不了用户读任意数据**。
- **家族 SSO 凭据(`pfa_*`)是一张"只能换票"的账号级凭据。** 它的**唯一能力**是为同一个 user、同一发布者(同 Apple team)的 app mint 出 scoped grant,且 scope 不超过该 grant kind 允许的上限。它同样**换不出 session、不能当用户身份调业务端点**。
- **两个 app(PendingBot / PendingCrew)共享"账号身份/换票凭据",不共享"全权令牌";每个 app 各换各的 scoped 票。** 这对齐业界成熟模式(Microsoft MSAL / Google Sign-In 的同发布者 SSO)。

**用在哪·长什么样 —— 三条登录路径殊途同归**

PendingCrew(Mac/iPad 编排工作台)不做独立的应用内全权登录,登录是"可选能力叠加"。三条路径最终都收敛到"拿到 `pfa_` → mint 换 `pdg_`":

| 路径 | 适用场景 | 产出 |
|---|---|---|
| **确认卡(家族 SSO)** | 本机装过且登录过 PendingBot,共享 keychain 有 `pfa_` | 读 `pfa_` → mint → `pdg_` grant,近乎一键 |
| **直接登录(Apple / Google / 邮箱 OTP)** | 本机没 PendingBot、手机也不在手边 | 临时 session →`/me/family-credential`→ `pfa_` → mint → `pdg_`,**用完即弃 session** |
| **扫码** | 本机没 PendingBot、但账号在手机 PendingBot 上 | 出码 → 手机已登录的 PendingBot 扫码批准 → 轮询拿 `pdg_` |

家族凭据存在**共享 keychain 组**(`M42BKJN82S.com.pendingname.shared`)里,只有同一发布者(同 team)签名的 app 读得到。

**示例 —— 旅游群登录 PendingCrew** — owner 想在自己 Mac 上代表「五一川西」群账号开 crew:他在 PendingCrew 扫码 → 手机上已登录的 PendingBot 弹出"授权这台 Mac 代表「五一川西」跑 PendingCrew?" → 他选这个群账号、点批准 → Mac 轮询拿到一张 `pendingcrew_control` 的 `pdg_` grant,存进 Keychain。之后这台 Mac 上 PendingCrew 的所有请求都带这张 grant,所有 crew / 会话 / 费用都归「五一川西」。这台 Mac 始终没拿到 owner 的 Supabase session,只拿到了一张受限、可撤销的控制票。

**为什么这样设计**
- **共享账号、分开授权、换不出 session** —— 一台机器一旦被夺,泄露的是一张 scoped、可撤销的 grant,而不是用户的全权登录态。
- **可独立开源** —— PendingCrew 作为"准备开源软件",必须能不登录 PendingBot 就用(未登录走 BYOK 本地模式)。登录只是叠加"云端 crew / unified billing"的可选升级,不开屏逼登。
- **"登录代表群账号"是高一档的能力** —— 它在物理设备上打开"以某 subject 跑本机 coding agent"的通道,所以收在群权限矩阵的 admin+(见 [群权限矩阵](group-permissions.md))。

**边界**
- **不共享全权 Supabase session** —— 这是整个模型否掉的过权点;PendingCrew 长期只持 `pdg_`,直接登录路径里的 session 是一次性的、用完即弃、绝不持久化。
- **不做第三方 IdP 联邦** —— 同发布者 SSO 用的是 OS keychain 组做边界,不引第三方身份提供方。
- **凭据可撤销、可级联** —— 用户"退出所有设备"撤掉 family grant 时,它 mint 出的子 grant 一并失效。

**注意**
- **🟨 `devicePublicKey` 还是占位字符串,grant 没和物理设备做密码学绑定。** PendingCrew 客户端传的是 `"scaffold-placeholder-key-…"`(`PendingCrewAPI.swift`)。这意味着设备公钥还没真正参与签发,grant 与具体物理设备的密码学绑定尚未闭合 —— Phase 4 跨端遥控前置必做,已记 tech-debt。别把这条当已验证。
- **"登录页搬 PendingBot + 确认卡"是 2026-06-17 的演进,不是新模型。** 它只换了登录**入口 UI**(镜像 PendingBot 登录页 + 同发布者确认卡),服务端 device-login / mint / 家族 SSO 语义不变。安全立场("只持 scoped grant、不共享全权 session")完全沿用 2026-06-08 SSO spec。
- **appKind 枚举没有 iPad 变体** —— iPad 上 PendingCrew 复用 `pendingcrew_macos`(命名漂移,不影响逻辑,`appGrantCompatible` 只认 `pendingcrew` 前缀族)。已记 tech-debt。

**现状** — 🟨 服务端三条路径的端点都已落 + 部署(device-login challenge / `/device-grant/mint` / `/me/family-credential`,家族凭据签发 + 级联撤销 + scope 夹逼);客户端 P1(确认卡 + 家族 SSO mint)+ P2(直接登录栈)已落代码。**真机尾巴多且必做**:共享 keychain 跨 app 真读、OAuth 全链路、扫码端到端,只能真签名 app + Xcode GUI 验(headless ad-hoc 构建必失败);且 `devicePublicKey` 占位未闭合。证据见 [`docs/progress.md`](../../../progress.md) T1.3 + 2026-06-17 登录搬迁行;细节下指 [`2026-06-08 SSO spec`](../../../superpowers/specs/2026-06-08-pendingcrew-login-sso-design.md) 与 [`2026-06-17 登录港 spec`](../../../superpowers/specs/2026-06-17-pendingcrew-login-port-design.md)。
