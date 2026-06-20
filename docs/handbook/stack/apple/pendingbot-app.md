# PendingBot app(iPhone / iPad / Mac)

大绿豆的**主客户端**:一份 SwiftUI 代码同时跑 iPhone / iPad / macOS,普通用户的日常入口。系统里它是"读边缘投影 + 写回真源"的那一端——不是后端,是把后端的能力包成三端原生体验的壳。产品层面的三端 UI 决策见 [三端 UI](../../pendingbot/features/tri-platform-ui.md);读数据怎么走见 [客户端读路径](../../shared/concepts/read-path.md)。

**逻辑 — 它是什么、什么角色**

- **一个工程、三个目标(destination)**:iPhone / iPad / macOS 由**同一个 SwiftUI multiplatform 工程**编出,而不是三套代码。工程用 XcodeGen 从声明式 spec 生成,改工程配置改 spec、再生成,不手改工程文件。
- **视觉层三端共享、原封统一**:配色 / 气泡 / 字体 / 头像 / 间距 / 手感抽成一套三端共用的 SwiftUI 组件层,iPhone 自己也用这套。所以"三端一致"是字面意义的同一份代码,不是各端各画长得像。布局骨架按屏幕大小适配(iPhone 单列、iPad/Mac 多列),适配不算改设计。详见 [三端 UI](../../pendingbot/features/tri-platform-ui.md)。
- **读路径 = 本地缓存 + 边缘投影**:app 不直连数据库做高频读。开屏先用**设备本地加密缓存**即时画出来,再向**边缘投影**拿增量追新,只有边缘没命中 / 深翻历史才回落直连数据库(带行级安全)。三端共用一个 Repository 门面收口这套缓存读写,三端自动继承。完整模型见 [读路径](../../shared/concepts/read-path.md)。
- **平台成熟度分档**:iPhone 是 v1.0 的完整功能主目标;iPad 复用同一 target 跑多列大屏壳;macOS 已是真能用的三端之一(不再是占位),只有硬件 / 平台真没有的能力(语音通话、相机扫码、推送)留 iOS-only,其余业务 UI 三端同源。

**为什么 — 关键取舍**

- **一份代码胜过三套**:早期 iOS / Mac / 共享层是三个分裂的工程,改了 iOS、Mac 跟不上,长期漂移。合成单 multiplatform 工程 + 共享视觉层,是为了根治这种漂移——党纲"优先原生、优先长期体验"的直接落地,宁可一次把地基打厚。
- **读放边缘是为延迟,不是因为库不行**:库在欧盟单区(见 [Supabase](../supabase/supabase.md)),跨区首屏会白屏等待,所以热读必须本地缓存先行、边缘投影追新。这是 app 端能感知到的"首屏快、跨区不卡"的来源。
- **原生而非跨平台框架**:三端都用各自平台原生的 SwiftUI / AppKit 控件(个别 UIKit-only 控件在 Mac 上用 AppKit 重写),不走一套跨平台 UI 框架糊三端——优先原生手感。

**用在哪·长什么样**

- 用户的"大绿豆"就是这个 app:消息 / 好友 / 来信 / crew / 我 几个 tab。iPhone 底部 TabView 单列;iPad / Mac 是多列大屏壳(列表列 + 详情列并排)。
- crew tab 是 PendingBot 看见 / 遥控 crew 的入口——PendingBot 看见 crew,深度操作交给 [PendingCrew app](pendingcrew-app.md),互不吞功能。

**边界**

- **不是后端**:所有写回真源、所有授权的最终底线在 worker + 数据库;app 只做乐观 UI + 缓存 + 读投影。
- **真 iOS-only 的留存是对的**:语音通话、相机 / 相册、登录壳 / Onboarding / Turnstile 留 iOS;这些之外三端同源。
- **不在中国大陆上架**:中文只是开发语言,评估时不把中国 App Store 限制当约束。

**注意**

- **"Mac 还是占位"是过时说法**:早期文档把 macOS 标作 scaffold / 占位 View,现状是 Mac 已实装为真能用的三端之一(三端共享地基 + 全 feature slice 跨平台已合 main)。按现状理解,别照搬旧 README 里的"Mac 在 Phase 2+ 才做"。
- **签名必须保持开启,连模拟器也要签**:工程对 iOS 真机 + **iOS 模拟器** + macOS 全用 Apple Development 身份签名。模拟器若回落 ad-hoc(无 team 前缀)→ keychain-access-groups 失效 → Keychain 全挂 -34018 → Supabase 会话存不住 → 登录态写静默降级成 anon → onboarding 报 "permission denied for table users"。这个坑被反复误诊成后端 / DB 问题多次,实为签名问题;务必保持模拟器签名。验登录态要用 Xcode GUI / 已登录 Apple ID 的环境构建,headless 无证书构建会回落 ad-hoc。
- **改工程配置走 spec、别手改工程文件**:build settings / 依赖 / target 改在 XcodeGen spec 里再重生成,直接编辑生成出来的工程文件会被下次生成覆盖。

**现状** — 🟨 三端共享地基 + 全 feature slice 跨平台 + iPad/Mac 多列壳已合 main;Mac 首屏 + iPhone 实装在本机验过无回归。标 🟨 而非 ✅:三端真机 / 模拟器的**完整**验证仍待(尤其 iPad 新三列、深链切 tab、Mac 各 tab),且有若干 Mac 端降级尾巴(composer 三横幅缺失、相机缺失、二维码名片 / push-active-conv 占位,各记 tech-debt)。证据见 [`docs/progress.md`](../../../progress.md) + [三端 UI](../../pendingbot/features/tri-platform-ui.md)。
