# PendingCrew app(Mac / iPad)

大绿豆里**给开发者**的那一半:一个准备开源、本地为家的 crew 编排工作台,SwiftUI 写的桌面客户端。系统里它特殊在——它**自己内含一个本地后端**:Mac 上 crew / captain / session 全在本机跑,云端只当邮差。产品定位见 [PendingCrew 定位](../../pendingcrew/vision.md);本地为家的权威定义见 [本地为家](../../pendingcrew/concepts/local-first.md);登录模型见 [设备授权](../../shared/concepts/device-grant.md)。

**逻辑 — 它是什么、什么角色**

- **一个 SwiftUI 工程,双目标(Mac + iPad),能力分档**:
  - **Mac = 全功能**——本地 crew(在这台机器上真起 coding agent 子进程)+ 云端 crew(遥控对等电脑 / fly 云机)。
  - **iPad = 仅云端 crew**——iPad 跑不了本地 agent(无子进程能力 + 沙盒限制),本质是远程查看 / 遥控端,必须登录才有意义。
  - **iOS 不做**——iOS 用户在 [PendingBot app](pendingbot-app.md) 的 crew tab 里遥控,不另出 PendingCrew iOS。
- **这个 app 内含一个本地后端 / runner**:它和别的客户端最大的不同是——它不是"瘦客户端调远端 API",而是在本机直接编排子进程。Mac 上把用户自己的 Claude Code / Codex 作为子进程拉起来跑、管它的生命周期、收它的输出。两种 runner 后端的产品差异(Claude Code 走常驻终端、Codex 走 app-server)见 [runner 后端](../../pendingcrew/features/runner-backends.md)。
- **本地 MCP 是 app 二进制自己**:为了把 crew 的协作能力(@人类提问、审批 hook、给 agent 注入消息)接进被编排的 coding agent,app 把自己作为本地 MCP server / hook helper 跑——同一个 app 二进制带特定参数重新执行自己,当 crew-comms helper 用,不另外起一个独立进程 / Node 脚本。
- **登录走 scoped grant,不是全权 session**:核心工作流不登录也转(开源硬约束)。想登录时优先复用本机同发布者 app(PendingBot)的身份,但 PendingCrew 只换到一张受限的设备授权票(`pdg_`,控制 crew 这一小块),换不出 PendingBot 的全权 Supabase session。完整登录路径见 [Apple/Google 登录](sign-in.md) 与 [设备授权](../../shared/concepts/device-grant.md)。

**为什么 — 关键取舍**

- **本地内含后端,因为开源软件不能强制登录**:PendingCrew 准备开源,类比 Claude Code 的"登订阅 or 自带 key 二选一"——开源版必须不登录任何账号就能完整用。把本地做成自洽核心(自带后端 + runner + 本地白板),而不是云端的瘦客户端,是这个产品形态的硬约束。
- **本机即家,避双主同步**:一个 crew 的通信面同时只托管一处(纯本地 crew 用本地白板,登录态 crew 用 edge 白板),不做本地 ↔ edge 双向 sync——双主写冲突是分布式系统最难维持的形态,绕开它。
- **登录最小授权**:让 PendingCrew 持完整 PendingBot session 是过权,它只需"控制 crew"这一小块,scoped grant 把授权面收到最小。

**用在哪·长什么样**

- Mac 开机即用、不开屏逼登:默认直接进本地工作台,侧栏底部留一个"登录 PendingBot 账号"的可选入口。布局是三栏(crew/机器索引 + crew 群聊 + 单 session 窗口),见 [三栏 UI](../../pendingcrew/features/three-pane-ui.md)。
- iPad 是例外——硬登录,纯远程遥控端。
- 它和 PendingBot 的分工:PendingBot 看见 crew、做轻量遥控;PendingCrew 深度操作 crew(看完整输出、改工作目录、配 captain),互不吞功能。

**边界**

- **不做 PendingCrew iOS**,不做普通 IM(IM 都在 PendingBot,PendingCrew 只有 crew 内部群聊)。
- **本地后端只在 Mac**:iPad 没有本地 runner,只能跑云端 crew。
- **不持全权 session**:这是登录模型否掉的过权点,PendingCrew 长期只持 scoped grant。

**注意**

- **"BYOK 双轨 / 双 backend 模式"是已死的旧措辞**:旧 spec / 旧 roadmap 里"BYOK 双轨""`BackendMode` 切换"已作废——现状是 **Mac 后端恒为本地**,登录只是翻 `isAuthenticated` 这道能力门(叠加遥控 / 信箱 / fly),不是切换一个"本地 vs 云端"的模式开关。别按旧双轨理解。
- **本地 runner 模块整段 `#if os(macOS)` 隔离**:iPad / 编译校验环境进不到这块逻辑;它依赖子进程 + 终端能力,iPad 沙盒没有。
- **签名同 PendingBot 一样不能省**:Mac + iPad 模拟器都用 Apple Development 身份签名,不能回落 ad-hoc。设备授权令牌 / 家族凭据存在 keychain(含**跨 app 共享组** `M42BKJN82S.com.pendingname.shared`),ad-hoc 身份每次重构就变 → 系统认不出重建的 app → 反复弹"存取钥匙串"授权框 / -34018 存不住 → 登录态丢。用稳定的 Apple Development 身份根治(与 PendingBot 同源的坑)。
- **登录入口 UI 已搬成"镜像 PendingBot 登录页 + 同发布者确认卡"(2026-06-17)**:这只换了入口 UI,服务端 device-login / mint / 家族 SSO 语义不变,安全立场沿用旧 SSO 设计。

**现状** — 🟨 工程双端 build 通、本地模式(建 crew / 起 session / 群聊白板 / 审批)在本机 GUI 截图验过若干切片;Claude Code 常驻终端 + Codex app-server 两 runner 已实现并真机验过。标 🟨:跨端遥控(peer)、fly 云机、活体 hub 推送的真机端到端仍有尾巴,且 `devicePublicKey` 占位未和物理设备做密码学绑定(见 [设备授权](../../shared/concepts/device-grant.md) 注意 + tech-debt)。证据见 [`docs/progress.md`](../../../progress.md)。
