# 三端 UI(iPhone / iPad / Mac)

PendingBot 一份 SwiftUI 代码同时跑 iPhone / iPad / Mac:**视觉设计语言三端完全统一、原封共享**,只有布局骨架按屏幕大小适配(iPhone 单列、大屏多列)。核心权威 = 决策 D5。相关:[charter](../../shared/charter.md)(优先原生、优先长期体验)。

**逻辑** — 分三层,边界清楚:

1. **视觉设计语言**(配色 / 气泡样式 / 字体 / 头像 / 图标 / 间距 / 交互手感)—— 三端**完全统一、原封保留**。抽成一套**三端共享的 SwiftUI 组件层**,让 iPhone 自己也用这套——所以「统一」是字面意义上的同一份代码,不是「各端各画、长得像」。
2. **布局骨架** —— 按平台适配,**不算改设计**:iPhone 保持底部 TabView 单列;**iPad / Mac 用 NavigationSplitView 多列**(会话列表 + 聊天流并排)。每个功能片(feature slice)实现成跨平台 `FeatureSurface`,在大屏壳里投影成「列表列 + 详情列」。
3. **个别 UIKit-only 控件**(键盘附件栏、相机相册)—— Mac 上无对应,必须 AppKit 重写,**视觉尽量贴近但底层不同**。这是唯一会有差异的地方。

**为什么** — 用户要三端 UI「较统一」且**不动现有 iPhone 视觉设计**。缘起是「Mac 新建机器人选模型为何跟 iOS 不一样」——根因是早期 `Features/*` 图省事整体 `#if os(iOS)` 一刀切,Mac 被迫在 `Sources/Mac/` 平行重写出阉割版。定调:**不计成本一次打好地基,默认全三端共享含 UI**,只有 Mac 硬件真没有的(语音 / 相机 / 推送)才留 iOS-only。两套平行 UI 合一,根治「改了 iOS、Mac 没跟上」的长期漂移。

**用在哪·长什么样**

- **iPhone** —— 底部 TabView,单列,视觉**原封不变**(这是硬要求)。
- **iPad / Mac** —— NavigationSplitView 多列壳:会话 / 列表在中栏,详情(聊天流 / 文章 / 设置)在右栏。消息 / 好友 / 来信 / crew / 我 各 tab 都由同一份共享视图渲染真账号数据。
- **关键纪律**:把现有 iOS 视图重构成「共享 SwiftUI core + 薄 iOS 桥」是**结构重构、不是视觉改动**;每次重构后必须在 iOS 真机 / 模拟器**视觉回归确认无变化**——否则共享化时容易顺手改了 iPhone 的样子。

**边界(真·iOS-only 留存,正确的)**

- **语音通话**(`Features/Call/*`)—— Mac 硬件 / 平台限制,见 [语音](voice.md)。
- **相机扫码 / 相册**(UIImagePickerController)—— Mac 无对应。
- **登录壳 / Onboarding / Turnstile** —— iOS 壳。
- 这些之外,iPhone / iPad / Mac 的业务 UI 是同一份代码。

**注意**

- **决策日志一度标「未实施」已过时**:D5 在 2026-06-01 记的现状是「❌ 未实施(规划)」,但 `feat/tri-platform-ui`(71 commit)随后**已实现并合 main**(2026-06-09,`b4d0b131`):全 feature slice 跨平台、iPad 收敛三列、`Sources/Mac/` 删到只剩登录壳(MacWelcomeView),双端 build 绿。按现状理解——这不再是「规划」。
- **大屏壳曾有过「合 main 起从未真正跑通」的坑**:五个 tab 的列视图早期在 SwiftUI 视图图**外**手动求值,捕获的 self 拷贝从不装入图 → `@EnvironmentObject`/`@State` 永不灌注 → Mac 端首启即崩。已修(渲染分支挪进 body)。说明「共享化」要小心视图图的求值时机。
- **缓存首帧一跳**:大屏壳切 tab 会重建当前 tab,曾放大成「整页空→填」的可见闪烁;已把同步缓存读提到 init 让首帧即带值。盲盒模型 pill 因本地无缓存仍有固有一跳(见 tech-debt)。

**现状** — 🟨 已合 main(三端共享地基 + 全 feature slice 跨平台 + iPad/Mac 三列壳),Mac 端首屏在本机 GUI 截图验过、iPhone 实装无回归。标 🟨 而非 ✅:**三端真机 / 模拟器的完整验证仍待**(尤其 iPad 新三列布局 / 深链切 tab / 通话悬浮窗、Mac 各 tab 渲染;登录态需真账号,headless 模拟器进不到壳)。已知降级尾巴(各记 tech-debt,真机验时补):Mac composer 缺 freeze/continue/@-mention 三横幅、相机缺失、Mac 二维码名片 / push-active-conv 占位、Mac composer 简化文本孪生。
