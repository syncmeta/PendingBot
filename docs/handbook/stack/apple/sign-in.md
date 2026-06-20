# 登录(Apple / Google / 邮箱 / 扫码)

用户怎么进大绿豆。系统里这是 [Supabase](../supabase/supabase.md) Auth 那一层在 Apple 客户端的呈现——账号身份从 Supabase 签发,本篇讲用户能看到的几条登录路径,以及 PendingCrew 那条"用完即弃 session"的特殊路。安全模型(为什么 PendingCrew 不持全权 session)的权威定义在 [设备授权](../../shared/concepts/device-grant.md),本篇不重抄,只立"有哪些路径、各长什么样"。

**逻辑 — 几条路,各管什么**

- **PendingBot:四条平等的登录路径**——Apple 登录、Google 登录、邮箱 OTP(验证码)、扫码。前三条产出一个正常的 Supabase session(账号身份),app 拿着它读写。它们在登录壳里是并列入口,用户选顺手的那条。
- **邮箱走 OTP,不走密码 + 单独确认**:输邮箱 → 收验证码 → 验码即登录。验证码本身已证明你掌握这个邮箱,所以不再加一道独立的邮件确认(那会和 OTP 路径冲突)。
- **登录前有一道人机校验(Turnstile)**:进 OTP 这一步前,后台静默预取一枚 Cloudflare Turnstile token 当人机门;绝大多数情况用户无感(token 自动拿到),只有 Cloudflare 真要交互时才弹出控件。这是 Supabase EU 项目开了 CAPTCHA 保护的直接结果(见 [Supabase](../supabase/supabase.md) 注意)。
- **PendingCrew 不做独立的全权登录**:它登录是"可选能力叠加",三条路径(同发布者确认卡 / 直接登录 / 扫码)最终都收敛到"拿一张受限的设备授权票(`pdg_`)",换不出全权 session。完整三路对照见 [设备授权](../../shared/concepts/device-grant.md)。

**PendingCrew 的"一次性 session → 换 scoped grant"是这篇的关键特殊路**

- PendingCrew 直接登录(Apple / Google / 邮箱)时,确实会短暂拿到一个 Supabase session——但它**用完即弃**:立刻拿这个 session 去换一张账号级的"换票凭据"(家族 SSO 凭据 `pfa_`),再用 `pfa_` mint 出一张受限的设备授权 grant(`pdg_`),然后**主动登出、丢掉那个 session**(成败两路都丢)。PendingCrew 长期手里只有那张 scoped grant。
- **为什么不直接留着 session**:留全权 session 是过权——PendingCrew 只需要"控制 crew"这一小块能力。一台机器被夺,泄露的是一张 scoped、可撤销的票,而不是用户的全权登录态。这对齐业界同发布者 SSO 模式(MSAL / Google Sign-In)。安全立场的完整论证在 [设备授权](../../shared/concepts/device-grant.md)。

**用在哪·长什么样**

- **PendingBot 登录壳**:三胶囊(Apple / Google)+ 邮箱输入框 → 人机校验 → 验证码。同一套登录状态机驱动 iOS 与 Mac 两端(平台各用原生控件,逻辑共享,不让流程在两端漂移)。
- **PendingCrew 确认卡(最顺的路)**:本机装过且登录过 PendingBot 时,共享 keychain 里已有 `pfa_`,PendingCrew 弹一张"同发布者确认卡"(显示你的头像 + 账号),一键 mint 换 grant,几乎无感。
- **扫码(账号在手机上、本机没 PendingBot)**:PendingCrew 出一个二维码 → 手机上已登录的 PendingBot 扫它 → 弹"授权这台 Mac 代表〔某 subject〕跑 PendingCrew?" → 选 subject、批准 → Mac 轮询拿到 grant。

**边界**

- **PendingCrew 绝不持全权 Supabase session**——这是登录模型否掉的过权点,直接登录路径里的 session 是一次性的、用完即弃、绝不持久化。
- **不做第三方 IdP 联邦**:同发布者 SSO 用 OS keychain 共享组做边界(同 team 签名的 app 才读得到 `pfa_`),不引第三方身份提供方。
- **核心工作流不强制登录**:PendingCrew 准备开源,不登录走本地 BYOK 模式照样完整可用,登录只叠加云端能力。

**注意**

- **扫码批准带防"骗签到别的 subject"护栏**:出码方可附带一个"想以哪个 subject 登录"的提示;批准方(手机上的 PendingBot 用户)看到这个提示,必须以同一个 subject 批准,堵掉"诱导批准方签给另一个 subject"的攻击。
- **PendingCrew 登录入口 UI 是 2026-06-17 才搬成现在这样**:镜像 PendingBot 登录页 + 同发布者确认卡。这只换了**入口 UI**,服务端的 device-login / mint / 家族 SSO 语义没变,安全立场完全沿用旧 SSO 设计——别把它当一个新的登录模型。
- **Google 登录在 PendingCrew 上还差后台配置**:`com.pendingname.pendingcrew` 的 iOS OAuth client id 尚未在 Cloud Console 建好 / 填进工程,在此之前 PendingCrew 的 Google 路径会抛错;邮箱 OTP + 扫码 + 确认卡是当前可用路径(见 tech-debt)。
- **签名问题会伪装成登录 / 后端故障**:模拟器 / Mac 若回落 ad-hoc 签名 → keychain 存不住会话 → Supabase 写静默降级成 anon → 报 "permission denied for table users" 这类**像后端权限**的错,实为签名问题。验登录态必须用真签名的 Xcode GUI 构建(见 [PendingBot app](pendingbot-app.md) / [PendingCrew app](pendingcrew-app.md) 注意)。

**现状** — 🟨 服务端三条 PendingCrew 登录路径的端点都已落 + 部署;PendingBot 四条登录路径代码已落。标 🟨:真机尾巴多且必做(共享 keychain 跨 app 真读、OAuth 全链路、扫码端到端只能真签名 app + Xcode GUI 验,headless ad-hoc 构建必失败),Google 后台未配。证据见 [`docs/progress.md`](../../../progress.md) + [设备授权](../../shared/concepts/device-grant.md) 现状行。
